import SwiftUI

/// AICode — Apple Intelligence (Foundation Models, iOS 26) を使った
/// AIチャット・コーディングアプリ。
///
/// できること:
/// - チャットでプロンプトを送り、オンデバイスAIからストリーミングで回答をもらう
/// - AIが生成した SwiftUI コードを Code タブで見てコピーする
/// - AIが出力した「UI記述JSON」を安全に解釈し、Preview タブに
///   実際の SwiftUI として描画する（＝ライブプレビュー）
///
/// できないこと（重要）:
/// - iOSアプリ内で任意の Swift をコンパイルして実行することはできない。
///   アプリ内に Swift コンパイラはなく、App Store の規約も
///   ダウンロードしたコードの実行を禁じている。
///   そのためプレビューは「AIがJSONで書いたUI記述を、アプリ側が
///   あらかじめ用意した部品だけに変換して描く」方式にしている。
///   詳しくは README.md と `UIDescription.swift` を参照。
@main
struct AICodeApp: App {
    @State private var store = ChatStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
        }
    }
}
