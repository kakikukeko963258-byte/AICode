# AICode — Apple Intelligence チャット・コーディングアプリ

SwiftUIで作る、Apple Intelligence（Foundation Models, iOS 26）を使った
AIチャット・コーディングアプリのスターター。チャットでプロンプトを送ると
オンデバイスAIがストリーミングで回答し、生成した SwiftUI コードを
見てコピーでき、AIが出したUI記述をプレビューとして実際に描画する。

> **前のメモアプリからの置き換えです。** このフォルダには以前
> メモ要約アプリ（AIMemo）がありましたが、ユーザーの要望で
> このAIチャット・コーディングアプリ（AICode）に置き換えました。
> AIMemo のファイルは残っていません。

## 画面（3タブ）

| タブ | 内容 |
|---|---|
| **チャット** | プロンプトを送るとオンデバイスAIがストリーミングで回答。会話履歴を保持する。サンプル（下記）もここから試せる |
| **コード** | AIが生成した最新の SwiftUI コードを等幅フォントで表示。コピーボタン付き |
| **プレビュー** | AIが出したUI記述JSONを実際の SwiftUI として描画するライブプレビュー。ボタンが本当に動く（カウンター +1 など） |

## ライブプレビューの限界 — 必ず読んでください

**このアプリは、AIが生成した Swift コードをアプリ内でコンパイル・
実行しません。できません。**

- iOSアプリの中に Swift コンパイラはない
- App Store の規約は、ダウンロードしたコードの実行を禁じている

その代わり、**安全なプレビュー**を実装している：

1. AIには「コードに加えて、UI記述JSONも ```json フェンスで出す」よう指示している（`AICode/AICode/AIService.swift` の `instructions`）
2. JSONで使えるのは、あらかじめ決めた小さな部品だけ
   （`AICode/AICode/UIDescription.swift`）：
   `VStack / HStack / ZStack, Text, Button, Image(system), Spacer,
   Divider, TextField, Toggle, Slider, List` ＋ 色・padding・font
3. アプリはそのJSONを `UINode` にデコードし、このファイルに書かれた
   部品だけで描画する。知らない部品・キーは無視される。
   ボタンができるのは `increment / decrement / reset / toggle / none`
   だけ。JSONの中身がどんなに怪しくても、コードは実行されない
4. チャットの回答がストリーミングで届く間、JSONが完成するたびに
   プレビューが更新される（＝ライブプレビュー）

つまり「AIが書いたSwiftUIそのものが動く」のではなく、
「AIがJSONで書いた画面設計図を、アプリが安全に描き直す」方式。
本物の SwiftUI コードは Code タブからコピーして Xcode に貼ると動く。

## サンプル（AIなしでも動く）

チャット画面のチップ、または Code / Preview タブから選べる：

1. **赤いボタンとカウンター** — 「＋1」ボタンでカウントが増える
2. **プロフィールカード** — アイコン・名前・紹介文のカード
3. **ToDoリスト** — テキストフィールド、トグル、スライダー、リスト

サンプルはAIを使わないので、Apple Intelligence が使えない端末でも
コードとプレビューを試せる。

## 必要条件

- **ビルド**: Xcode 26（iOS 26 SDK）、Swift 6、macOS 26
  - GitHub Actions では `macos-26` ランナーでビルドする
  - 手元で開く場合も Xcode 26 が必要（Xcode 25 以前では
    Foundation Models がないためコンパイルできない）
- **実行・AI機能**: iOS 26、Apple Intelligence 対応 iPhone
  （**iPhone 15 Pro 以降**）、Apple Intelligence をオン
  - 対応していない端末では、アプリ内に理由が表示され、
    AIチャット・要約は無効になる。サンプルはそのまま試せる
  - Foundation Models はオンデバイスで動く（約3Bパラメータ）。
    APIキー・課金・ネットワークは不要。コンテキストは約4,096トークン

## プロジェクト構成

```
apple-intelligence-app/
├── README.md
├── .github/workflows/build-ipa.yml   # macos-26 で unsigned .ipa を作る
└── AICode/
    ├── AICode.xcodeproj/project.pbxproj
    └── AICode/
        ├── AICodeApp.swift       # @main, ChatStore を environment に渡す
        ├── ContentView.swift     # チャット / コード / プレビューの3タブ
        ├── ChatView.swift        # チャット画面・サンプルチップ
        ├── CodeView.swift        # 生成コード表示・コピー
        ├── PreviewView.swift     # JSONプレビュー表示
        ├── ChatStore.swift       # 会話状態、```swift / ```json の抽出、サンプル適用
        ├── AIService.swift       # Foundation Models: availability 判定 + ストリーミング
        ├── UIDescription.swift   # UI記述JSONのモデル・デコード・安全なレンダラー
        ├── Samples.swift         # サンプル3件（プロンプト・コード・JSON）
        ├── Info.plist
        └── Assets.xcassets/      # AppIcon (1024px)・AccentColor
```

- バンドルID: `com.kakuei.aicode`（プレースホルダー。自分のものに変えてください）
- デプロイメントターゲット: iOS 26.0、Swift 6、SwiftUI
- 依存関係なし（Foundation Models はシステムフレームワーク）

## GitHub Actions で .ipa を作る

1. このフォルダの内容を GitHub リポジトリに push する
2. Actions タブで **Build unsigned IPA** が走る（push / PR / 手動実行）
3. 完了後、Artifacts から **AICode-unsigned**（`AICode-unsigned.ipa`）をダウンロード

ワークフローは `CODE_SIGNING_ALLOWED=NO` でアーカイブし、
`.xcarchive` 内の `.app` を `Payload/` に入れて zip した
**unsigned .ipa** を作る。`xcodebuild -exportArchive` は使っていない
（署名なしでは失敗するため）。

## unsigned .ipa を iPhone に入れるには

**unsigned .ipa はそのままでは iPhone にインストールできない。**
次のどちらかが必要：

- **無料の Apple ID で再署名**: Xcode で自分の Apple ID を使い
  プロジェクトを開いて実機ビルドするのが一番確実。
  または AltStore / SideStore などに unsigned .ipa を渡して
  自分の Apple ID で署名してインストールする
- **有料の Apple Developer Program（年額 $99）**: 証明書と
  プロビジョニングプロファイルを用意し、ワークフローに署名
  ステップを追加すれば、署名済み .ipa / TestFlight 配布ができる
  （このリポジトリには証明書・秘密鍵・シークレットは含めないこと）

## 制限・未検証の点

- この Linux VM には Xcode がないため、**コンパイルは未検証**。
  ソースとワークフローは iOS 26 / Xcode 26 の公開APIに沿って
  書いているが、初めてのビルドは GitHub Actions のログで確認すること
- Foundation Models のストリーミングは `streamResponse(to:)` の
  partial `.content` を「これまでの全文」として扱っている。
  SDK の挙動が変わる場合は `AIService.swift` を見直すこと
- プレビューは対応部品のみ。`NavigationStack`、画像読み込み、
  ネットワーク、複雑なレイアウトは JSON では表現できない
- AIの回答はオンデバイスモデル（約3B）によるもので、長いコードや
  正確なAPI知識には限界がある。生成コードは Xcode で確認すること
