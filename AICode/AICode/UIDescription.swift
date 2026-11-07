import SwiftUI

// MARK: - Safe live preview: UI description, not code execution
//
// iOS apps cannot compile arbitrary Swift at runtime: there is no
// Swift compiler inside an app, and App Store rules forbid executing
// downloaded code. So the "live preview" in this app does NOT run
// AI-generated Swift. Instead:
//
// 1. The AI is instructed (see `AIService.instructions`) to also emit
//    a small JSON description of the UI, using ONLY the node types
//    below.
// 2. This file decodes that JSON into `UINode` values. Unknown types
//    and unknown keys are ignored — they can never become code.
// 3. `UINodeView` renders those values as real SwiftUI views, using
//    only components written in this file.
//
// Supported set (deliberately small):
//   VStack / HStack / ZStack, Text, Button, Image(system), Spacer,
//   Divider, TextField, Toggle, Slider, List
//   + color, padding, font, spacing, bold
//
// Interactive state lives in `PreviewState` (counter, toggle,
// slider, text field). Buttons only do the named actions
// (increment / decrement / reset / toggle / none). Text may contain
// "{counter}", "{toggle}", "{slider}" or "{text}" placeholders,
// which are replaced with the live state when rendered.

/// One node of the UI-description JSON.
struct UINode: Decodable, Equatable {
    var type: String
    var text: String?
    var title: String?
    var label: String?
    var placeholder: String?
    var systemName: String?
    var color: String?
    var background: String?
    var font: String?
    var bold: Bool?
    var spacing: Double?
    var padding: Double?
    var action: String?
    var isOn: Bool?
    var value: Double?
    var items: [String]?
    var children: [UINode]?

    enum CodingKeys: String, CodingKey {
        case type, text, title, label, placeholder, systemName, color,
             background, font, bold, spacing, padding, action, isOn,
             value, items, children
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Unknown / missing `type` degrades to a harmless Text node
        // instead of failing the whole preview.
        type = (try? c.decode(String.self, forKey: .type)) ?? "Text"
        text = try? c.decode(String.self, forKey: .text)
        title = try? c.decode(String.self, forKey: .title)
        label = try? c.decode(String.self, forKey: .label)
        placeholder = try? c.decode(String.self, forKey: .placeholder)
        systemName = try? c.decode(String.self, forKey: .systemName)
        color = try? c.decode(String.self, forKey: .color)
        background = try? c.decode(String.self, forKey: .background)
        font = try? c.decode(String.self, forKey: .font)
        bold = try? c.decode(Bool.self, forKey: .bold)
        spacing = try? c.decode(Double.self, forKey: .spacing)
        padding = try? c.decode(Double.self, forKey: .padding)
        action = try? c.decode(String.self, forKey: .action)
        isOn = try? c.decode(Bool.self, forKey: .isOn)
        value = try? c.decode(Double.self, forKey: .value)
        items = try? c.decode([String].self, forKey: .items)
        children = try? c.decode([UINode].self, forKey: .children)
    }

    /// Decode a JSON string into a node, or return `nil` (with the
    /// reason) so the UI can show a parse error instead of crashing.
    /// Accepts either a bare node object or `{"ui": <node>}`.
    static func decode(from jsonString: String) -> Result<UINode, Error> {
        guard let data = jsonString.data(using: .utf8) else {
            return .failure(PreviewError.invalidJSON("JSONを読み取れませんでした。"))
        }
        do {
            return .success(try JSONDecoder().decode(UINode.self, from: data))
        } catch {
            // Try the {"ui": ...} wrapper before giving up.
            struct Wrapper: Decodable { var ui: UINode }
            do {
                let wrapped = try JSONDecoder().decode(Wrapper.self, from: data)
                return .success(wrapped.ui)
            } catch {
                return .failure(PreviewError.invalidJSON("プレビュー用JSONを解釈できませんでした: \(error.localizedDescription)"))
            }
        }
    }
}

enum PreviewError: LocalizedError {
    case invalidJSON(String)
    var errorDescription: String? {
        if case .invalidJSON(let message) = self { return message }
        return nil
    }
}

// MARK: - Colour / font helpers

