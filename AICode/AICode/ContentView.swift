import SwiftUI

/// Three tabs sharing one `ChatStore`:
/// - Chat: prompt the on-device AI, streamed replies
/// - Code: the latest SwiftUI code the AI generated, with Copy
/// - Preview: the AI's UI-description JSON rendered as real SwiftUI
struct ContentView: View {
    @Environment(ChatStore.self) private var store
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            ChatView()
                .tabItem { Label("チャット", systemImage: "message") }
                .tag(0)
            CodeView()
                .tabItem { Label("コード", systemImage: "chevron.left.forwardslash.chevron.right") }
                .tag(1)
            PreviewView()
                .tabItem { Label("プレビュー", systemImage: "eye") }
                .tag(2)
        }
    }
}
