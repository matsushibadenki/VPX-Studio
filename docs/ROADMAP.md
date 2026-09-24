# VPX Studio 開発ロードマップ

## 1. 目的と進め方

VPX Studioを、Apple Silicon Mac上で動作するリアルタイム・バーチャルプロダクション基盤として段階的に完成させる。プロ用カメラ／トラッカーとiPhoneを同じDevice Adapter契約へ接続し、映像、Pose、レンズ、深度、クロックを共通タイムラインで処理する。

本ロードマップは [VPX-Studio設計書](./VPX-Studio設計書.md) を実装単位へ分解したものである。各項目は、コード、テスト、診断表示、受入条件のいずれかを伴う。後続フェーズへ進む前に、前フェーズの受入条件と既知の劣化時挙動を確認する。

状態の意味は次のとおり。

- [Done] 現在のコードベースで実装済み、または設計・契約として確定済み
- [Next] 次に着手する高優先度の未完了作業
- [Later] 計画済みだが、直近のリリースには含めない作業

## 2. プロジェクト全体の節目

| 節目 | 到達条件 | 主な成果物 |
| --- | --- | --- |
| M0 開発基盤 | 再現可能なビルド、座標・映像・時刻の規約、診断基盤 | Swift Package、共通データ契約、テレメトリ |
| M1 Metal合成MVP | 単一カメラで3D背景と実写を60fpsプレビュー | Frame Graph、CameraRig、基本キー／合成 |
| M2 iPhone単体 | iPhoneの映像・Pose・IMU・深度をMacへ安全に入力 | Capture Node、暗号化通信、時刻整列 |
| M3 校正済み合成 | ステージ座標とカメラ投影を再現可能に一致 | Calibration Profile、品質ゲート、デバッグビュー |
| M4 複数Node | 2〜4台のiPhoneを独立監視・復旧 | Host、Admission Control、Node別バッファ |
| M5 再構成可能なTake | 映像だけでなく設定・補助パス・診断を保存 | Take Package、Reviewモード |
| M6 プロ入出力 | SDI/HDMI/NDI、外部トラッカー、同期機材を接続 | 署名済みアダプタ、Genlock/PTP/LTC |
| M7 LED／高品位 | LED wallと高品質レンダリングを本番運用 | Off-axis frustum、HDR、選択的RT |

## 3. 現在地

- [Done] macOS Swift Package、SwiftUI Studio画面、MetalKitプレビューの土台を作成。
- [Done] `VideoFrame`、`PoseSample`、`LensSample`、`DepthFrame`、`ClockSample` と品質状態の共通契約を定義。
- [Done] Metal Frame Graphの依存順、重複、欠損依存、循環依存を検証するテストを追加。
- [Done] Stage座標（m、右手系、+X右／+Y上／-Z前方）とUHD 4K/60p・10-bit標準プロファイルを定義。
- [Done] iPhone Capture NodeとMac Host間の能力通知、HEVC映像、Pose／IMU、深度、クロックのバージョン付き契約を追加。
- [Done] 長さプレフィックスcodec、AES-GCM保護、Bonjour Host、QR資格情報、確認コードを実装。
- [Done] iPhone側のBonjour探索、Keychain保存、QR読取、接続／映像開始・停止UIを実装。
- [Done] VideoToolboxによるiPhone HEVCエンコードとMacデコードをRealtime Coreへ接続。
- [Done] 4タイムスタンプ同期、RTT外れ値拒否、ネットワークジッター、クロックドリフト推定を実装。
- [Done] HEVC映像50ms、Pose 20msを標準とする時刻順ジッターバッファを実装。
- [Done] ARKit Pose、CoreMotion角速度、LiDAR深度の取得経路と品質表示を実装。
- [Done] 物理CameraRig投影、焦点距離調整、一次放射歪みK1補正、基本クロマキー合成を実装。
- [Done] 日本語・英語・简体中文の実行時切替、カタログによる言語追加、システム／ライト／ダーク表示モードを実装。
- [Done] fps、GPU時間、フレーム年齢、推定ドロップ、同期品質を表示するテレメトリを実装。
- [Done] プロ機材とiPhoneを共通Device Adapterとして扱う方針、および複数iPhoneの通信・帯域・校正設計を文書化。

