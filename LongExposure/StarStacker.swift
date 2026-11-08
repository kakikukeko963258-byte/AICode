import CoreImage
import Vision
import simd

/// Linear, floating-point stacking; no synthetic stars or detail generation.
final class StarStacker {
    private let context: CIContext
    private let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private var reference: CGImage?
    private var referencePoints: [CGPoint] = []
    private var mean: CIImage?
    private var bounds = CGRect.zero
    private var edgeInset: CGFloat = 2
    private(set) var accepted = 0
    private(set) var rejected = 0
    private(set) var lastRejection = ""
    private(set) var lastAlignment = matrix_identity_float3x3

    init(context: CIContext) { self.context = context }

    func add(_ input: CIImage) throws -> Bool {
        let origin = input.extent.origin
        let frame = input.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
        let scale = min(1, 1024 / max(frame.extent.width, frame.extent.height))
        let scaled = frame.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let small = scaled
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 3])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        guard let thumbnail = context.createCGImage(small, from: small.extent) else { throw Self.failure("位置合わせ画像を作成できません。") }
        let points = peaks(scaled)
        var aligned = frame
        var inset = edgeInset
        if let reference {
            do {
                // Target is the floating frame; the handler supplies the fixed reference.
                let warp: simd_float3x3
                if let t = StarRegistration.align(source: points, reference: referencePoints, size: small.extent.size) {
                    warp = simd_float3x3(columns: (SIMD3(Float(t.a),Float(t.b),0), SIMD3(Float(t.c),Float(t.d),0), SIMD3(Float(t.tx),Float(t.ty),1)))
                } else {
                    let request = VNHomographicImageRegistrationRequest(targetedCGImage: thumbnail)
                    try VNImageRequestHandler(cgImage: reference).perform([request])
                    guard let observation = request.results?.first else { throw Self.failure("星を認識できませんでした。") }
                    warp = observation.warpTransform
                }
                let corners = try Self.corners(for: warp, size: small.extent.size)
                lastAlignment = warp
                let original = Self.rectCorners(small.extent.size)
                for (point, old) in zip(corners, original) {
                    inset = max(inset, max(abs(point.x - old.x), abs(point.y - old.y)) / scale + 3)
                }
                aligned = frame.applyingFilter("CIPerspectiveTransform", parameters: [
                    "inputBottomLeft": CIVector(cgPoint: CGPoint(x: corners[0].x / scale, y: corners[0].y / scale)),
                    "inputBottomRight": CIVector(cgPoint: CGPoint(x: corners[1].x / scale, y: corners[1].y / scale)),
                    "inputTopRight": CIVector(cgPoint: CGPoint(x: corners[2].x / scale, y: corners[2].y / scale)),
                    "inputTopLeft": CIVector(cgPoint: CGPoint(x: corners[3].x / scale, y: corners[3].y / scale))
                ]).cropped(to: bounds)
            } catch {
                // Never average an unregistered image into a sharp star stack.
                rejected += 1
                lastRejection = error.localizedDescription
                return false
            }
        } else {
            bounds = frame.extent
            self.reference = thumbnail
            referencePoints = points
        }
        let next = mean.map { $0.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: aligned, kCIInputTimeKey: 1.0 / Double(accepted + 1)]) } ?? aligned
        guard let rendered = context.createCGImage(next, from: bounds, format: .RGBAh, colorSpace: space) else { throw Self.failure("星空の合成に失敗しました。") }
        mean = CIImage(cgImage: rendered)
        edgeInset = inset
        accepted += 1
        return true
    }

    private func peaks(_ image: CIImage) -> [CGPoint] {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        guard width > 8, height > 8 else { return [] }
        var rgba = [Float](repeating: 0, count: width*height*4)
        rgba.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: width*16, bounds: CGRect(x:0,y:0,width:width,height:height), format:.RGBAf, colorSpace:space) }
        func intensity(_ x:Int,_ y:Int)->Float { rgba[(y*width+x)*4] }
        var samples:[Float] = []
        for y in stride(from:4,to:height-4,by:8) { for x in stride(from:4,to:width-4,by:8) { samples.append(intensity(x,y)) } }
        samples.sort()
        let background = samples[samples.count/2]
        let deviations = samples.map { abs($0-background) }.sorted()
        let threshold = background + max(0.00001, deviations[deviations.count/2] * 8)
        var candidates:[(Float,CGPoint)] = []
        for y in 3..<(height-3) {
            for x in 3..<(width-3) {
                let v = intensity(x,y)
                guard v > threshold else { continue }
                var maximum = true
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 { if intensity(x+dx,y+dy) >= v { maximum = false } } }
                guard maximum else { continue }
                var weight:CGFloat = 0, cx:CGFloat = 0, cy:CGFloat = 0
                for dy in -2...2 { for dx in -2...2 {
                    let w = CGFloat(max(0,intensity(x+dx,y+dy)-background))
                    weight += w; cx += CGFloat(x+dx)*w; cy += CGFloat(y+dy)*w
                } }
                // Bitmap scanlines start at the top; Core Image coordinates start below.
                if weight > 0 { candidates.append((v,CGPoint(x:cx/weight+0.5,y:CGFloat(height)-0.5-cy/weight))) }
            }
        }
        candidates.sort { $0.0 > $1.0 }
        var points:[CGPoint] = []
        for (_,point) in candidates {
            if points.allSatisfy({ hypot($0.x-point.x,$0.y-point.y) > 6 }) { points.append(point) }
            if points.count >= 30 { break }
        }
        return points
    }

    var linearImage: CIImage? {
        guard let mean else { return nil }
        let inset = min(edgeInset, min(bounds.width, bounds.height) * 0.12)
        return mean.cropped(to: bounds.insetBy(dx: inset, dy: inset))
    }

    func developed(ev: Double) -> CIImage? {
        linearImage?.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
    }

    // Matrix and corner validation is shared with the synthetic registration checks.
    static func rectCorners(_ size: CGSize) -> [CGPoint] {
        [CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0), CGPoint(x: size.width, y: size.height), CGPoint(x: 0, y: size.height)]
    }

    static func corners(for warp: simd_float3x3, size: CGSize) throws -> [CGPoint] {
        let original = rectCorners(size)
        let points = try original.map { point -> CGPoint in
            let p = warp * SIMD3(Float(point.x), Float(point.y), 1)
            guard p.z.isFinite, abs(p.z) > 0.0001 else { throw failure("不正な位置合わせです。") }
            let result = CGPoint(x: CGFloat(p.x / p.z), y: CGFloat(p.y / p.z))
            guard result.x.isFinite, result.y.isFinite, abs(result.x - point.x) < size.width * 0.1, abs(result.y - point.y) < size.height * 0.1 else { throw failure("動きが大きすぎます。") }
            return result
        }
        let horizontal = hypot(points[1].x - points[0].x, points[1].y - points[0].y) / size.width
        let vertical = hypot(points[3].x - points[0].x, points[3].y - points[0].y) / size.height
        guard (0.94...1.06).contains(horizontal), (0.94...1.06).contains(vertical) else { throw failure("画角が変わりました。") }
        return points
    }

    private static func failure(_ text: String) -> NSError { NSError(domain: "StarStacker", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
