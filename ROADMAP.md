# VPX Studio Roadmap

## 目的

VPX Studioを、Apple Silicon Mac上で動作するリアルタイム・バーチャルプロダクション基盤として段階的に構築する。最初に低遅延の単一カメラ合成を成立させ、その後にiPhone Capture Node、複数端末、プロ機材、LED wallへ拡張する。

各フェーズは、前フェーズの計測可能な受け入れ基準を満たしてから進める。未検証の機能を重ねて原因を不明確にしない。

## 現在地

- [Done] macOS Swift Package、SwiftUI Studio画面、MetalKitプレビューを作成。
- [Done] 映像・Pose・レンズ・深度・クロックの共通データ契約を定義。
- [Done] Metalのパス依存関係を扱うRealtime Frame Graphを実装し、3Dシーンと実写合成の描画順序へ接続。
- [Done] Frame Graphの依存順、重複、欠損依存、循環依存を検証する回帰テストを追加。
- [Done] 右手系・m単位・+X右／+Y上／-Z前方のStage座標規約と、UHD 4K/60p・10-bit標準プロファイルをプロジェクト設定として固定。
- [Done] iPhone Capture NodeとMac Hostで共有する、能力通知・映像・Pose／IMU・深度・クロックのバージョン付き通信契約を追加。
- [Done] 信頼性ストリームの分割・結合を復元する長さプレフィックス付き制御メッセージ codec を追加。
- [Done] 4タイムスタンプ交換からMac／iPhone間のクロック差とRTTを推定する共有ロジックを追加。
- [Done] HEVC映像プロファイル、映像開始／停止、品質変更、キーフレーム要求を表す冪等な制御契約を追加。
- [Done] iPhone向けARSession Capture Coordinatorで、同じ時刻の映像・ARKit Pose・IMU角速度・LiDAR深度を取得。
- [Done] 深度バッファ、透視投影、Camera Rigの土台を持つ最小Metal 3Dプレビューを作成。
- [Done] 実写前景を透過して3Dを見せる、切替可能な基本クロマキー合成を作成。
- [Done] クロマキーの有効化、緑のしきい値、エッジのソフトネスをStudio画面から調整可能にした。
- [Done] 日本語、英語、简体中文の実行時切替と、将来の言語をカタログで追加できるローカライズ構成を作成。
- [Done] システム設定、ライト、ダークを切り替える表示モードを追加。
- [Done] レンダリングfps、GPUフレーム時間、入力フレーム年齢、推定ドロップ数をリアルタイム表示するテレメトリを追加。
- [Done] Device Registryでカメラ入力を役割・能力・接続状態を持つ管理対象として表示。
- [Done] センサーサイズと焦点距離から画角を導く物理カメラ投影と、焦点距離のライブ調整を追加。
- [Done] 一次放射歪みK1による実写レンズ補正と、ライブ調整を追加。
- [Done] プロ機材とiPhoneを共通のDevice Adapterとして扱う設計を文書化。
- [Done] 複数iPhoneをMac Hostに接続する通信・帯域・校正方針を文書化。

## Phase 0 — 開発基盤と測定基準

**目的:** 以後の実装を比較・検証できる状態にする。

- [Next] 対象Mac、macOS、Xcode、iPhone OS、対応iPhone機種の最小バージョンを固定。
- [Done] Stage座標系（m単位、右手系、+X右／+Y上／-Z前方、床面原点）の規約を定義。
- [Done] UHD 4K/60p、10-bitを標準ライブ映像プロファイルとして定義。
- [Done] 入力フレーム年齢とMetal GPUフレーム時間を計測・表示。
- [Next] 入力、デコード、Metal、出力の区間ごとの完全なレイテンシ計測を実装。
- [Done] GPUフレーム時間と推定ドロップフレームのテレメトリを実装。
- [Next] CPUコピー回数とメモリ使用量のテレメトリを実装。
- [Done] 英語、日本語、简体中文の実行時ローカライズカタログを導入。
- [Later] 実機ベンチマークを自動実行し、対応ハードウェア別に結果を蓄積。