## 4. Phase 0 — 開発基盤・規約・測定

### 目的

実装結果を環境間で比較できるビルド、データ、時間、性能の基準を固定する。

### 作業項目

- [Next] 対応Mac、macOS、Xcode、iOS、対応iPhone機種と最低OSをリリース設定へ固定。
- [Done] Stage座標の単位、軸、原点、カメラ前方、座標変換の命名規約を文書化。
- [Done] UHD 4K/60p・10-bit標準ライブプロファイルをプロジェクト設定へ追加。
- [Next] 入力、ネットワーク、デコード、Metal、出力を分けた区間別レイテンシ計測を追加。
- [Next] CPUコピー回数、CVPixelBuffer／IOSurfaceの再利用率、メモリ使用量を計測。
- [Done] GPUフレーム時間、入力フレーム年齢、推定ドロップ数の表示を追加。
- [Next] 固定テスト映像と固定Poseログを用いた再現可能なベンチマークハーネスを作成。
- [Done] 3言語のローカライズカタログと将来言語追加手順を確立。

### 完了条件

同じ入力と設定を再生したとき、処理時間、入力フレーム年齢、フレーム落ち、GPU時間をログとUIで再現可能に確認できる。

## 5. Phase 1 — Metalリアルタイム合成MVP

### 目的

単一のローカル映像入力に対して、3D背景、基本キー、レンズ補正、プレビューを低遅延で成立させる。

### 作業項目

- [Done] AVFoundationのUVC／Continuity Camera入力をDevice Registryへ接続。
- [Done] CVPixelBufferからCVMetalTextureCacheを経由するテクスチャ入力を実装。
- [Next] 入力形式ごとのゼロコピー経路と色変換コストを測定し、許容値を設定。
- [Done] センサーサイズ・焦点距離から画角を導くCameraRig投影を実装。
- [Done] 一次放射歪みK1による基本レンズ補正を実装。
- [Next] 実測内部／外部パラメータ、複数歪み係数、breathingテーブルをCameraRigへ追加。
- [Next] 限定OpenUSDまたはglTFサブセットのMesh、PBR、ライト、影を読み込む。
- [Done] Frame GraphでAcquire→Normalize→Render→Composite→Presentの順序を管理。
- [Next] 実写、CG、アルファマットをMetalパス間の同期フェンス付きで合成。
- [Next] SDR色変換、入力色メタデータ、プレビューオーバーレイを実装。
- [Next] 入力断、GPU期限超過、トラッキング断時の保護状態を実装。
- [Later] HDR、OCIO／ACEScg、LUTを色変換マニフェストへ統合。

### 完了条件

対象Macの標準プロファイルで、単一入力のプレビューを60fpsで維持し、入力年齢、処理時間、ドロップ、品質状態を画面とログで確認できる。

## 6. Phase 2 — iPhone Capture Node単体

### 目的

iPhoneを、映像カメラ、トラッキング端末、IMU、対応機種の深度センサーとしてMacの正規入力にする。

### iPhone側

- [Done] ARSessionからワールドPose、追跡状態、角速度、加速度を取得するCoordinatorを実装。
- [Next] AVCaptureSessionの映像にframeID、captureTime、色メタデータ、カメラ情報を付与。
- [Done] VideoToolbox HEVCエンコードとキーフレーム要求、品質変更の制御契約を実装。
- [Next] LiDAR搭載機のscene depthとconfidence textureを送信。非搭載機は能力から明示的に除外。
- [Next] カメラ、モーション、ローカルネットワーク権限と拒否時の説明を整備。
- [Done] Host探索、QRスキャン、確認コード、Keychain資格情報保存、深いリンク処理を実装。

