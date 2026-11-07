import Foundation
import FoundationModels

/// Errors surfaced to the UI when the on-device model cannot be used.
enum AIError: LocalizedError {
    case unavailable(String)
    case notSupported
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return message
        case .notSupported:
            return "このデバイスでは Apple Intelligence (Foundation Models) を使えません。"
        case .emptyResponse:
            return "AI から回答が返ってきませんでした。もう一度お試しください。"
        }
    }
}

/// Thin wrapper around the Foundation Models framework (iOS 26).
///
/// - Deployment target is iOS 26, so these APIs are available at
///   compile time. Runtime availability is still checked before every
///   call: `SystemLanguageModel.default.availability` is `.available`
///   only on an Apple Intelligence-capable device (iPhone 15 Pro or
///   later) with Apple Intelligence turned on and the model ready.
/// - `LanguageModelSession` is stateful: prompts and responses are
///   appended to its transcript and count toward the ~4,096-token
///   context window. One session is kept per conversation.
/// - `streamResponse(to:)` yields partial `Response<String>` values
///   whose `.content` is the text generated so far; the UI updates
///   the chat bubble live from those partials.
/// - `LanguageModelSession` is not re-entrant: the UI disables Send
///   while a request is in flight.
@available(iOS 26, *)
@MainActor
final class AIService {

    /// The instructions given to every chat session. They tell the
    /// model to (1) answer coding questions in Japanese, (2) put
    /// SwiftUI code in a ```swift fence, and (3) when a visible UI
    /// is requested, also emit a ```json fence with a UINode
    /// description using ONLY the supported node types in
    /// `UIDescription.swift`. Anything outside that set is ignored
    /// by the preview renderer — by design, so arbitrary code can
    /// never run.
    static let instructions = """
    あなたは SwiftUI のコーディングアシスタントです。日本語で、簡潔に答えてください。
    コードを出すときは ```swift フェンスで囲んでください。
    画面のUIを作るよう頼まれたときは、コードに加えて、プレビュー用のUI記述も ```json フェンスで出してください。
    JSON は次の形だけを使ってください（これ以外の部品・キーは使いません）:
    {"type":"VStack","spacing":16,"padding":16,"children":[...]}
    使える type: VStack, HStack, ZStack, Text, Button, Image, Spacer, Divider, TextField, Toggle, Slider, List
    Text: {"type":"Text","text":"こんにちは","font":"title","color":"blue","bold":true}
    Button: {"type":"Button","title":"＋1","color":"red","action":"increment"} — action は increment / decrement / reset / toggle / none のいずれか
    Image: {"type":"Image","systemName":"star.fill","color":"yellow"}
    TextField: {"type":"TextField","placeholder":"名前"}
    Toggle: {"type":"Toggle","label":"オンにする"}
    Slider: {"type":"Slider","value":0.5}
    List: {"type":"List","items":["牛乳を買う","ゴミを出す"]}
    カウンターを表示する Text には "{counter}" と書いてください（例: "カウント: {counter}"）。
    色は red, blue, green, orange, purple, pink, yellow, gray, black, white の名前か "#RRGGBB" で指定してください。
    font は title, title2, title3, headline, body, callout, subheadline, footnote, caption, largeTitle のいずれか。
    JSON は必ず有効な JSON 1個だけにしてください。JSON の中に Swift コードを混ぜないでください。
    """

    private var session: LanguageModelSession?

    /// Returns `nil` when the on-device model can be used, otherwise a
    /// message explaining why not. Checked before every request.
    func availabilityMessage() -> String? {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "この iPhone は Apple Intelligence に対応していません。Foundation Models を使うには iPhone 15 Pro 以降が必要です。"
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence がオフになっています。「設定」>「Apple IntelligenceとSiri」からオンにしてください。"
            case .modelNotReady:
                return "オンデバイスモデルを準備中です。しばらく待ってからもう一度お試しください。"
            @unknown default:
                return "Apple Intelligence を現在利用できません。しばらく待ってからもう一度お試しください。"
            }
        }
    }

    /// Start (or restart) a chat session, e.g. for a new conversation.
    func startSession() {
        session = LanguageModelSession(instructions: Self.instructions)
    }

    /// Send a prompt and stream the reply. `onPartial` is called with
    /// the full text generated so far, each time a new chunk arrives.
    /// Returns the complete reply text.
    func sendStreaming(
        _ prompt: String,
        onPartial: @escaping (String) -> Void
    ) async throws -> String {
        if let message = availabilityMessage() {
            throw AIError.unavailable(message)
        }
        if session == nil {
            startSession()
        }
        guard let session else { throw AIError.notSupported }
        guard !session.isResponding else { throw AIError.unavailable("AIが回答中です。終わるまでお待ちください。") }

        var full = ""
        let stream = session.streamResponse(to: prompt)
        for try await partial in stream {
            full = partial.content
            onPartial(full)
        }
        let trimmed = full.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIError.emptyResponse }
        return full
    }

    /// Non-streaming one-shot call (kept for completeness / tests).
    func send(_ prompt: String) async throws -> String {
        if let message = availabilityMessage() {
            throw AIError.unavailable(message)
        }
        if session == nil {
            startSession()
        }
        guard let session else { throw AIError.notSupported }
        let response = try await session.respond(to: prompt)
        let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw AIError.emptyResponse }
        return response.content
    }
}