**完了条件:** 同一入力を再生して、処理時間・遅延・フレーム落ちを再現可能に記録できる。

## Phase 1 — Metalリアルタイム合成MVP

**目的:** 一台の入力カメラに対し、3D背景を低遅延で合成する。

- [Done] AVFoundationによるローカルUVC／Continuity Camera入力アダプタを実装。
- [Done] ローカルカメラ入力をDevice Registry、Metal texture変換、Studio画面へ接続。
- [Done] CVPixelBufferからCVMetalTextureCache経由でMetal textureへ取り込む。
- [Done] 映像入力の色域・伝達特性・YCbCrマトリクスをVideoFrameへ伝播し、Inspectorに表示。
- [Next] 入力形式ごとのゼロコピー経路と色変換コストを計測する。
- [Done] CameraRigのセンサーサイズ・焦点距離から画角を導く投影を実装。
- [Done] CameraRigに一次放射歪みK1を追加し、実写レンズ補正を実装。
- [Next] CameraRigの実測内部／外部パラメータ入力と、複数係数のレンズ校正を実装。
- [Next] glTFまたは限定OpenUSDサブセットを読み込み、Mesh、PBR、ライト、影を描画。
- [Done] Frame Graphで3Dシーンと実写クロマキー合成を順序制御する基礎合成を実装。
- [Next] 実写、CG、アルファマットをMetal Frame Graphで合成。
- [Next] SDR出力の色変換とプレビュー用オーバーレイを実装。
- [Next] 入力断、トラッキング断、GPU期限超過時の保護状態を実装。
- [Later] HDR、OCIO／ACEScg、LUTの本格運用を追加。

**完了条件:** 対象Mac上で、単一入力のプレビューを60fpsで維持し、フレーム落ち・処理遅延・入力品質を画面とログで確認できる。

## Phase 2 — 単一iPhone Capture Node

**目的:** iPhoneを映像、姿勢、IMU、深度の正規入力としてMacへ接続する。

- [Done] iPhone側Capture NodeのARSession取得コンポーネントを作成。
- [Next] iPhone Capture NodeアプリのUI、HEVCエンコード、Mac Hostへの安全なWi-Fi伝送を実装。
- [Done] Capture NodeとHostで共有するバージョン付き通信メッセージ、映像制御契約、長さプレフィックス codec、分割受信の再構成テストを実装。
- [Next] AVCaptureSessionで映像を取得し、フレームIDと取得時刻を付与。
- [Next] ARKit World TrackingとCoreMotionからPose、角速度、加速度、品質状態を送信。
- [Next] LiDAR対応機でscene depthと信頼度を送信。非対応機では機能を明示的に無効化。
- [Next] BonjourでMac Hostを発見し、QRコードまたは確認コードで相互認証。
- [Next] Wi-Fi上に、制御用の信頼性ストリームと、Pose／IMU用の低遅延データグラムを実装。
- [Next] iPhoneとMac間のクロック差、RTT、ジッターを継続測定。
- [Next] ARKitの再ローカライズ、追跡低下、接続断を品質イベントとして伝播。

**完了条件:** 単一iPhoneの映像とPoseが同一タイムラインに整列し、トラッキング品質・時刻差・通信遅延をMacで確認できる。

## Phase 3 — 校正と合成品質

**目的:** iPhone／プロカメラのどちらでも、ステージ座標と映像を安定して一致させる。

- [Next] AprilTagまたはチェッカーボードを使うステージ原点校正を実装。
- [Next] NodeごとにT_stage_from_nodeWorldを保存・検証する。
- [Next] レンズ内部パラメータ、歪み、BreathingのCalibration Profileを管理。
- [Next] Chroma、深度、時間的一貫性、人物セグメンテーションを信頼度で統合。
- [Next] マット、深度、Pose、レンズ補正のデバッグビューを実装。
- [Next] 校正残差、最終検証日時、適用範囲をLIVE前チェックに含める。
- [Later] Rolling shutter、外部レンズエンコーダ、予測Poseの高度な補正を追加。

