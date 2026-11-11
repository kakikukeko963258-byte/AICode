import SwiftUI

/// 星空カメラ AstroCam
/// 無音（シャッター音なし）で星空を長時間スタッキング撮影するカメラ。
/// 写真撮影の仕組み（AVCapturePhotoOutput）を使わず、映像フレームを
/// 1枚ずつ重ねる方式のため、日本向けiPhoneでもシャッター音は鳴らない。
@main
struct AstroCamApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}