func previewColor(from name: String?) -> Color {
    guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          !name.isEmpty else { return .primary }
    switch name {
    case "red": return .red
    case "blue": return .blue
    case "green": return .green
    case "orange": return .orange
    case "purple": return .purple
    case "pink": return .pink
    case "yellow": return .yellow
    case "gray", "grey": return .gray
    case "black": return .black
    case "white": return .white
    case "secondary": return .secondary
    case "clear": return .clear
    default:
        // "#RRGGBB" (and "#RGB") support.
        var hex = name
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return .primary }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

func previewFont(from name: String?) -> Font {
    switch name?.lowercased() {
    case "largetitle": return .largeTitle
    case "title": return .title
    case "title2": return .title2
    case "title3": return .title3
    case "headline": return .headline
    case "subheadline": return .subheadline
    case "callout": return .callout
    case "footnote": return .footnote
    case "caption": return .caption
    default: return .body
    }
}

// MARK: - Interactive preview state

/// The only mutable state a preview can touch. Buttons can only
/// increment / decrement / reset the counter or flip the toggle;
/// nothing in the JSON can run code or reach outside this object.
@Observable
final class PreviewState {
    var counter = 0
    var isOn = true
    var sliderValue = 0.5
    var textInput = ""
}

// MARK: - Renderer

/// Renders a `UINode` as real SwiftUI, using only the components in
/// this file. Unknown node types render as a small grey note, never
/// as an error and never as executed code.
struct UINodeView: View {
    let node: UINode
    @Bindable var state: PreviewState

    var body: some View {
        switch node.type.lowercased() {
        case "vstack":
            VStack(alignment: .leading, spacing: node.spacing ?? 12) {
                children
            }
            .padding(node.padding ?? 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(previewColor(from: node.background).opacity(node.background == nil ? 0 : 1))
        case "hstack":
            HStack(spacing: node.spacing ?? 12) {
                children
            }
            .padding(node.padding ?? 0)
            .background(previewColor(from: node.background).opacity(node.background == nil ? 0 : 1))
        case "zstack":
            ZStack {
                children
            }
            .padding(node.padding ?? 0)
        case "text":
            Text(substituted(node.text ?? ""))
                .font(previewFont(from: node.font))
                .bold(node.bold ?? false)
                .foregroundStyle(previewColor(from: node.color))
                .padding(node.padding ?? 0)
        case "button":
            Button(node.title ?? node.text ?? "ボタン") {
                performAction(node.action)
            }
            .buttonStyle(.borderedProminent)
            .tint(previewColor(from: node.color))
            .padding(node.padding ?? 0)
        case "image":
            Image(systemName: node.systemName ?? "photo")
                .font(previewFont(from: node.font))
                .foregroundStyle(previewColor(from: node.color))
                .padding(node.padding ?? 0)
        case "spacer":
            Spacer()
        case "divider":
            Divider()
        case "textfield":
            TextField(node.placeholder ?? "", text: Binding(
                get: { state.textInput },
                set: { state.textInput = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .padding(node.padding ?? 0)
        case "toggle":
            Toggle(node.label ?? node.title ?? "オン", isOn: Binding(
                get: { state.isOn },
                set: { state.isOn = $0 }
            ))
            .onAppear { if let isOn = node.isOn { state.isOn = isOn } }
            .padding(node.padding ?? 0)
        case "slider":
            Slider(value: Binding(
                get: { state.sliderValue },
                set: { state.sliderValue = $0 }
            ), in: 0...1)
            .onAppear { if let value = node.value { state.sliderValue = value } }
            .padding(node.padding ?? 0)
        case "list":
            VStack(alignment: .leading, spacing: 0) {
                ForEach(node.items ?? [], id: \.self) { item in
                    Text(substituted(item))
                        .padding(.vertical, 8)
                    if item != node.items?.last {
                        Divider()
                    }
                }
            }
            .padding(node.padding ?? 0)
        default:
            Text("プレビュー未対応の部品です: \(node.type)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var children: some View {
        ForEach(Array((node.children ?? []).enumerated()), id: \.offset) { _, child in
            UINodeView(node: child, state: state)
        }
    }

    private func substituted(_ text: String) -> String {
        text
            .replacingOccurrences(of: "{counter}", with: "\(state.counter)")
            .replacingOccurrences(of: "{toggle}", with: state.isOn ? "オン" : "オフ")
            .replacingOccurrences(of: "{slider}", with: String(format: "%.2f", state.sliderValue))
            .replacingOccurrences(of: "{text}", with: state.textInput)
    }

    private func performAction(_ action: String?) {
        switch action?.lowercased() {
        case "increment": state.counter += 1
        case "decrement": state.counter -= 1
        case "reset": state.counter = 0
        case "toggle": state.isOn.toggle()
        default: break // "none" or unknown: do nothing, by design
        }
    }
}
