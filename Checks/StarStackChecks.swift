import Foundation
import CoreImage
import simd

@main
enum StarStackChecks {
    static let size = 256
    static let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static let context = CIContext(options: [.workingColorSpace: space, .cacheIntermediates: false])
    static var randomState: UInt64 = 1234567
    static let stars: [(Int, Int)] = [(35,35),(85,30),(150,42),(210,35),(48,90),(110,80),(180,95),(225,105),(30,155),(85,175),(160,160),(205,185),(45,215),(120,220),(205,225)]

    static func noise() -> Float {
        randomState = randomState &* 6364136223846793005 &+ 1
        return (Float((randomState >> 32) & 65535) / 65535 - 0.5) * 0.004
    }
    static func frame(noisy: Bool) -> CIImage {
        var pixels = [Float](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                var value: Float = 0.003 + (noisy ? noise() : 0)
                for (sx, sy) in stars {
                    let distance = Float((x-sx)*(x-sx)+(y-sy)*(y-sy))
                    if distance < 64 { value += 0.3 * exp(-distance / 3) }
                }
                let faint = Float((x-125)*(x-125)+(y-130)*(y-130))
                if faint < 64 { value += 0.004 * exp(-faint / 3) }
                let index = (y * size + x) * 4
                pixels[index] = value; pixels[index+1] = value; pixels[index+2] = value; pixels[index+3] = 1
            }
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: size * 16, size: CGSize(width: size, height: size), format: .RGBAf, colorSpace: space)
    }
    static func values(_ image: CIImage) -> [Float] {
        var pixels = [Float](repeating: 0, count: size * size * 4)
        pixels.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: size * 16, bounds: CGRect(x: 0, y: 0, width: size, height: size), format: .RGBAf, colorSpace: space)
        }
        return pixels
    }
    static func value(_ pixels: [Float], _ x: Int, _ y: Int) -> Double { Double(pixels[(y * size + x) * 4]) }
    static func variance(_ pixels: [Float]) -> Double {
        let samples = (115..<145).flatMap { y in (15..<65).map { x in value(pixels, x, y) } }
        let mean = samples.reduce(0,+) / Double(samples.count)
        return samples.map { pow($0-mean,2) }.reduce(0,+) / Double(samples.count)
    }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
    static func main() throws {
        let stack = StarStacker(context: context)
        let first = frame(noisy: true)
        let firstAccepted = try stack.add(first)
        require(firstAccepted, "First frame rejected")
        for _ in 1..<16 { _ = try stack.add(frame(noisy: true)) }
        require(stack.accepted >= 12, "Too many stationary frames rejected: \(stack.accepted)")
        let combined = values(stack.linearImage!)
        let original = values(first)
        require(variance(combined) < variance(original) * 0.4, "Stack did not reduce background noise")
        require(value(combined,125,130) > 0.005, "Faint star was erased")
        let brightened = values(stack.developed(ev: 2.5)!)
        let gain = value(brightened,125,130) / value(combined,125,130)
        require(abs(gain - pow(2,2.5)) < 0.05, "Linear development gain is wrong")

        let tracking = StarStacker(context: context)
        let base = frame(noisy: false)
        _ = try tracking.add(base)
        let angle = CGFloat(0.006)
        let transform = CGAffineTransform(translationX: -128, y: -128)
            .concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(translationX: 131, y: 126))
        let sensorBounds = CGRect(x: 0, y: 0, width: size, height: size)
        let shifted = base.transformed(by: transform)
            .composited(over: CIImage(color: .black).cropped(to: sensorBounds)).cropped(to: sensorBounds)
        let sourcePoints = stars.map { CGPoint(x:$0.0,y:$0.1).applying(transform) }
        let referencePoints = stars.map { CGPoint(x:$0.0,y:$0.1) }
        let geometric = StarRegistration.align(source:sourcePoints,reference:referencePoints,size:CGSize(width:size,height:size))
        require(geometric != nil, "Pure constellation matching failed")
        let error = sourcePoints[0].applying(geometric!)
        require(hypot(error.x-referencePoints[0].x,error.y-referencePoints[0].y)<0.05, "Constellation transform is backwards")
        let alignedAccepted = try tracking.add(shifted)
        require(alignedAccepted, "Translated/rotated star field was not registered: \(tracking.lastRejection)")
        let aligned = values(tracking.linearImage!)
        var maximum = 0.0, peak = CGPoint.zero
        for y in 20..<40 { for x in 75..<95 { let v = value(aligned,x,y); if v > maximum { maximum = v; peak = CGPoint(x:x,y:y) } } }
        require(value(aligned,85,30) > 0.23, "Registration direction or rotation is wrong: original=\(value(values(base),85,30)), aligned=\(value(aligned,85,30)), peak=\(peak), max=\(maximum), warp=\(tracking.lastAlignment), expectedInverse=\(transform.inverted())")
        let badWarp = simd_float3x3(columns: (SIMD3(1,0,0), SIMD3(0,1,0), SIMD3(100,0,1)))
        do {
            _ = try StarStacker.corners(for: badWarp, size: CGSize(width:size,height:size))
            fatalError("Excessive motion was accepted")
        } catch { }
        print("PASS: faint-star preservation, noise reduction, EV gain, translation/rotation registration, excessive-motion rejection; accepted=\(stack.accepted)")
    }
}