### Mac側・通信

- [Done] BonjourとNetwork.frameworkによるHost発見・接続確立を実装。
- [Done] TLS相当の暗号化チャネルとAES-GCM保護メッセージを実装。
- [Next] 制御用信頼性ストリームと、Pose／IMU／診断用低遅延データグラムを分離。
- [Done] 映像フレーム、Pose、深度、Clock SampleをNode IDごとに登録。
- [Done] 4タイムスタンプ交換による時計差、RTT、ジッター、ドリフト推定を実装。
- [Next] ARKitのrelocalization、limited、tracking lost、接続断を品質イベントとして伝播。
- [Next] 推定時計差と不確かさを映像・Poseバッファの選択に反映し、期限切れデータを破棄。

### 完了条件

実機の単一iPhoneから映像とPoseを同一タイムラインへ整列し、Mac上でNode状態、ARKit状態、時計差、RTT、ジッター、深度信頼度を確認できる。

## 7. Phase 3 — 校正・センサーフュージョン・合成品質

### 目的

入力の座標系、内部パラメータ、深度、Pose品質を明示的に扱い、カメラ移動時の合成ずれを検証可能にする。

### 作業項目

- [Next] AprilTagまたはチェッカーボードによるステージ原点・姿勢校正を実装。
- [Next] `T_stage_from_nodeWorld`をNodeごとに保存し、ARKit再ローカライズ時に無効化・再検証。
- [Next] `CalibrationProfile`（内部・外部パラメータ、歪み、breathing、残差、適用範囲）を版管理。
- [Next] 実測値、メーカー値、推定値を区別し、LIVE／RECORD前の有効性を検査。
- [Next] IMU、ARKit、外部トラッカー、レンズエンコーダを共分散・遅延付きで融合。
- [Next] 外れ値除去、短時間Pose予測、予測上限、予測誤差テレメトリを実装。
- [Next] Chroma、深度、時間的一貫性、人物セグメンテーションを信頼度付きで統合。
- [Next] マット、深度、Pose、レンズ補正、色変換のデバッグビューを追加。
- [Next] 残差、最終検証日時、品質状態をLIVE開始前チェックへ追加。
- [Later] rolling shutter、外部レンズエンコーダ、因子グラフ型の高度な融合を追加。

### 完了条件

校正済み入力でカメラを移動させたとき、CG背景の位置ずれを数値と映像で検証できる。校正期限切れ、残差超過、座標系不一致は本番開始前に検出される。

## 8. Phase 4 — 複数iPhone Hostと帯域制御

### 目的

2〜4台を標準プロファイルとし、Nodeごとの映像・Pose・深度・診断を独立して運用する。1台の切断が他Nodeや本番出力を停止させない。

### 接続・認証

- [Done] Mac HostがBonjourで広告し、ペアリング済みHelloからNodeを登録。
- [Next] Nodeごとの証明書、資格情報、能力、役割、校正参照、接続状態を管理。
- [Next] Bluetoothは近距離発見・初回ペアリング補助に限定し、映像本線はWi-Fiへ固定。
- [Next] QRまたは確認コードによるアプリケーションレベル相互認証を複数台で検証。
- [Later] Multipeer Connectivityは補助接続に限定し、本線はNetwork.frameworkで統一。

### Node管理・帯域

- [Next] `primaryCamera`、`secondaryCamera`、`trackerOnly`、`monitorOnly`の役割を実装。
- [Next] Nodeごとに映像解像度、fps、ビットレート、深度fps、Poseレートを割り当てる。
- [Next] Host性能、Wi-Fi帯域、デコーダ数に基づくAdmission Controlを実装。
- [Next] 帯域不足時は低優先度映像から縮小・停止し、Poseと制御を維持。
- [Next] Nodeごとのフレーム年齢、ジッター、デコード時間、バッテリー、温度、ARKit状態を表示・保存。
- [Next] Node別ジッターバッファ、時刻整列、再接続を分離し、他Nodeへ影響させない。
- [Next] Node切断時の保護状態と再接続時のキーフレーム再要求を実装。
- [Later] 専用アクセスポイントのチャンネル診断、帯域推奨、運用レポートを追加。