**完了条件:** 校正済みの入力で、カメラ移動時のCG背景の位置ずれを可視化・記録でき、校正不良はLIVE開始前に検出される。

## Phase 4 — 複数iPhone Host

**目的:** 2〜4台のiPhoneを、独立したCapture Nodeとして安全に運用する。

- [Next] Mac側Bonjour HostとNode Registryを実装。
- [Next] 各Nodeに証明書、役割、能力、校正、接続状態を紐付ける。
- [Next] primaryCamera、secondaryCamera、trackerOnly、monitorOnlyの役割を実装。
- [Next] Nodeごとのジッターバッファ、時刻整列、フレーム年齢、デコード遅延を実装。
- [Next] Admission Controlにより、Host性能とWi-Fi帯域に応じて接続・映像プロファイルを判断。
- [Next] 帯域不足時に低優先度Nodeの映像を段階的に縮小し、Poseと制御を維持する。
- [Next] Node切断・再接続が他Nodeの映像や本番出力を停止させないことを確認。
- [Later] 専用Wi-Fiアクセスポイントの自動診断と推奨チャンネル表示。

**完了条件:** 2〜4台の標準プロファイルで、各Nodeの映像・Pose・状態を個別に監視しながら、他Nodeに影響なく接続断から復旧できる。

## Phase 5 — Take収録とレビュー

**目的:** 完成映像だけでなく、再合成可能な撮影状態を保存する。

- [Later] Take Packageのmanifest、バージョン、ハッシュ、互換性方針を実装。
- [Later] camera/composite映像、音声、matte、depth、Pose、校正、シーン、カラー設定を収録。
- [Later] フレーム落ち、同期品質、プラグイン版、入力設定を診断データとして保存。
- [Later] REVIEWモードで当時のシーン、補助パス、テレメトリを比較表示。
- [Later] アセットまたは校正値が欠落した場合の再生可能性を表示。

**完了条件:** 保存済みTakeを開いたとき、どの入力・校正・シーン・カラー変換で収録されたかを特定できる。

## Phase 6 — プロ機材と本番出力

**目的:** プロ向け映像・トラッキング・同期系をアダプタとして追加する。

- [Later] SDI/HDMIキャプチャ、NDI、ProRes収録・出力を実装。
- [Later] FreeD、外部カメラトラッカー、レンズエンコーダをTracking/Lensアダプタとして実装。
- [Later] Genlock、PTP、LTC/VITCの同期状態をClock Sampleへ統合。
- [Later] 10/12-bit HDR、ACES／OCIO、出力別カラー変換を実装。
- [Later] LIVEモードの権限分離、出力保護、運用ログを実装。

**完了条件:** 対応機材構成で同期状態、入力形式、遅延、出力品質を監視しながら安定運用できる。

## Phase 7 — LED Wallと高品位レンダリング

**目的:** インカメラVFXと高品位な再合成へ拡張する。

- [Later] LEDWallProfile（パネル配置、色、輝度、遅延、スキャン設定）を実装。
- [Later] カメラPoseに基づくoff-axis frustum renderingを実装。
- [Later] 選択的レイトレーシング、MetalFX、時間再構成を品質プロファイルに追加。
- [Later] 大規模OpenUSDのストリーミング、MaterialX、アセット管理を実装。
- [Later] 高品質な再合成とオフライン・レビュー用レンダリングを実装。

**完了条件:** 校正済みLED wall構成で、カメラ追従と出力同期を監視しながらインカメラVFXを運用できる。

## 横断要件

- [Next] LIVE／RECORD操作はSafe Area内に収め、狭い画面で重要な状態・停止操作が隠れないようにする。
- [Next] すべての警告は、原因、影響範囲、推奨操作を英語・日本語・简体中文で表示する。
- [Next] デバイス断、権限拒否、ネットワーク劣化、ストレージ不足、熱状態を障害として記録する。
- [Later] 署名付きプラグイン、互換性検証、プラグイン権限モデルを導入する。
- [Later] 実運用のパフォーマンス結果を、対応Mac・iPhone・Wi-Fi環境ごとに公開する。
