import SwiftUI

enum Player: Equatable {
    case maru, batsu
    var symbol: String { self == .maru ? "○" : "×" }
    var other: Player { self == .maru ? .batsu : .maru }
    var color: Color { self == .maru ? .red : .blue }
}

/// ルート: モード1（従来の隠し土壇場マス）とモード2（最大4人・盤サイズ可変）を切り替える。
/// 画面右上の小さい歯車から設定シートを開く。ゲーム画面自体はどちらのモードも文字なし。
struct ContentView: View {
    @State private var mode = 1
    @State private var playerCount = 2
    @State private var boardSize = 3
    @State private var showSettings = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if mode == 1 {
                Mode1View()
            } else {
                Mode2View(playerCount: playerCount, size: boardSize)
            }
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .padding(14)
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                Form {
                    Section("モード") {
                        Picker("モード", selection: $mode) {
                            Text("モード1（土壇場マス）").tag(1)
                            Text("モード2（みんなで）").tag(2)
                        }
                        .pickerStyle(.segmented)
                    }
                    if mode == 2 {
                        Section("モード2の設定") {
                            Picker("プレイヤー", selection: $playerCount) {
                                Text("2人").tag(2)
                                Text("3人").tag(3)
                                Text("4人").tag(4)
                            }
                            .pickerStyle(.segmented)
                            Picker("盤の大きさ", selection: $boardSize) {
                                Text("3×3").tag(3)
                                Text("4×4").tag(4)
                                Text("5×5").tag(5)
                                Text("6×6").tag(6)
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                }
                .navigationTitle("設定")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("閉じる") { showSettings = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }
}

// MARK: - モード1

/// モード1: 画面には中央の「井」だけ。盤は実は5x5（座標 -1...3）。
/// 内側3x3を囲う外周16マスは見えない隠しマスで、土壇場（内側の空きが2以下、
/// または相手がリーチ）になると置ける。勝ち筋は5x5の中の全ての3連。
/// ゲームが終わるとリトライボタン（アイコンのみ）がフェードインする。
struct Mode1View: View {
    // id = (row + 1) * 5 + (col + 1), row/col は -1...3
    @State private var cells: [Int: Player] = [:]
    @State private var current: Player = .maru
    @State private var gameOver = false

    private let cellSize: CGFloat = 68

    private let lines: [[Int]] = {
        func id(_ r: Int, _ c: Int) -> Int { (r + 1) * 5 + (c + 1) }
        var ls: [[Int]] = []
        for r in -1...3 { for c in -1...1 { ls.append([id(r, c), id(r, c + 1), id(r, c + 2)]) } }
        for c in -1...3 { for r in -1...1 { ls.append([id(r, c), id(r + 1, c), id(r + 2, c)]) } }
        for r in -1...1 { for c in -1...1 { ls.append([id(r, c), id(r + 1, c + 1), id(r + 2, c + 2)]) } }
        for r in -1...1 { for c in 1...3 { ls.append([id(r, c), id(r + 1, c - 1), id(r + 2, c - 2)]) } }
        return ls
    }()

    private func isInner(_ id: Int) -> Bool {
        let r = id / 5 - 1
        let c = id % 5 - 1
        return (0...2).contains(r) && (0...2).contains(c)
    }

    private var innerEmptyCount: Int {
        (0..<25).filter { isInner($0) && cells[$0] == nil }.count
    }

    /// 土壇場かどうか: 内側の空きが2以下、または相手がリーチ
    private var ringOpen: Bool {
        if innerEmptyCount <= 2 { return true }
        let opp = current.other
        return lines.contains { line in
            line.filter { cells[$0] == opp }.count == 2 && line.contains { cells[$0] == nil }
        }
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 28) {
                board
                Button {
                    reset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 56, height: 56)
                        .background(Circle().stroke(Color.primary.opacity(0.6), lineWidth: 2))
                }
                .opacity(gameOver ? 1 : 0)
                .allowsHitTesting(gameOver)
                .animation(.easeInOut(duration: 0.9), value: gameOver)
            }
        }
    }