### 完了条件

2〜4台の標準プロファイルで、各Nodeを個別に監視・校正・役割変更できる。任意の1台を切断・再接続しても、他Nodeの映像と本番出力が停止しない。

## 9. Phase 5 — Take収録・再構成・レビュー

### 目的

完成映像だけでなく、再合成に必要な設定、校正、補助パス、診断を再現可能なパッケージとして保存する。

### 作業項目

- [Next] `manifest.json`のスキーマ、バージョン、互換性、ハッシュ規約を確定。
- [Next] camera/composite映像、音声、matte、depth、Pose、校正参照、USDシーンを収録。
- [Next] ソフトウェア版、プラグイン版、デバイス、入力形式、フレーム欠落、同期品質を保存。
- [Next] 色変換、LUT、アセット、Node能力、帯域変更履歴をマニフェストへ記録。
- [Next] ストレージ不足、書込み遅延、ドロップ時の収録保護と明確な警告を実装。
- [Later] REVIEWモードで当時のシーン、補助パス、テレメトリを比較表示。
- [Later] 欠落アセット、校正不一致、バージョン非互換を再生前に診断。

### 完了条件

保存済みTakeを開くと、使用した入力、Node、校正、シーン、色変換、同期状態を特定でき、同じ設定で再生または再合成を開始できる。

## 10. Phase 6 — プロ機材アダプタと本番出力

### 目的

プロ映像、トラッキング、レンズ、同期機材を、iPhoneと同じ共通データ契約へ接続する。

### 作業項目

- [Later] SDI／HDMIキャプチャ、NDI、ProRes入力・出力をVideoIOアダプタとして追加。
- [Later] FreeD、Mo-Sys、stYpe、Ncam、OptiTrack等をTrackingアダプタとして追加。
- [Later] FIZ／ズーム／フォーカス／絞りエンコーダをLensアダプタへ追加。
- [Later] Genlock、PTP、LTC/VITCをClock Sampleへ統合し、ロック状態と不確かさを表示。
- [Later] 10／12-bit HDR、OCIO／ACEScg、出力デバイス別変換を実装。
- [Later] アダプタの能力、形式、最悪遅延、必要権限、バージョンを登録。
- [Later] 署名、互換性検証、動的有効化、障害時の安全な無効化を実装。
- [Later] LIVE／RECORDの権限分離、確認操作、監査ログを追加。

### 完了条件

対応機材構成で、入力形式、同期状態、レンズ・Pose品質、経路別遅延、出力状態を監視しながら連続運用できる。

## 11. Phase 7 — LED Wall・OpenUSD・高品位レンダリング

### 目的

インカメラVFXとレビュー用高品質再合成へ拡張する。

### 作業項目

- [Later] `LEDWallProfile`（パネル配置、物理寸法、色、輝度、遅延、スキャン）を実装。
- [Later] カメラPoseに基づくoff-axis frustumとLED出力同期を実装。
- [Later] プロファイル、校正、同期が有効な場合のみ本番出力を許可するポリシーを追加。
- [Later] OpenUSDのレイヤー、バリアント、参照、限定Runtime Parameterを実装。
- [Later] MaterialX、Alembic、glTFの必要範囲を段階的に追加。
- [Later] 選択的レイトレーシング、MetalFX、時間再構成を品質プロファイルへ追加。
- [Later] Live Fast／Live Quality／Review Cinemaの劣化順序を実装。
- [Later] 内部作業色空間、HDR、LED、SDR、収録向けの出力変換を統一。

### 完了条件

校正済みLED構成でoff-axis frustumとカメラ追従を確認でき、レンダリング品質、遅延、同期、出力保護の状態を本番UIから監視できる。

