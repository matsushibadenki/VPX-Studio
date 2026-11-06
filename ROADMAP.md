# VPX Studio Roadmap

詳細な進捗・受入条件の正本は[docs/ROADMAP.md](docs/ROADMAP.md)。以下は概要であり、検証待ちの条件は詳細版を参照する。

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
- [Done] iPhoneのVideoToolbox HEVCエンコードと、MacのVideoToolboxデコードからRealtimeCoreへ渡す入力アダプタを追加。
- [Done] QR引き渡し用256-bit資格情報、確認コード、AES-GCM制御メッセージ保護を共有プロトコルへ追加。
- [Done] AES-GCMで保護したバイナリHEVC／制御パケット、TCP分割受信の復元、Bonjour広告するMac Hostを追加。
- [Done] ペアリング済みHelloを受けたMac HostがDevice RegistryへNodeを登録し、HEVC映像をRealtimeCoreへ投入する経路を追加。
- [Done] iPhone Capture Nodeの3言語UIコンポーネントに、Host探索、QR読取、確認コード、接続、映像開始／停止を追加。
- [Done] iPhone側Bonjour探索、QR資格情報のURI形式、Keychain保存を追加。
- [Done] iPhone Capture NodeのSwiftUIアプリ起点と、QR深いリンクを受けるアプリフローを追加。
- [Done] Pose／IMUをAES-GCM保護されたチャネルでMacへ送信し、Studioのトラッキング品質表示へ反映する経路を追加。
- [Done] 1秒周期の4タイムスタンプ同期、Clock offset／Network RTTのHost表示を追加。
- [Done] 最小RTTサンプル選択、RTT外れ値拒否、Network jitter推定とHost表示を追加。
- [Done] 推定時計差をHEVC映像ジッターバッファへ適用し、時刻順の50ms標準バッファリングを追加。
- [Done] 長期クロックドリフト（ppm）推定と、Pose用20msジッターバッファを追加。
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

- 🟢 [Done] `Config/ReleaseBaseline.json`に対応環境を固定し、環境チェックとdeployment target整合テストを追加。
- [Done] Stage座標系（m単位、右手系、+X右／+Y上／-Z前方、床面原点）の規約を定義。
- [Done] UHD 4K/60p、10-bitを標準ライブ映像プロファイルとして定義。
- [Done] 入力フレーム年齢とMetal GPUフレーム時間を計測・表示。
- 🟢 [Done] 入力、エンコード、伝送、デコード、Metal、drawable表示の区間計測を実装。未測定区間を省略し、時計推定と光学遅延の限界を明記。
- [Done] GPUフレーム時間と推定ドロップフレームのテレメトリを実装。
- 🟢 [Done] 観測フレームの既知CPUコピー、CVPixelBuffer／IOSurface再観測、プロセスメモリを計測・表示。
- 🟢 [Done] 固定120フレーム・120Poseのベンチマーク、Pose取得年齢、診断JSON v4とJSONL連続保存を追加。全56件のテストと実アプリでの描画・保存を確認。
- ⭕️ [Pending] 実iPhone・機材別4K60／10-bit・光学遅延・ストレージ障害注入の認定。
- [Done] 英語、日本語、简体中文の実行時ローカライズカタログを導入。
- [Later] 実機ベンチマークを自動実行し、対応ハードウェア別に結果を蓄積。

**完了条件:** 同一入力を再生して、処理時間・遅延・フレーム落ちを再現可能に記録できる。

## Phase 1 — Metalリアルタイム合成MVP

**目的:** 一台の入力カメラに対し、3D背景を低遅延で合成する。

