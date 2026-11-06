# Phase 2 — Capture Node実装と受入手順

## 実装範囲

単一iPhoneからMacへ映像・Pose・IMU・任意のLiDAR深度を送る。開発環境で実装・プロトコル検証を完了し、実機での性能・権限・センサー受入はROADMAPのPendingに分ける。

### 撮影モード

| モード | カメラ所有者 | 送信データ |
| --- | --- | --- |
| ARトラッキング有効 | ARSession | 同じARFrameの映像・World Pose・取得時刻、直近のCoreMotion、任意のscene depth |
| 映像専用 | AVCaptureSession | 背面広角カメラの1080p映像・取得時刻・カメラID・色メタデータ |

2つのSessionを同時に動かさない。AR非対応の場合は映像専用へ制限する。モード・深度設定は接続前に選択する。接続中の設定変更には再接続が必要。LiDAR非搭載、AR無効、深度無効の場合はHelloのdepth能力を通知しない。

映像ヘッダーはsequenceをframe IDとして使い、センサー取得時の単調増加時計のナノ秒時刻を記録する。AVCaptureはサンプルPTS、ARKitはARFrame.timestampを使い、受信時刻で代用しない。色メタデータとカメラ情報はHEVCヘッダーを通して保持する。ARKitでは3×3内部パラメータを列優先で付与する。取得できない値を推測で埋めない。

HEVCエンコーダは入力バッファの実寸を使う。既存のUHD60ビットレートプロファイル指定は、実際に全機種が4K60／10-bitで取得できる保証ではない。形式・性能の認定はPending。

CoreMotionの角速度はrad/s、userAccelerationはm/s²に変換し、端末座標系の値としてPoseに添付する。最新サンプルがARFrameから50ms以上離れた場合は加速度を省略し、角速度をゼロにする。ARKitのWorld Poseと端末IMUの座標系を同一視した融合は行わない。モーション取得は任意で、利用不可でも映像・ARKitを継続できる。

### Protocol v2

| 経路 | 内容 | 制御 |
| --- | --- | --- |
| Bonjour `_vpxcapture._tcp` | Mac発見 | アプリのローカルネットワーク権限 |
| TCP + AES-GCM | Hello、制御、HEVC、深度、4タイムスタンプ交換、重要品質遷移 | QR共有256-bit資格情報、長さフレーミング |
| UDP + AES-GCM | Pose・IMU、診断 | TCPから通知されたNode ID／接続トークン／ポート、1200バイト上限、128パケットのリプレイ窓 |

TCPのHelloが認証されてからUDPセッションを結び付ける。再接続ごとに接続トークンを更新する。異なるNode／トークン、暗号認証失敗、過大なデータグラム、重複・古すぎるsequenceは使用しない。UDP障害時にPoseをTCPへ暗黙に移さない。HostはTCP接続を保持し、EOF／接続断で同期・Pose・深度を無効化する。再接続時はNode能力を更新する。

同じProtocol v2のMac／iPhoneを使用する。Hostは旧版・未知版のHelloを拒否する。この方式は共有秘密によるアプリケーション層AEADであり、TLS・証明書認証・前方秘匿性の実装ではない。端末別資格情報・失効・証明書はPhase 4以降。

### 深度

ARKit sceneDepthのFloat32メートル値とUInt8 confidence（0／1／2）を行paddingなしで送る。iPhoneはlittle endianなのでwire形式は`depth-float32-le`。同じARFrameのsequence／取得時刻／寸法を添える。confidenceが取得できない場合は深度パケットを送らない。

送信上限は5fps。Macは1024×1024以下、深度バイト数width×height×4、confidenceバイト数width×height、confidence値の範囲を検証する。Nodeにつき最新1フレームだけ保持し、時計モデルと期限が有効な場合のみ使用する。Inspectorの信頼度は全画素に対するconfidence=2の画素率で、距離精度そのものではない。Phase 2では受信・診断までを扱い、深度合成・センサーフュージョンはPhase 3。

### 追跡と時刻

normal、initializing、excessiveMotion、insufficientFeatures、relocalizing、interrupted、interruptionEnded、failed、disconnected、motionUnavailableを扱う。状態変化をTCPで確実に通知し、UDPでも診断を送る。Hostはイベントsequenceで重複を除去する。Hostで検出した接続断のNode取得時刻は未知のため0とする。

再ローカライズ開始・中断復帰時は参照空間revisionを更新し、移動速度の差分履歴をリセットする。Hostは基準の再設定が必要な状態で古い原点を自動適用しない。追跡喪失・再ローカライズ中のPoseは本番入力に使用しない。