## 12. UI／UXと運用品質（全フェーズ横断）

- [Done] SwiftUIを基本とし、UI状態とリアルタイム処理を分離。
- [Done] 日本語、英語、简体中文を実行時に切り替え、翻訳カタログへ新言語を追加可能。
- [Done] システム設定、ライト、ダーク表示モードを切り替え可能。
- [Next] `BUILD`、`CALIBRATE`、`REHEARSE`、`LIVE`、`RECORD`、`REVIEW`の作業モードを段階的に導入。
- [Next] 全画面でSafe Area内、左右16pt以上の余白、狭い画面での操作可能性を検証。
- [Next] 警告を原因・影響・推奨操作の構造化データとして管理し、3言語で表示。
- [Next] LIVE中の危険な変更を確認操作またはロール権限で制御。
- [Next] fps、入力品質、Pose年齢、ジッター、同期、GPU、ストレージ、温度を共通Inspectorへ統合。
- [Later] 読み取り中心のリモート監視と、許可された制御だけを受ける運用端末を追加。

## 13. セキュリティ・信頼性・復旧

- [Done] QR資格情報、確認コード、暗号化制御・データパケットの基盤を実装。
- [Next] 資格情報の失効、再ペアリング、端末削除、監査イベントを実装。
- [Next] ローカルネットワーク、カメラ、モーション、ストレージ権限の状態を起動時に検証。
- [Next] 入力断、同期喪失、フレーム落ち、ストレージ不足、温度上昇、性能低下を統一イベント化。
- [Next] 期限切れパケット、未知のプロトコル版、能力不一致、破損Takeを安全に拒否。
- [Later] プラグイン署名、権限宣言、互換性検証、隔離ロードを実装。
- [Later] Takeと校正成果物の改変検出、監査ログのエクスポートを追加。

## 14. 受入基準

| 項目 | 初期受入基準 |
| --- | --- |
| 標準入力 | 4K/60p、10-bit入力を対象とし、対応形式を明示できる |
| フレーム処理 | 期限超過、ドロップ、入力年齢を連続運転中に記録できる |
| 遅延 | 入力→ネットワーク→デコード→GPU→出力の内訳を表示できる |
| メモリ | 対応経路のCPUコピー回数とバッファ再利用を確認できる |
| トラッキング | Pose年齢、ジッター、共分散または信頼度、追跡喪失を表示・保存できる |
| iPhone | Nodeごとに接続、クロック差、ARKit状態、深度信頼度を表示できる |
| 複数iPhone | 2〜4台で帯域・遅延・フレーム落ちをNode別に監視し、1台の切断から復旧できる |
| 校正 | ステージ変換、内部パラメータ、残差、有効期限を保存し、LIVE前に検証できる |
| 収録 | 映像、設定、校正、シーン、診断、補助パスの参照をTakeへ保存できる |
| 復旧 | 入力断、Pose断、同期断、ストレージ不足時の保護動作がプロファイルどおりである |
| UI | 日本語・英語・简体中文、ライト・ダーク、Safe Area、狭い画面を確認できる |

## 15. 直近の着手順

1. [Next] Phase 0の対象環境と区間別レイテンシ計測を確定する。
2. [Next] Phase 1のOpenUSD／glTF最小ローダー、Metal合成、SDR色変換を完成させる。
3. [Next] Phase 2のiPhone実機権限、AVCapture映像、深度、品質イベントを検証する。
4. [Next] Phase 3のステージ校正とCalibration Profileを追加し、LIVE前チェックへ接続する。
5. [Next] Phase 4のNode役割、Admission Control、再接続、Node別診断を完成させる。
6. [Later] Take、プロ機材、LED wall、高品位レンダリングを順に追加する。

各ステップでは、機能実装と同じ変更でテスト、診断表示、失敗時の劣化方針、3言語文言を更新する。性能や同期品質を測定できない機能は、次の本番向けフェーズの完了条件に含めない。
