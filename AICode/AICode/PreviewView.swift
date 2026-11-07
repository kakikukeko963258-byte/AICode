import SwiftUI

/// Preview tab: renders the latest UI-description JSON as real SwiftUI.
///
/// This is a *safe* live preview, not runtime Swift compilation:
/// the AI's JSON is decoded into `UINode` values and rendered only
/// with the components in `UIDescription.swift`. Buttons can only do
/// the named actions (counter +1 / reset, toggle flip). Arbitrary
/// Swift from the AI is never compiled or executed.
///
/// The preview updates live while a chat reply streams in, whenever
/// a complete JSON block can be parsed. Sample prompts work offline.
struct PreviewView: View {
    @Environment(ChatStore.self) private var store
    @State private var previewState = PreviewState()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("ライブプレビュー（安全なJSONプレビュー）")
                        .font(.headline)
                    Text("AIが出したUI記述JSONを、このアプリが用意した部品だけで描いています。Swiftコードそのものをアプリ内でコンパイル・実行しているわけではありません。")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if let node = store.currentPreviewNode {
                        VStack(alignment: .leading, spacing: 0) {
                            UINodeView(node: node, state: previewState)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        Button("プレビューの状態をリセット") {
                            previewState = PreviewState()
                        }
                        .font(.callout)
                    } else {
                        Text("まだプレビューがありません。チャットで画面を作ってもらうか、サンプルをタップしてください。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        ForEach(Samples.all) { sample in
                            Button(sample.title) {
                                store.applySample(sample)
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    if let error = store.previewError {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding()
            }
            .navigationTitle("プレビュー")
        }
    }
}

#Preview {
    PreviewView()
        .environment(ChatStore())
}
