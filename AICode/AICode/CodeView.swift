import SwiftUI
import UIKit

/// Code tab: the latest SwiftUI code extracted from an AI reply
/// (or from a sample prompt), in a monospace block with a Copy button.
///
/// This code is *shown* here — it is not compiled or run inside the
/// app. iOS has no in-app Swift compiler, and App Store rules forbid
/// executing downloaded code. Paste it into Xcode to run it for real;
/// the Preview tab shows the same UI via the safe JSON preview.
struct CodeView: View {
    @Environment(ChatStore.self) private var store
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let code = store.currentCode {
                        HStack {
                            Text("生成された SwiftUI コード")
                                .font(.headline)
                            Spacer()
                            Button(copied ? "コピーしました" : "コピー") {
                                UIPasteboard.general.string = code
                                copied = true
                                Task {
                                    try? await Task.sleep(for: .seconds(2))
                                    copied = false
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Text(code)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        Text("このコードはアプリ内では実行されません。Xcodeに貼り付けて実行してください。同じ画面は「プレビュー」タブでJSONプレビューとして動きます。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("まだコードがありません。")
                            .font(.headline)
                        Text("チャットで「カウンターを作って」などと聞くか、下のサンプルをタップすると、ここに SwiftUI コードが表示されます。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        ForEach(Samples.all) { sample in
                            Button(sample.title) {
                                store.applySample(sample)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("コード")
        }
    }
}

#Preview {
    CodeView()
        .environment(ChatStore())
}
