import Foundation

/// Chat state shared by the Chat / Code / Preview tabs.
///
/// - `messages`: the conversation shown in the Chat tab.
/// - `currentCode`: the latest Swift code extracted from an AI reply
///   (```swift fence) — shown in the Code tab with a copy button.
/// - `currentPreviewNode` / `previewError`: the latest UI-description
///   JSON extracted from an AI reply (```json fence) and decoded into
///   a `UINode` — rendered in the Preview tab. Updated live while a
///   reply streams in, whenever a complete JSON block can be parsed.
/// - Sample prompts apply their code + preview immediately, with no
///   AI call, so the preview works offline too.
@available(iOS 26, *)
@MainActor
@Observable
final class ChatStore {
    struct Message: Identifiable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        var text: String
    }

    var messages: [Message] = []
    var currentCode: String?
    var currentPreviewNode: UINode?
    var previewError: String?
    var isStreaming = false
    var errorMessage: String?

    /// `nil` when AI can be used; otherwise the reason, shown as a
    /// banner in the Chat tab. Sample prompts still work when this
    /// is non-nil.
    var aiUnavailableMessage: String? {
        // Deployment target is iOS 26, so this is always the iOS 26 path.
        aiService?.availabilityMessage()
    }

    private var aiService: AIService?

    init() {
        if #available(iOS 26, *) {
            aiService = AIService()
        }
        messages.append(Message(
            role: .assistant,
            text: "こんにちは！SwiftUIのコーディングアシスタントです。作りたい画面や、わからないコードのことを聞いてください。\n\n下のサンプルをタップすると、AIなしでもコードとライブプレビューを試せます。"
        ))
    }

    // MARK: - Sending

    func send(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }
        errorMessage = nil
        messages.append(Message(role: .user, text: trimmed))

        guard #available(iOS 26, *) else {
            appendAssistant("Foundation Models を使うには iOS 26 が必要です。")
            return
        }
        guard let service = aiService else {
            appendAssistant("このデバイスでは Apple Intelligence を使えません。サンプルでプレビューを試せます。")
            return
        }
        if let reason = service.availabilityMessage() {
            appendAssistant(
                reason + "\n\nAIチャットは使えませんが、下のサンプルをタップすればコードとライブプレビューを試せます。"
            )
            return
        }

        isStreaming = true
        messages.append(Message(role: .assistant, text: ""))
        let assistantIndex = messages.count - 1

        Task {
            do {
                let full = try await service.sendStreaming(trimmed) { [weak self] partial in
                    // Streaming runs on the MainActor (AIService is
                    // @MainActor), so this updates the UI directly.
                    guard let self else { return }
                    self.messages[assistantIndex].text = partial
                    self.applyExtractedContent(from: partial)
                }
                applyExtractedContent(from: full)
                isStreaming = false
            } catch {
                var text = "エラー: \(error.localizedDescription)"
                // For the language error, attach the device's actual
                // language state so it can be screenshotted and
                // reported instead of guessed.
                if error.localizedDescription.contains("対応言語と端末の言語設定") {
                    text += "\n\n【診断情報】\n\(service.diagnosticsSummary)"
                }
                messages[assistantIndex].text = text
                errorMessage = error.localizedDescription
                isStreaming = false
            }
        }
    }

    func newConversation() {
        guard !isStreaming else { return }
        messages.removeAll()
        currentCode = nil
        currentPreviewNode = nil
        previewError = nil
        errorMessage = nil
        if #available(iOS 26, *) {
            aiService?.startSession()
        }
        messages.append(Message(
            role: .assistant,
            text: "新しい会話を始めました。何を作りますか？"
        ))
    }

    // MARK: - Samples (offline)

    func applySample(_ sample: SamplePrompt) {
        messages.append(Message(role: .user, text: sample.prompt))
        messages.append(Message(
            role: .assistant,
            text: "サンプル「\(sample.title)」です。Code タブに SwiftUI コード、Preview タブにライブプレビューを出しました。ボタンを押すとカウンターなどが実際に動きます。"
        ))
        currentCode = sample.swiftCode
        applyPreviewJSON(sample.uiJSON)
    }

    // MARK: - Extraction

    /// Extract the first ```swift (or bare ```) code fence and the
    /// first ```json fence from a reply, and reflect them in the
    /// Code / Preview tabs. Called on every streamed chunk so the
    /// preview updates live as the reply arrives; incomplete JSON
    /// simply fails to parse and is ignored until complete.
    func applyExtractedContent(from text: String) {
        if let code = extractFencedBlock(from: text, languages: ["swift", ""]) {
            currentCode = code
        }
        if let json = extractFencedBlock(from: text, languages: ["json", "ui"]) {
            applyPreviewJSON(json)
        }
    }

    func applyPreviewJSON(_ json: String) {
        switch UINode.decode(from: json) {
        case .success(let node):
            currentPreviewNode = node
            previewError = nil
        case .failure(let error):
            previewError = error.localizedDescription
        }
    }

    private func appendAssistant(_ text: String) {
        messages.append(Message(role: .assistant, text: text))
    }

    /// Returns the content of the first fenced block whose language
    /// tag is in `languages`, or `nil` if there is none.
    private func extractFencedBlock(from text: String, languages: [String]) -> String? {
        var searchFrom = text.startIndex
        while let fenceStart = text.range(of: "```", range: searchFrom..<text.endIndex) {
            let afterFence = fenceStart.upperBound
            guard let lineEnd = text[afterFence...].firstIndex(of: "\n") else { return nil }
            let language = text[afterFence..<lineEnd]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let contentStart = text.index(after: lineEnd)
            guard let fenceEnd = text.range(of: "```", range: contentStart..<text.endIndex) else { return nil }
            if languages.contains(language) {
                return String(text[contentStart..<fenceEnd.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            searchFrom = fenceEnd.upperBound
        }
        return nil
    }
}
