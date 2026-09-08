# VPX Studio

Apple Silicon向けのリアルタイム・バーチャルプロダクション基盤です。

## 現在の実装

- MetalKitによる60fpsプレビュー土台
- デバイス／映像／Pose／レンズ／深度の共通データ契約
- 依存関係を検証するRealtime Frame Graph
- iPhone Capture Nodeを接続するためのアダプタ境界
- SwiftUIのスタジオ画面
- 日本語、English、简体中文を実行中に切り替えるローカライズカタログ
- システム設定、ライト、ダークを切り替える表示モード

## 起動

```sh
swift run VPXStudio
```

Xcodeで開発する場合は、`Package.swift`を開きます。

## 表示言語の追加

`Sources/VPXStudio/Resources/LocalizationCatalog.json` の `languages` 配列に、
`id`、表示名、既存キーすべての翻訳を持つ言語オブジェクトを追加します。言語選択メニューはカタログを読み込むため、Swiftコードを変更せずに候補へ追加されます。

## 次の実装

- [Next] AVFoundationによるローカル映像入力
- [Next] iPhone Capture Node（ARKit Pose、CoreMotion、深度、LAN時刻同期）
- [Next] Metal texture入力、カメラ補正、基本3Dシーン
- [Later] SDI/NDI、外部トラッカー、Take収録、LED wall出力
