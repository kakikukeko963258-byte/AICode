import SwiftUI

enum Player: Equatable {
    case maru, batsu
    var symbol: String { self == .maru ? "○" : "×" }
    var other: Player { self == .maru ? .batsu : .maru }
    var color: Color { self == .maru ? .red : .blue }
}

/// 超シンプルなまるばつ（三目並べ）＋土壇場ルール
/// - ふつうの3x3。○が先手、タップで交互に置く。2人対戦（交互に渡す）。
/// - 上段の右の「枠の一個外」にもう1マス（位置9）がある。
/// - 枠外マスは土壇場でだけ解放される:
///     * 盤の空きが2マス以下になったとき
///     * または相手がリーチ（あと1手で3つ並ぶ）になったとき
///   解放中に1回だけ置ける。置くのも1手として数える。
/// - 枠外を使った勝ち筋は2つ:
///     * 枠外 - 上段まん中 - 上段右（横の延長）
///     * 枠外 - 中段右 - 下段まん中（斜め）
/// - 盤が全部埋まっても枠外が残っていれば、最後の1手として枠外勝負ができる。
struct ContentView: View {
    // 位置 0...8 = 盤（左上から右下）、9 = 枠外
    @State private var cells: [Int: Player] = [:]
    @State private var current: Player = .maru
    @State private var winner: Player? = nil
    @State private var winningLine: [Int] = []
    @State private var isDraw = false
    @State private var maruWins = 0
    @State private var batsuWins = 0
    @State private var draws = 0
    @State private var hint: String? = nil

    private let lines: [[Int]] = [
        [0, 1, 2], [3, 4, 5], [6, 7, 8],
        [0, 3, 6], [1, 4, 7], [2, 5, 8],
        [0, 4, 8], [2, 4, 6],
        [9, 1, 2], // 枠外 - 上段まん中 - 上段右
        [9, 5, 7], // 枠外 - 中段右 - 下段まん中
    ]

    private var boardFull: Bool { (0...8).allSatisfy { cells[$0] != nil } }
    private var outsideUsed: Bool { cells[9] != nil }
    private var gameOver: Bool { winner != nil || isDraw }
    private var emptyCount: Int { (0...8).filter { cells[$0] == nil }.count }

    private var outsideUnlocked: Bool {
        if outsideUsed { return false }
        if emptyCount <= 2 { return true }
        // 相手がリーチなら土壇場として解放
        let opp = current.other
        for line in lines {
            let marks = line.filter { cells[$0] == opp }.count
            let empty = line.filter { cells[$0] == nil }.count
            if marks == 2 && empty == 1 { return true }
        }
        return false
    }

    private var statusText: String {
        if let w = winner { return "\(w.symbol) の勝ち！" }
        if isDraw { return "引き分け" }
        if boardFull && !outsideUsed { return "土壇場！\(current.symbol) は枠外に置ける" }
        if outsideUnlocked { return "土壇場！枠外マス解放中（\(current.symbol) の番）" }
        return "\(current.symbol) の番"
    }

    var body: some View {
        VStack(spacing: 18) {
            Text("まるばつ")
                .font(.largeTitle.bold())
            Text(statusText)
                .font(.title3.bold())
                .foregroundStyle(winner != nil ? Color.orange : Color.primary)
                .multilineTextAlignment(.center)

            // 盤面: 上段の右に、枠の一個外のマスがはみ出す
            VStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 8) {
                        ForEach(0..<3, id: \.self) { col in
                            cellButton(position: row * 3 + col)
                        }
                        if row == 0 {
                            outsideButton
                        }
                    }
                }
            }

            if let hint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Text("○ \(maruWins) 勝　× \(batsuWins) 勝　引き分け \(draws)")
                .font(.headline)

            HStack(spacing: 12) {
                Button("次の対戦") { reset(clearScore: false) }
                    .buttonStyle(.borderedProminent)
                Button("スコア消去") { reset(clearScore: true) }
                    .buttonStyle(.bordered)
            }

            Text("ルール: 枠外マスは「盤の空きが2以下」か「相手がリーチ」の土壇場で解放され、1回だけ置けるよ。枠外-上段まん中-上段右、枠外-中段右-下段まん中の並びでも勝ち。盤が埋まっても枠外が残っていれば最後の1手になるよ。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func cellButton(position: Int) -> some View {
        Button {
            place(position)
        } label: {
            Text(cells[position]?.symbol ?? "")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(cells[position]?.color ?? .primary)
                .frame(width: 84, height: 84)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(winningLine.contains(position) ? Color.yellow.opacity(0.55) : Color.gray.opacity(0.15))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.gray.opacity(0.5), lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
    }

    private var outsideButton: some View {
        Button {
            place(9)
        } label: {
            VStack(spacing: 2) {
                if let p = cells[9] {
                    Text(p.symbol)
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(p.color)
                } else if outsideUnlocked {
                    Text("枠外")
                        .font(.headline.bold())
                        .foregroundStyle(.orange)
                    Text("置ける！")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                } else {
                    Text("枠外")
                        .font(.headline)
                        .foregroundStyle(.gray)
                    Text("🔒土壇場で解放")
                        .font(.caption2)
                        .foregroundStyle(.gray)
                }
            }
            .frame(width: 84, height: 84)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(winningLine.contains(9) ? Color.yellow.opacity(0.55)
                          : (outsideUnlocked && !outsideUsed ? Color.orange.opacity(0.18) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(outsideUnlocked && !outsideUsed ? Color.orange : Color.gray,
                            style: StrokeStyle(lineWidth: 2.5, dash: [7, 5]))
            )
        }
        .buttonStyle(.plain)
    }

    private func place(_ position: Int) {
        guard !gameOver, cells[position] == nil else { return }
        if position == 9 && !outsideUnlocked {
            hint = "枠外マスはまだ開いてないよ。盤の空きが2以下になるか、相手がリーチになったら解放されるよ。"
            return
        }
        hint = nil
        cells[position] = current

        if let line = lines.first(where: { l in l.allSatisfy { cells[$0] == current } }) {
            winner = current
            winningLine = line
            if current == .maru { maruWins += 1 } else { batsuWins += 1 }
            return
        }
        if boardFull && outsideUsed {
            isDraw = true
            draws += 1
            return
        }
        // 盤が埋まっても枠外が残っていれば、手番を渡して最後の枠外勝負へ
        current = current.other
    }

    private func reset(clearScore: Bool) {
        cells = [:]
        current = .maru
        winner = nil
        winningLine = []
        isDraw = false
        hint = nil
        if clearScore {
            maruWins = 0
            batsuWins = 0
            draws = 0
        }
    }
}

#Preview {
    ContentView()
}