- [Done] AVFoundationによるローカルUVC／Continuity Camera入力アダプタを実装。
- [Done] ローカルカメラ入力をDevice Registry、Metal texture変換、Studio画面へ接続。
- [Done] CVPixelBufferからCVMetalTextureCache経由でMetal textureへ取り込む。
- [Done] 映像入力の色域・伝達特性・YCbCrマトリクスをVideoFrameへ伝播し、Inspectorに表示。
- 🟢 [Done] BGRA8と8/10-bit YUV両レンジの直接取込・GPU色変換を実装し、形式別の実測値・予算・超過回数を記録。
- [Done] CameraRigのセンサーサイズ・焦点距離から画角を導く投影を実装。
- [Done] CameraRigに一次放射歪みK1を追加し、実写レンズ補正を実装。
- 🟢 [Done] 内部／外部パラメータ、5係数歪み、breathingと出所を校正JSONからCameraRigへ適用。
- 🟢 [Done] 限定glTF 2.0の静的メッシュ・PBR係数・directional lightを読み込み、深度シャドウマップとPBRを描画。
- [Done] Frame Graphで3Dシーンと実写クロマキー合成を順序制御する基礎合成を実装。
- 🟢 [Done] 実写・CG・独立アルファマットを共有イベント／フェンス付きFrame Graphで合成。
- 🟢 [Done] 線形SDR合成とsRGB出力、色メタデータ判定、デバッグパス・状態オーバーレイを実装。
- 🟢 [Done] 入力断・追跡断・GPU超過の保護、品質別の期限、警告保存、追跡基準変更時の隔離を実装。
- ⭕️ [Pending] 実カメラを含む機種別4K60／10-bit・校正精度・長時間運用認定。詳細は[Phase 1仕様](docs/PHASE1.md)。
- [Later] HDR、OCIO／ACEScg、LUTの本格運用を追加。

**完了条件:** 対象Mac上で、単一入力のプレビューを60fpsで維持し、フレーム落ち・処理遅延・入力品質を画面とログで確認できる。

## Phase 2 — 単一iPhone Capture Node

**目的:** iPhoneを映像、姿勢、IMU、深度の正規入力としてMacへ接続する。

- 🟢 [Done] iPhone側Capture NodeのARSession取得コンポーネントを作成。
- 🟢 [Done] iOSアプリプロジェクト、3言語の権限文言、許可確認・設定導線、Privacy Manifestを追加。
- 🟢 [Done] Capture NodeとHostで共有するバージョン付き通信メッセージ、映像制御契約、長さプレフィックス codec、分割受信の再構成テストを実装。
- 🟢 [Done] ARKitと排他のAVCapture映像専用モード、フレームID・取得時刻・色・カメラメタデータを追加。
- 🟢 [Done] ARKit World TrackingとCoreMotionからPose、角速度、加速度、品質状態を送信。
- 🟢 [Done] LiDAR深度・信頼度をバイナリ送信し、MacのNode別有界バッファ・信頼度診断へ接続。非対応機は能力から除外。
- 🟢 [Done] iPhone側Bonjour探索、QRスキャン画面、Keychainへの資格情報保存を実装。
- 🟢 [Done] AES-GCM保護されたTCPとPose／IMU／診断UDPを分離。接続トークン、MTU制限、リプレイ防止を追加。
- 🟢 [Done] iPhoneとMac間のクロック差とRTTを継続測定し、Host Inspectorへ表示。
- 🟢 [Done] 複数サンプルからジッターと外れ値を推定し、Host Inspectorへ表示。
- 🟢 [Done] 長期ドリフト推定と、Poseジッターバッファへの推定時計差適用を追加。
- 🟢 [Done] ARKit状態理由・参照空間revision・接続断の品質イベント、時計の不確かさと期限切れ破棄、HEVCキーフレーム再要求を追加。
- 🟢 [Done] 全74件のテスト、ローカルTCP／UDP接続試験、Simulator／実機向け署名なしアプリビルドを確認。詳細は[Phase 2仕様](docs/PHASE2.md)。
- ⭕️ [Pending] 実iPhoneの署名・権限許可／拒否、LiDAR有無、Wi-Fi映像・Pose・深度整列、AR再ローカライズ、機種別性能・長時間運用の受入試験。詳細版のPhase 2に集約。

