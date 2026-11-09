import SwiftUI

/// 光跡カメラ TrailCam
/// 夜の道路などで車のライトの軌跡（光跡）を撮る長時間露光カメラ。
/// 低ISOフレームを比較明合成／平均化して合成し、
/// サンプル写真のような青橙グレーディングで仕上げる。
@main
struct TrailCamApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}