Host時計への逆変換は次式。

`host = (node - offset + referenceHost × drift) / (1 + drift)`

driftはppmから無次元へ変換する。時計モデルの不確かさ推定は`RTT/2 + jitter`。50msを超える場合や不正な数値は同期有効にしない。これはネットワーク対称性を仮定した推定で、測定誤差の厳密な上限ではない。同期サンプルが3秒以上更新されなければ既存の鮮度ゲートで出力を保護する。

映像は50ms・最大12フレーム、Poseは20ms・最大48パケットの有界バッファを使う。Host時刻に変換して選び、映像・深度は500ms、Poseは品質プロファイルの期限を超えると破棄する。映像参照が欠落した場合はキーフレームを要求し、キーフレームまで公開しない。Macの診断JSON v6はNodeごとのAR理由・時計不確かさ・深度高信頼度率を含む。

## アプリのビルド

`iPhoneApp/VPXIPhoneCapture.xcodeproj`をXcodeで開き、`VPXIPhoneCapture` schemeを選択する。実機へのインストール時はSigning & Capabilitiesで開発用Teamを設定する。共有ライブラリは親ディレクトリのSwift Packageを参照する。アプリとライブラリのSwift module名を分け、重複生成を避ける。

XcodeGenの再生成元は`iPhoneApp/project.yml`。Info.plistは手動管理で、生成時に権限説明を上書きしない。

```sh
xcodegen generate --spec iPhoneApp/project.yml
xcodebuild -project iPhoneApp/VPXIPhoneCapture.xcodeproj \
  -scheme VPXIPhoneCapture -sdk iphonesimulator \
  -configuration Debug CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath .build/iphone-app build
swift test
```

Info.plistとen／ja／zh-HansのInfoPlist.stringsへカメラ・モーション・ローカルネットワーク説明を設定し、Bonjourと`vpxstudio://pair/`を宣言する。カメラは撮影開始前に非同期で許可確認し、拒否時は設定への導線を表示する。ローカルネットワークは専用の許可要求APIを仮定せず、Bonjour開始でOSの許可処理へ接続する。探索のwaiting／failure時は権限と接続の確認を案内する。

Privacy Manifestは追跡・収集なしとし、アプリ内撮影イベントのタイムスタンプをMacへ送る用途としてSystem Boot Timeの理由`8FFB.1`を宣言する。[AppleのRequired Reason API仕様](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)に基づく。App Store提出可否の認定は別途必要。

## 検証と実機受入

自動テストは全74件。Phase 2では深度形式・破損拒否、メタデータ保持、品質イベント、UDPサイズ・暗号認証・リプレイ、時計逆変換・不確かさ・期限切れを追加した。Network.frameworkのループバックで、実TCP時計交換とEOF、UDP接続トークンの受入／拒否も検証した。Simulator用・実機用アプリを署名なしでビルドした。iPhone SE（第3世代）／iPhone 16 Pro MaxのSimulator初期画面でSafe Area・左右余白・改行を確認した。

実機では次を順番に確認し、結果を診断JSONとともに保存する。現状はすべて⭕️ [Pending]。

1. 実iPhoneへ開発用署名でインストールし、3言語でカメラ・モーション・ローカルネットワークの初回許可、拒否、設定復帰を確認する。拒否中に撮影が続かず、モーション拒否だけでは映像を失わないことを確認する。
2. Macでペアリングを開始し、iPhoneでHostを選び、QRと確認コードを照合して接続する。Wi-Fi上で映像・UDP Pose・時計交換が届くことを確認する。
3. AR同期モードと映像専用モードを切り替え、カメラ所有権の競合がないこと、frame ID・取得時刻・色・カメラ情報が正しいことを確認する。
4. LiDAR搭載機／非搭載機でHello能力を比較する。搭載機でdepth／confidenceが同じframe ID・取得時刻を持ち、Macの深度高信頼度率が更新されることを確認する。
5. 遮蔽、急な動き、中断、バックグラウンド復帰、再ローカライズ、通信断を起こす。理由・revision・追跡保護・基準再設定と再接続時のキーフレーム復旧を確認する。
6. Wi-Fi損失・再順序・遅延・片方向UDP遮断を与える。TCPがPoseを詰まらせないこと、同期不確かさ超過や期限切れで保護が働くことを確認する。光学測定で実際の整列誤差・映像遅延を測る。
7. 対応機種ごとに取得解像度・fps・ビット深度、Wi-Fi帯域、温度、電池消費、長時間のメモリ上限を記録する。

これらを確認するまでは、実機でのM2受入をDoneにしない。
