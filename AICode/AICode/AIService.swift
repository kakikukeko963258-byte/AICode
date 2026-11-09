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
    static let instructionsJA = """
    あなたは SwiftUI のコーディングアシスタントです。日本語で、簡潔に答えてください。
    コードやUI記述は、ユーザーが画面やコードを作るよう頼んだときだけ出してください。挨拶や普通の質問には、コードを出さず文章だけで答えてください。
    直前の自分の回答を繰り返さず、必ずユーザーの最新の発言に答えてください。
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

    /// English version of the instructions. Used when the on-device
    /// model's supported languages do not include Japanese: sessions
    /// whose instructions use an unsupported language make every
    /// request fail with `unsupportedLanguageOrLocale`, so the
    /// instructions follow the model, and the model is asked to
    /// answer in the user's language instead.
    static let instructionsEN = """
    You are a SwiftUI coding assistant. Reply concisely. If the user writes in Japanese, reply in Japanese.
    Only output code or a UI description when the user asks you to create a screen or code. For greetings and ordinary questions, answer in plain text without code.
    Never repeat your previous answer; always respond to the user's latest message.
    When you output code, wrap it in a ```swift fence.
    When asked to create a UI screen, in addition to the code also output a preview UI description in a ```json fence.
    The JSON must use ONLY this shape: {"type":"VStack","spacing":16,"padding":16,"children":[...]}
    Allowed type values: VStack, HStack, ZStack, Text, Button, Image, Spacer, Divider, TextField, Toggle, Slider, List
    Text: {"type":"Text","text":"Hello","font":"title","color":"blue","bold":true}
    Button: {"type":"Button","title":"+1","color":"red","action":"increment"} — action is one of increment / decrement / reset / toggle / none
    Image: {"type":"Image","systemName":"star.fill","color":"yellow"}
    TextField: {"type":"TextField","placeholder":"Name"}
    Toggle: {"type":"Toggle","label":"Turn on"}
    Slider: {"type":"Slider","value":0.5}
    List: {"type":"List","items":["Buy milk","Take out trash"]}
    In a Text that shows the counter, write "{counter}" (example: "Count: {counter}").
    Colors are one of red, blue, green, orange, purple, pink, yellow, gray, black, white or "#RRGGBB".
    font is one of title, title2, title3, headline, body, callout, subheadline, footnote, caption, largeTitle.
    Output exactly one valid JSON object. Do not mix Swift code into the JSON.
    """

    /// Whether the on-device model's supported languages include
    /// Japanese. `supportedLanguages` reflects the Apple Intelligence
    /// language configured on the device.
    static var modelSupportsJapanese: Bool {
        SystemLanguageModel.default.supportedLanguages.contains {
            $0.minimalIdentifier.hasPrefix("ja")
        }
    }

    /// Instructions for a new session, in a language the model
    /// supports: Japanese when supported, English otherwise.
    static var defaultInstructions: String {
        modelSupportsJapanese ? instructionsJA : instructionsEN
    }

    /// Maps a Foundation Models generation error to a user-facing
    /// error with a clear Japanese explanation, when one is known.
    static func mapGenerationError(_ error: Error) -> Error {
        guard let generationError = error as? LanguageModelSession.GenerationError else {
            return error
        }
        switch generationError {
        case .unsupportedLanguageOrLocale:
            return AIError.unavailable("AIの対応言語と端末の言語設定が合っていないようです。「設定」>「Apple IntelligenceとSiri」で言語を日本語に設定してから、もう一度お試しください。")
        case .guardrailViolation:
            return AIError.unavailable("その内容には回答できませんでした。別の聞き方を試してください。")
        case .assetsUnavailable:
            return AIError.unavailable("オンデバイスモデルを準備中です。しばらく待ってからもう一度お試しください。")
        case .concurrentRequests:
            return AIError.unavailable("AIが回答中です。終わるまでお待ちください。")
        default:
            return error
        }
    }

    /// Short diagnostics snapshot shown to the user when a language
    /// error occurs, so the device's actual language state can be
    /// reported back instead of guessed.
    var diagnosticsSummary: String {
        let model = SystemLanguageModel.default
        let languages = model.supportedLanguages
            .map(\.minimalIdentifier)
            .sorted()
            .joined(separator: ", ")
        return "対応言語: \(languages)\n端末ロケール: \(Locale.current.identifier)\nロケール対応: \(model.supportsLocale() ? "はい" : "いいえ")"
    }

    /// Generation options for every request. Random sampling with a
    /// temperature keeps replies from collapsing into the same output
    /// every time (the default sampling is near-deterministic, and the
    /// small on-device model otherwise echoes its previous answer).
    /// The token cap keeps one reply from filling the ~4k context
    /// window and crowding out the rest of the conversation.
    static let generationOptions = GenerationOptions(
        sampling: .random(probabilityThreshold: 0.9),
        temperature: 0.7,
        maximumResponseTokens: 1600
    )

    private var usingEnglishInstructions = false
    /// Fallback stage for language errors: 0 = locale phrase +
    /// supported-language instructions, 1 = English instructions,
    /// 2 = no instructions at all.
    private var fallbackStage = 0

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
    /// Instructions use a language the model supports, prefixed with
    /// Apple's recommended locale phrase ("The person's locale is
    /// ja_JP.") for non-U.S.-English locales.
    func startSession() {
        fallbackStage = 0
        startSession(english: !Self.modelSupportsJapanese)
    }

    func startSession(english: Bool) {
        usingEnglishInstructions = english
        let body = english ? Self.instructionsEN : Self.instructionsJA
        session = LanguageModelSession(instructions: Self.localePhrase + body)
    }

    /// Advances the language fallback chain after an
    /// `unsupportedLanguageOrLocale` error. Returns false when the
    /// chain is exhausted.
    private func advanceFallback() -> Bool {
        fallbackStage += 1
        switch fallbackStage {
        case 1:
            startSession(english: true)
            return true
        case 2:
            usingEnglishInstructions = true
            session = LanguageModelSession()
            return true
        default:
            return false
        }
    }

    /// The exact locale phrase from Apple's Foundation Models
    /// language guidance; empty for U.S. English.
    private static var localePhrase: String {
        let locale = Locale.current
        if Locale.Language(identifier: "en_US").isEquivalent(to: locale.language) {
            return ""
        }
        return "The person's locale is \(locale.identifier).\n"
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
        // Walk the language fallback chain (English instructions,
        // then no instructions) on `unsupportedLanguageOrLocale`
        // before giving up and surfacing the mapped, friendly message.
        while true {
            do {
                return try await streamOnce(prompt, onPartial: onPartial)
            } catch let generationError as LanguageModelSession.GenerationError {
                if case .unsupportedLanguageOrLocale = generationError, advanceFallback() {
                    continue
                }
                throw Self.mapGenerationError(generationError)
            }
        }
    }

    private func streamOnce(
        _ prompt: String,
        onPartial: @escaping (String) -> Void
    ) async throws -> String {
        guard let session else { throw AIError.notSupported }
        guard !session.isResponding else { throw AIError.unavailable("AIが回答中です。終わるまでお待ちください。") }

        var full = ""
        let stream = session.streamResponse(to: prompt, options: Self.generationOptions)
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
        do {
            let response = try await session.respond(to: prompt, options: Self.generationOptions)
            let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { throw AIError.emptyResponse }
            return response.content
        } catch {
            throw Self.mapGenerationError(error)
        }
    }
}
