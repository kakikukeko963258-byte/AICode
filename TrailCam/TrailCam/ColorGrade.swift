import CoreImage
import Foundation

/// 仕上がりの色味。サンプル写真は「サイバー」:
/// 影を青〜ティールに倒し、光跡のオレンジ/赤を引き立てる青橙グレーディング。
enum GradeStyle: String, CaseIterable, Identifiable {
    case cyber
    case natural
    case mono

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cyber: return "サイバー"
        case .natural: return "ナチュラル"
        case .mono: return "モノクロ"
        }
    }
}

enum ColorGrade {
    private static var cachedCube: (style: GradeStyle, filter: CIFilter)?

    static func apply(to image: CIImage, style: GradeStyle) -> CIImage {
        switch style {
        case .natural:
            return image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.15,
                kCIInputContrastKey: 1.06,
                kCIInputBrightnessKey: 0.0
            ])
        case .mono:
            return image.applyingFilter("CIPhotoEffectMono")
        case .cyber:
            if let cachedCube, cachedCube.style == style {
                var out = image
                cachedCube.filter.setValue(out, forKey: kCIInputImageKey)
                if let result = cachedCube.filter.outputImage { out = result }
                return out.applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 1.12,
                    kCIInputContrastKey: 1.05
                ])
            }
            let filter = makeCyberCubeFilter()
            cachedCube = (style, filter)
            filter.setValue(image, forKey: kCIInputImageKey)
            let cubed = filter.outputImage ?? image
            return cubed.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.12,
                kCIInputContrastKey: 1.05
            ])
        }
    }

    /// 32^3 のカラーキューブで青橙スプリットトーニングを作る。
    /// - 影: 青/ティールを足し、赤を引く
    /// - ハイライト: オレンジ方向に寄せる
    /// - 彩度を約1.3倍、軽いS字コントラスト
    private static func makeCyberCubeFilter() -> CIFilter {
        let size = 32
        var data = Data(capacity: size * size * size * 4 * MemoryLayout<Float>.size)
        for bIndex in 0..<size {
            for gIndex in 0..<size {
                for rIndex in 0..<size {
                    var r = Float(rIndex) / Float(size - 1)
                    var g = Float(gIndex) / Float(size - 1)
                    var b = Float(bIndex) / Float(size - 1)

                    // 軽いS字コントラスト
                    func scurve(_ x: Float) -> Float { x * x * (3 - 2 * x) }
                    r = r + (scurve(r) - r) * 0.28
                    g = g + (scurve(g) - g) * 0.28
                    b = b + (scurve(b) - b) * 0.28

                    // 彩度アップ
                    let luma = 0.299 * r + 0.587 * g + 0.114 * b
                    r = luma + (r - luma) * 1.30
                    g = luma + (g - luma) * 1.30
                    b = luma + (b - luma) * 1.30

                    // スプリットトーン
                    let shadow = (1 - luma) * (1 - luma)
                    let high = luma * luma
                    r += -0.055 * shadow + 0.075 * high
                    g += 0.045 * shadow + 0.020 * high
                    b += 0.130 * shadow - 0.060 * high

                    func clamp(_ x: Float) -> Float { min(1, max(0, x)) }
                    var outR = clamp(r), outG = clamp(g), outB = clamp(b)
                    data.append(Data(bytes: &outR, count: 4))
                    data.append(Data(bytes: &outG, count: 4))
                    data.append(Data(bytes: &outB, count: 4))
                    var a: Float = 1
                    data.append(Data(bytes: &a, count: 4))
                }
            }
        }
        let filter = CIFilter(name: "CIColorCube")!
        filter.setValue(size, forKey: "inputCubeDimension")
        filter.setValue(data, forKey: "inputCubeData")
        return filter
    }
}
