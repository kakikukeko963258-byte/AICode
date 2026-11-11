import SwiftUI

/// データモッシュ MoshCam
/// 異なる2本の動画を、データモッシュ特有の「前の映像が次の映像の
/// 動きで溶けて崩れる」トランジションで繋げるアプリ。
@main
struct MoshCamApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}
