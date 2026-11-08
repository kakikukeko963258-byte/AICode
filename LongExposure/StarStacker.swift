import CoreImage
import Vision
import simd

/// Linear, floating-point stacking; no synthetic stars or detail generation.
final class StarStacker {
    private let context: CIContext
    private let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private var reference: CGImage?
    private var mean: CIImage?
    private var bounds = CGRect.zero
    private var edgeInset: CGFloat = 2
    private(set) var accepted = 0
    private(set) var rejected = 0

    init(context: CIContext) { self.context = context }

    func add(_ input: CIImage) throws -> Bool {
        let origin = input.extent.origin
        let frame = input.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
        let scale = min(1, 1024 / max(frame.extent.width, frame.extent.height))
        let small = frame.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 3])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        guard let thumbnail = context.createCGImage(small, from: small.extent) else { throw Self.failure("位置合わせ画像を作成できません。") }
        var aligned = frame
        var inset = edgeInset
        if let reference {
            do {
                // Target is the floating frame; the handler supplies the fixed reference.
                let request = VNHomographicImageRegistrationRequest(targetedCGImage: thumbnail)
                try VNImageRequestHandler(cgImage: reference).perform([request])
                guard let observation = request.results?.first else { rejected += 1; return false }
                let corners = try Self.corners(for: observation.warpTransform, size: small.extent.size)
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
                return false
            }
        } else {
            bounds = frame.extent
            self.reference = thumbnail
        }
        let next = mean.map { $0.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: aligned, kCIInputTimeKey: 1.0 / Double(accepted + 1)]) } ?? aligned
        guard let rendered = context.createCGImage(next, from: bounds, format: .RGBAh, colorSpace: space) else { throw Self.failure("星空の合成に失敗しました。") }
        mean = CIImage(cgImage: rendered)
        edgeInset = inset
        accepted += 1
        return true
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
