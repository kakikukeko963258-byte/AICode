# 長時間露光

iPhone用の長時間露光カメラ。元のAICodeコミット `3b4cdca31f8157b2aec7a56138bea9499e8c4f7c` を維持した `long-exposure` ブランチで開発しています。既存のAICodeソースは残し、独立した撮影アプリをビルドします。

Bundle IDはmainと同じ `com.kakikukeko.main`。このPCの署名では `com.kakikukeko.main.6X8S588GJ6` となり、現在のAICode/mainアプリを上書きします。

- スロー：0.5〜600秒。線形色空間で連続フレームを平均し、水・雲などの動きを滑らかにします。
- 光跡：0.5〜600秒。連続フレームの明るい部分を残します。
- センサー：端末が現在のカメラ形式で許可する露光時間内で、1枚の写真を撮影します。ISOは撮影前の自動測光値または手動指定です。指定ISOは端末の対応範囲に収めます。
- 3秒・10秒タイマー、途中終了（合成モード）、撮影中の合成プレビュー、写真保存、共有。

三脚などで固定して撮影してください。撮影中は画面を開いたままにします。バックグラウンドに移ると合成モードはその時点の画像を保存し、センサー撮影は中断します。

スローと光跡は連続フレームの合成です。センサーを600秒間連続露光する機能ではありません。動体位置合わせはありません。合成は最大1920×1080相当のカメラ出力（縦向きでは1080×1920）を使い、撮影端末での画角・解像度に依存します。写真はsRGB JPEGで保存します。RAW撮影は含みません。

露光・フォーカス・ホワイトバランスは撮影開始時に固定します。スローは平均合成のため、撮影時間が長くなっても静止物の明るさは増えません。

写真への追加が許可されない場合も「ファイル」→「このiPhone内」→「長時間露光」にJPEGを残し、共有から書き出せます。アプリ内のJPEGは自動削除しません。

## ビルドと導入

`.github/workflows/long-exposure.yml` はGitHub ActionsのmacOS runnerとXcodeでIPAを生成します。公開リポジトリのlong-exposureブランチへpushすると開始し、`LongExposure-unsigned` Artifactを出力します。

未署名IPAは、そのままiPhoneへインストールできません。設定済みAltForge Remoteの `Install-With-Plume.ps1` で既存mainのIDに署名して転送します。証明書・Apple ID・端末登録情報はリポジトリに含めません。

Appleのセンサー露光制約： https://developer.apple.com/documentation/avfoundation/avcapturedevice/exposureduration

実機の起動・撮影・写真保存は、ビルドおよびインストールの成功とは別に確認する必要があります。
