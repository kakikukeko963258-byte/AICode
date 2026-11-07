import Foundation

/// One built-in demo: a prompt the user can tap, the SwiftUI code the
/// AI would generate for it, and the UI-description JSON that drives
/// the live preview. These work fully offline, with no Apple
/// Intelligence needed — they demonstrate the preview even on a
/// device where the on-device model is unavailable.
struct SamplePrompt: Identifiable {
    let id = UUID()
    let title: String
    let prompt: String
    let swiftCode: String
    let uiJSON: String
}

enum Samples {
    static let all: [SamplePrompt] = [counter, profileCard, todoList]

    static let counter = SamplePrompt(
        title: "赤いボタンとカウンター",
        prompt: "赤いボタンとカウンターを作って",
        swiftCode: """
        import SwiftUI

        struct CounterView: View {
            @State private var count = 0

            var body: some View {
                VStack(spacing: 16) {
                    Text("カウンター")
                        .font(.title)
                        .bold()
                    Text("カウント: \\(count)")
                        .font(.title2)
                    Button("＋1") {
                        count += 1
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    Button("リセット") {
                        count = 0
                    }
                }
                .padding()
            }
        }
        """,
        uiJSON: """
        {
          "type": "VStack",
          "spacing": 16,
          "padding": 16,
          "children": [
            {"type": "Text", "text": "カウンター", "font": "title", "bold": true},
            {"type": "Text", "text": "カウント: {counter}", "font": "title2"},
            {"type": "Button", "title": "＋1", "color": "red", "action": "increment"},
            {"type": "Button", "title": "リセット", "action": "reset"}
          ]
        }
        """
    )

    static let profileCard = SamplePrompt(
        title: "プロフィールカード",
        prompt: "プロフィールカードを作って",
        swiftCode: """
        import SwiftUI

        struct ProfileCardView: View {
            var body: some View {
                VStack(spacing: 12) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(.blue)
                    Text("kakuei")
                        .font(.title)
                        .bold()
                    Text("iOSアプリを作っています")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                        Text("フォローする")
                    }
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .padding()
            }
        }
        """,
        uiJSON: """
        {
          "type": "VStack",
          "spacing": 12,
          "padding": 16,
          "children": [
            {"type": "Image", "systemName": "person.circle.fill", "color": "blue", "font": "title"},
            {"type": "Text", "text": "kakuei", "font": "title", "bold": true},
            {"type": "Text", "text": "iOSアプリを作っています", "font": "callout", "color": "secondary"},
            {"type": "HStack", "spacing": 12, "children": [
              {"type": "Image", "systemName": "star.fill", "color": "yellow"},
              {"type": "Text", "text": "フォローする"}
            ]}
          ]
        }
        """
    )

    static let todoList = SamplePrompt(
        title: "ToDoリスト",
        prompt: "ToDoリストを作って",
        swiftCode: """
        import SwiftUI

        struct TodoListView: View {
            @State private var newTask = ""
            @State private var notificationsOn = true

            var body: some View {
                VStack(alignment: .leading, spacing: 16) {
                    Text("今日のToDo")
                        .font(.title)
                        .bold()
                    TextField("新しいタスク", text: $newTask)
                        .textFieldStyle(.roundedBorder)
                    Toggle("通知する", isOn: $notificationsOn)
                    List {
                        Text("牛乳を買う")
                        Text("ゴミを出す")
                        Text("ジムに行く")
                    }
                    .frame(height: 180)
                }
                .padding()
            }
        }
        """,
        uiJSON: """
        {
          "type": "VStack",
          "spacing": 16,
          "padding": 16,
          "children": [
            {"type": "Text", "text": "今日のToDo", "font": "title", "bold": true},
            {"type": "TextField", "placeholder": "新しいタスク"},
            {"type": "Toggle", "label": "通知する", "isOn": true},
            {"type": "Slider", "value": 0.5},
            {"type": "List", "items": ["牛乳を買う", "ゴミを出す", "ジムに行く"]}
          ]
        }
        """
    )
}
