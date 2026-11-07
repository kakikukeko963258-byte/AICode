import SwiftUI

/// Chat tab: prompt the on-device AI and watch the reply stream in.
/// When Apple Intelligence is unavailable the banner explains why
/// (iPhone 15 Pro+ + iOS 26 + Apple Intelligence on) and the sample
/// prompts below still work offline.
struct ChatView: View {
    @Environment(ChatStore.self) private var store
    @State private var input = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let reason = store.aiUnavailableMessage {
                    Label(reason + " サンプルはそのまま試せます。", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12))
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(store.messages) { message in
                                messageBubble(message)
                                    .id(message.id)
                            }
                            if store.isStreaming {
                                ProgressView("AIが考えています…")
                                    .font(.callout)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: store.messages.count) { _, _ in
                        if let last = store.messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                    .onChange(of: store.messages.last?.text) { _, _ in
                        if let last = store.messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }

                // Built-in samples: work offline, no AI call.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Samples.all) { sample in
                            Button(sample.title) {
                                store.applySample(sample)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(store.isStreaming)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 6)

                HStack {
                    TextField("作りたい画面や質問を書く…", text: $input, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .disabled(store.isStreaming)
                    Button("送信") {
                        store.send(input)
                        input = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isStreaming)
                }
                .padding()
            }
            .navigationTitle("AIチャット")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("新規会話") { store.newConversation() }
                        .disabled(store.isStreaming)
                }
            }
        }
    }

    @ViewBuilder
    private func messageBubble(_ message: ChatStore.Message) -> some View {
        HStack(alignment: .top) {
            if message.role == .assistant {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
            }
            Text(message.text.isEmpty ? "…" : message.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(message.role == .user
            ? Color(.systemBlue).opacity(0.12)
            : Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    ChatView()
        .environment(ChatStore())
}
