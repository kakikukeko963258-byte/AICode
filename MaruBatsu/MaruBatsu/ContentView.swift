import SwiftUI

enum Player: Equatable {
    case maru, batsu
    var symbol: String { self == .maru ? "○" : "×" }
    var other: Player { self == .maru ? .batsu : .maru }
    var color: Color { self == .maru ? .red : .blue }
}

/// まるばつ v2
/// 画面には中央の「井」だけ。タイトル・状態表示・スコア・説明などの文字は一切なし。
/// 盤は実は5x5（座標 -1...3）。内側3x3を囲う外周16マスは見えない隠しマスで、
/// 土壇場（内側の空きが2以下、または相手がリーチ）になると置けるようになる。
/// 知っている人だけが使える。勝ち筋は5x5の中の全ての3連（横・縦・斜め）。
/// ゲームが終わると、リトライボタン（アイコンのみ）がフェードインする。
struct ContentView: View {
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
                // ゲーム終了後にだけフェードインするリトライボタン（アイコンのみ）
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
            // 縦2本
            for i in 1...2 {
                let x = s * CGFloat(i + 1)
                path.move(to: CGPoint(x: x, y: s - ext))
                path.addLine(to: CGPoint(x: x, y: s * 4 + ext))
            }
            // 横2本
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

#Preview {
    ContentView()
}
