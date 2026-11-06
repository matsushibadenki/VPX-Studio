# 開発・リリース基準

リリース対象は `Config/ReleaseBaseline.json` に固定する。Swift Packageのdeployment targetはmacOS 15／iOS 18、開発・CIの基準はXcode 27.2／Swift 6.4.2とする。異なるツールチェーンへ移行するときは基準ファイルと検証結果を一緒に更新する。

MacはApple Silicon M1以降、メモリ8GiB以上（16GiB以上を推奨）を互換性の基準とする。iPhoneはiOS 18を実行できるXS／XS Max／XR以降、ARKit World Tracking対応を基準とし、iPhone 12以降を推奨する。LiDARは必須にせず、深度入力は12 Pro以降の対応Proモデルでのみ有効化する。各機能は実行時のcapability判定を優先する。

これは互換性の最低条件であり、全機種で4K60・10-bitを保証する認定表ではない。GPU・デコード・Wi-Fi・発熱を含む機種別実測はPendingとする。標準目標と実際に取得したフォーマットを区別して記録する。

## 計測の読み方

診断JSONの`metrics.pipeline`は、Host単調時刻を基準とする。値がない区間は省略し、0msとは区別する。

| 値 | 境界 |
| --- | --- |
| captureToEncodeMilliseconds | 取得→iPhone側のエンコード済みaccess unit準備完了。センサー配送・エンコード待機も含む |
| transportMilliseconds | エンコード済みunit準備完了→Hostアダプタ受信。暗号化・送信待機・Wi-Fi・復号を含む推定値 |
| captureToReceiveMilliseconds | 取得→Hostアダプタ受信。iPhoneでは同期推定を含み、エンコード・伝送を含む。純粋なネットワーク片道遅延ではない |
| receiveToDecodeMilliseconds | 受信→デコーダ投入。ジッターバッファ待機を含む |
| decodeMilliseconds | デコーダ投入→VideoToolbox完了通知 |
| decodeToRenderMilliseconds | デコード完了（ローカルは受信）→描画開始 |
| textureImportMilliseconds | CVMetalTextureCacheによる入力テクスチャ取得のCPU処理時間 |
| renderToPresentMilliseconds | 描画開始→Metal drawableのpresentedTime |
| captureToPresentMilliseconds | 取得→drawableのpresentedTime。ディスプレイスキャン／パネル応答の光学測定ではない |

コピー計数は表示経路で観測した入力フレームについて、VPXが明示的に実行した既知のCPUコピーだけを数える。未選択または描画前に上書きされたフレームは含めない。HEVC compressed access unitのCMBlockBuffer転送を1回として計測し、OS／ドライバ／VideoToolbox内部のコピー回数は不明である。ゼロという値は内部コピーもゼロという保証ではない。

`encodeCompletedNanoseconds`は映像ヘッダーの任意フィールドであり、旧Nodeでは未計測になる。上記の伝送値は時計同期の誤差を含み、純粋な無線伝搬時間を表さない。入力、伝送、デコード、GPU、表示の各区間を分けて比較する。

CVPixelBufferのアドレス、IOSurface IDの再観測を最新256フレームの窓で数える。再利用率は`pixelBufferReuseCount / observedFrames`、`ioSurfaceReuseCount / ioSurfaceFrames`で計算できる。アドレス再利用はプール実装の完全な証明ではない。メモリはHostプロセスのresident sizeであり、GPU専用メモリ・システム全体の使用量ではない。

## 検証

```sh
swift test
swift run VPXStudio
bash script/check_release_environment.sh
```

GUI・カメラ・LiDAR・ネットワーク・GPUの実機確認と、純粋なデータ契約の自動テストは別の結果として記録する。

## 固定入力ベンチマーク

入力パネルの「ベンチマークを実行」で、`vpx-fixed-pattern-pose-v1`を再生する。640×360 BGRA・60fps・120フレームの固定生成パターンと、対応する120サンプルの固定Poseログを使う。画像の内容とPoseの順序は毎回同じであり、実時間の処理性能やフレーム落ちまで同じになることを保証するものではない。

同じウィンドウサイズ・品質設定で実行し、診断アイコンの計測値とJSON書き出しを比較する。JSONの`benchmark`には入力定義、Poseログ、開始前の計測、実行中の計測、完了／中断状態が入る。累積カウンタは開始前との差分で比較する。別ソースへの切替はベンチマークを中断する。

診断JSON v4は実行OS、CPUアーキテクチャ、物理メモリ、Metalデバイス名も保存する。表示されなかった入力フレームがある場合、`benchmark.deliveredFrames`と`metrics.pipeline.observedFrames`の増分は一致しない。これは最新フレーム優先のmailboxであり、入力全数の収録保証ではない。

このハーネスは入力・バッファ・Metal・表示の回帰確認用であり、iPhoneのエンコード・Wi-Fi・HEVCデコード・4K60認定の代用ではない。未使用区間は未計測として出力する。

## 診断イベントの連続保存

診断履歴画面のドライブアイコンから保存先を選ぶと、JSONL形式でイベントを連続保存する。停止アイコンで同期・クローズし、プレビュー終了時も保存を停止する。画面の256件制限とは独立して保存する。

各行はスキーマ版、セッションID、イベント、直前に保存できなかったイベント数を持つ。ディスクが遅い場合は描画を止めず、保持窓からあふれた履歴を`omittedBeforeEvent`として明示する。書込みエラーはUIへ通知し、連続保存を停止する。保存ファイルは選択先の既存内容を置き換えるため、保存ダイアログの確認を行う。任意の途中行まで通常のJSONデコーダで解析できる。