**完了条件:** 単一iPhoneの映像とPoseが同一タイムラインに整列し、トラッキング品質・時刻差・通信遅延をMacで確認できる。

## Phase 3 — 校正と合成品質

**目的:** iPhone／プロカメラのどちらでも、ステージ座標と映像を安定して一致させる。

- 🟠 [Next] 画像からAprilTag／チェッカーボードの交点を自動検出して校正へ接続。
- 🟢 [Done] 順序付きボード対応点からカメラ姿勢・再投影残差を求め、新しい校正revisionの生成・保存と本番前チェックへ接続。[校正手順](docs/CHECKERBOARD-CALIBRATION.md)を追加。
- ⭕️ [Pending] 実ボードの寸法・点番号・距離・傾き・動きぼけに対する精度と合成位置ずれを測定。
- 🟢 [Done] 既知姿勢への手動固定からT_stage_from_nodeWorldを計算し、接続・参照空間に結び付けて保存・適用。再接続・参照変更で失効し、新鮮な映像・正常Poseによる再固定を要求。
- ⭕️ [Pending] 実機での固定精度、移動・回転時の合成位置ずれ、再ローカライズ後の再固定を検証。
- [Next] レンズ内部パラメータ、歪み、BreathingのCalibration Profileを管理。
- [Next] Chroma、深度、時間的一貫性、人物セグメンテーションを信頼度で統合。
- 🟢 [Done] 色・アルファ変化に応じたGPUマット時間安定化、履歴の安全な初期化、同一フレーム再表示、3言語操作と診断JSON v11を追加。全105件のテストを通過。
- ⭕️ [Pending] 実カメラでの髪・半透明・速い動きの残像評価と、4K60のGPU負荷・メモリ認定。
- [Next] マット、深度、Pose、レンズ補正のデバッグビューを実装。
- 🟢 [Done] 生深度・confidenceのGPUデバッグ表示、ソース・鮮度照合、3言語の距離上限・状態表示と診断JSON v12を追加。本番ではデバッグ表示を使わない。
- ⭕️ [Pending] 実iPhoneで深度の方向・距離・信頼度と切断復帰を検証。深度合成はNextとして継続。
- [Next] 校正残差、最終検証日時、適用範囲をLIVE前チェックに含める。
- 🟢 [Done] 公称焦点距離・フォーカスの校正適用範囲と、ボード計算の最大残差を本番前に検査。出所と内部校正の有効期限を維持し、診断JSON v13へ保存。
- 🟢 [Done] 校正プロファイルv1の保存・読込、revision・残差・検証日時・期限・入力一致の本番前ゲート、基準失効時の保護、3言語Inspectorと診断JSON v7を実装。[校正仕様](docs/CALIBRATION.md)を参照。
- ⭕️ [Pending] 実カメラの校正精度、再校正、LIVE中の期限切れ保護の実機確認。
- [Later] Rolling shutter、外部レンズエンコーダ、予測Poseの高度な補正を追加。
- 🟢 [Done] Node別のPose外れ値除去、欠測後の3測定による復帰、拒否数・理由の3言語表示と診断JSON v8を実装。
- 🟢 [Done] 映像取得時刻へのPose補間、最大30ms・20cm・0.2radの短時間予測、実測に対する誤差計測と診断JSON v10を追加。対応Poseがない追跡映像は本番出力を保護し、全99件のテストを通過。
- ⭕️ [Pending] 実iPhoneで予測誤差・急な停止・合成ずれ・保護復帰を測定する。
- ⭕️ [Pending] 実機の高速運動・ノイズ・遮蔽時の閾値と誤拒否率を検証。

**完了条件:** 校正済みの入力で、カメラ移動時のCG背景の位置ずれを可視化・記録でき、校正不良はLIVE開始前に検出される。

## Phase 4 — 複数iPhone Host

**目的:** 2〜4台のiPhoneを、独立したCapture Nodeとして安全に運用する。

- [Done] Mac側Bonjour Hostと、ペアリング済みHelloを起点とするNode Registry接続を実装。
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