    private var board: some View {
        ZStack {
            gridLines
            VStack(spacing: 0) {
                ForEach(-1...3, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(-1...3, id: \.self) { col in
                            cellButton(id: (row + 1) * 5 + (col + 1))
                        }
                    }
                }
            }
        }
        .frame(width: cellSize * 5, height: cellSize * 5)
    }

    /// 中央の「井」: 内側3x3の罫線だけを描く（少しはみ出させて井らしく）
    private var gridLines: some View {
        let s = cellSize
        let ext: CGFloat = 12
        return Path { path in
            for i in 1...2 {
                let x = s * CGFloat(i + 1)
                path.move(to: CGPoint(x: x, y: s - ext))
                path.addLine(to: CGPoint(x: x, y: s * 4 + ext))
            }
            for i in 1...2 {
                let y = s * CGFloat(i + 1)
                path.move(to: CGPoint(x: s - ext, y: y))
                path.addLine(to: CGPoint(x: s * 4 + ext, y: y))
            }
        }
        .stroke(Color.primary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
        .frame(width: cellSize * 5, height: cellSize * 5)
    }

    private func cellButton(id: Int) -> some View {
        Button {
            place(id)
        } label: {
            Text(cells[id]?.symbol ?? "")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(cells[id]?.color ?? .primary)
                .frame(width: cellSize, height: cellSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func place(_ id: Int) {
        guard !gameOver, cells[id] == nil else { return }
        // 隠しマス（外周）は土壇場以外は反応しない
        if !isInner(id) && !ringOpen { return }
        cells[id] = current
        if lines.contains(where: { line in line.allSatisfy { cells[$0] == current } }) {
            gameOver = true
            return
        }
        if cells.count == 25 {
            gameOver = true
            return
        }
        current = current.other
    }

    private func reset() {
        cells = [:]
        current = .maru
        gameOver = false
    }
}

// MARK: - モード2

/// モード2の記号。順番は ○ → × → ▲ → ■。
/// 色は 丸=赤、バツ=青、三角=黄、四角=緑。
enum Mark: Equatable {
    case maru, batsu, sankaku, shikaku

    var symbol: String {
        switch self {
        case .maru: return "○"
        case .batsu: return "×"
        case .sankaku: return "▲"
        case .shikaku: return "■"
        }
    }
    var color: Color {
        switch self {
        case .maru: return .red
        case .batsu: return .blue
        case .sankaku: return Color(red: 0.92, green: 0.68, blue: 0.05) // 黄（読みやすい金黄）
        case .shikaku: return .green
        }
    }
    static let order: [Mark] = [.maru, .batsu, .sankaku, .shikaku]
}

/// モード2: 最大4人、盤は 3x3〜6x6 の任意サイズ。周りには置けない（盤の中だけ）。
/// 勝ちは盤サイズ分を1列に揃えること（横・縦・斜め）。画面は盤と記号だけ、
/// 終わるとリトライボタンがフェードインする（モード1と同じ作法）。
struct Mode2View: View {
    let playerCount: Int
    let size: Int

    @State private var cells: [Int: Mark] = [:] // id = row * size + col
    @State private var turnIndex = 0
    @State private var gameOver = false

    private var players: [Mark] { Array(Mark.order.prefix(playerCount)) }
    private var current: Mark { players[turnIndex % players.count] }
    private var cellSize: CGFloat { 336 / CGFloat(size) }

    private var lines: [[Int]] {
        var ls: [[Int]] = []
        for r in 0..<size { ls.append((0..<size).map { r * size + $0 }) }
        for c in 0..<size { ls.append((0..<size).map { $0 * size + c }) }
        ls.append((0..<size).map { $0 * size + $0 })
        ls.append((0..<size).map { $0 * size + (size - 1 - $0) })
        return ls
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 28) {
                board
                Button {
                    reset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 56, height: 56)
                        .background(Circle().stroke(Color.primary.opacity(0.6), lineWidth: 2))
                }
                .opacity(gameOver ? 1 : 0)
                .allowsHitTesting(gameOver)
                .animation(.easeInOut(duration: 0.9), value: gameOver)
            }
        }
        .onChange(of: playerCount) { _, _ in reset() }
        .onChange(of: size) { _, _ in reset() }
    }

    private var board: some View {
        ZStack {
            gridLines
            VStack(spacing: 0) {
                ForEach(0..<size, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<size, id: \.self) { col in
                            cellButton(id: row * size + col)
                        }
                    }
                }
            }
        }
        .frame(width: cellSize * CGFloat(size), height: cellSize * CGFloat(size))
    }

    private var gridLines: some View {
        let s = cellSize
        let n = CGFloat(size)
        let ext: CGFloat = 10
        return Path { path in
            for i in 1..<size {
                let p = s * CGFloat(i)
                path.move(to: CGPoint(x: p, y: -ext))
                path.addLine(to: CGPoint(x: p, y: s * n + ext))
                path.move(to: CGPoint(x: -ext, y: p))
                path.addLine(to: CGPoint(x: s * n + ext, y: p))
            }
        }
        .stroke(Color.primary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
        .frame(width: cellSize * n, height: cellSize * n)
    }

    private func cellButton(id: Int) -> some View {
        Button {
            place(id)
        } label: {
            ZStack {
                if let mark = cells[id] {
                    MarkView(mark: mark, size: cellSize * 0.62)
                }
            }
            .frame(width: cellSize, height: cellSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func place(_ id: Int) {
        guard !gameOver, cells[id] == nil else { return }
        cells[id] = current
        if lines.contains(where: { line in line.allSatisfy { cells[$0] == current } }) {
            gameOver = true
            return
        }
        if cells.count == size * size {
            gameOver = true
            return
        }
        turnIndex += 1
    }

    private func reset() {
        cells = [:]
        turnIndex = 0
        gameOver = false
    }
}

/// モード2の記号描画。4記号とも同じ線幅のアウトライン（中空）で描く。
struct MarkView: View {
    let mark: Mark
    let size: CGFloat

    var body: some View {
        let lw = size * 0.13
        let m = size * 0.07 // 線の端がはみ出さない余白
        ZStack {
            switch mark {
            case .maru:
                Circle()
                    .strokeBorder(mark.color, lineWidth: lw)
            case .batsu:
                Path { path in
                    path.move(to: CGPoint(x: m, y: m))
                    path.addLine(to: CGPoint(x: size - m, y: size - m))
                    path.move(to: CGPoint(x: size - m, y: m))
                    path.addLine(to: CGPoint(x: m, y: size - m))
                }
                .stroke(mark.color, style: StrokeStyle(lineWidth: lw, lineCap: .round))
            case .sankaku:
                Path { path in
                    path.move(to: CGPoint(x: size / 2, y: m))
                    path.addLine(to: CGPoint(x: size - m, y: size - m))
                    path.addLine(to: CGPoint(x: m, y: size - m))
                    path.closeSubpath()
                }
                .stroke(mark.color, style: StrokeStyle(lineWidth: lw, lineJoin: .round))
            case .shikaku:
                Rectangle()
                    .strokeBorder(mark.color, lineWidth: lw)
                    .padding(m)
            }
        }
        .frame(width: size, height: size)
    }
}

#Preview {
    ContentView()
}
