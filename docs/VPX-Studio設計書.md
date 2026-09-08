# VPX Studio 設計書

| 項目 | 内容 |
| --- | --- |
| 文書状態 | Draft — 実装の基準となる設計 |
| 対象 | Apple Silicon Mac上のリアルタイム・バーチャルプロダクション環境 |
| 主な利用者 | 映像技術者、VPオペレーター、3Dアーティスト |
| 対応入力 | プロ映像機材、iPhone、およびiPhone内蔵センサー |
| 基準タイムベース | SMPTE Timecode と単調増加時刻を併用 |

## 1. 目的

VPX Studioは、実写映像、カメラ／端末トラッキング、3Dシーン、キーイング、カラー処理、収録を、低遅延の一つのリアルタイム処理系として扱うmacOSアプリケーションである。

スタジオ用のプロ機材だけでなく、iPhoneを撮影カメラ、トラッキング端末、深度センサー、プレビュー端末として利用できるようにする。同じプロジェクトを小規模撮影から同期済みのスタジオ撮影まで段階的に拡張できることを目指す。

### 1.1 設計原則

- 映像、姿勢、レンズ、時間同期を、共通時刻に紐付くデータストリームとして扱う。
- 映像フレームをCPUメモリへ往復コピーしない。可能な範囲で `CVPixelBuffer`、`IOSurface`、Metal textureを共有する。
- 機材を「能力を持つ入力ソース」として抽象化し、機種固有の処理をコアへ漏らさない。
- iPhoneの推定値は正規の入力として扱うが、プロ用外部トラッカーと同じ精度・同期保証を仮定しない。品質と信頼度を必ず伝播させる。
- 負荷過多時は定義済みの劣化方針と警告を適用し、品質低下を隠さない。
- UIの重要操作はSafe Area内に収め、狭い画面でも左右16pt以上の余白を維持する。

### 1.2 非目標

- 初期版で汎用DCCやゲームエンジンの全機能を再現しない。
- iPhoneだけで、Genlockされた放送用カメラと同等の同期保証をしない。
- 未検証のML推定を、安全判断や正確な測量の唯一の根拠にしない。

## 2. 利用シナリオ

| シナリオ | 映像入力 | トラッキング／深度 | 想定出力 |
| --- | --- | --- | --- |
| プロスタジオ | SDI/HDMIキャプチャ、NDI | 外部トラッカー、レンズエンコーダ、Genlock | LED wall、SDI、ProRes |
| 小規模グリーンバック | UVC、iPhone、NDI | iPhone ARKit、Vision、IMU | HDMI/NDI、収録 |
| iPhone撮影 | iPhoneカメラ | ARKit、IMU、LiDAR対応機の深度 | Mac上の合成／収録 |
| ロケーション・スカウト | iPhone | ARKit、LiDAR、位置情報（任意） | USDアンカー、簡易プレビュー |
| ハイブリッド | プロカメラ | iPhoneを補助トラッカー／モニターに使用 | プロ出力とモバイル監視 |

## 3. システム構成

```text
プロカメラ / iPhone / 外部トラッカー / ネットワーク映像
                         │
                         ▼
               Device Adapter Layer
 VideoFrame ─ PoseSample ─ LensSample ─ DepthFrame ─ ClockSample
                         │
                         ▼
          Time Alignment & Sensor Fusion
                         │
                         ▼
             Realtime Frame Graph (Metal)
 入力変換 → 補正 → Key/Depth → 3D Render → Composite → Color
                         │
             ┌───────────┼───────────┐
             ▼           ▼           ▼
          Preview     Recorder    SDI/HDMI/NDI
```

### 3.1 レイヤー責務

| レイヤー | 責務 | 禁止事項 |
| --- | --- | --- |
| UI / Studio | プロジェクト操作、監視、校正、ライブ制御 | GPUパスやデバイスSDKの直接制御 |
| Application | ユースケース、永続化、権限、状態遷移 | フレーム単位の重い処理 |
| Realtime Core | Frame Graph、時刻整列、負荷制御、診断 | UIスレッドの待機 |
| Device Adapter | SDK／プロトコルを共通ストリームへ変換 | 合成・レンダリング判断 |
| Render / Composite | Metalによる画像処理、3D、色変換 | 機種固有の形式への依存 |
| Storage | アセット、校正値、Take、再生可能なメタデータ | ライブパスのブロック |

### 3.2 推奨技術構成

- UI: SwiftUIを基本とし、高密度ビューやメニュー統合にAppKitを併用する。
- Application: Swift Concurrency。UI更新とリアルタイム処理を隔離する。
- Realtime Core／SDK境界: C++20とObjective-C++。
- GPU: Metal / MSL。レンダリング、compute、テクスチャ変換を同じGPUスケジュールで実行する。
- メディア: AVFoundation、CoreMedia、VideoToolbox、CoreAudio、CoreVideo。
- iPhone連携: ARKit、AVFoundation、CoreMotion、Network.framework。
- シーン: OpenUSDを正とし、MaterialX、Alembic、glTFを必要に応じてインポートする。
- カラー: OCIO互換の変換構成を持ち、ACEScgを内部作業色空間の標準候補とする。

## 4. デバイス抽象化

### 4.1 共通データ契約

すべての入力には、取得時刻、到着時刻、クロック情報、信頼度、校正参照を付与する。入力方式が異なっても合成側は同じ契約で処理する。

```text
DeviceDescriptor
  id, displayName, type, capabilities, connectionState

VideoFrame
  frameID, captureTime, presentationTime, pixelBuffer, format,
  colorMetadata, cameraID, calibrationID, quality

PoseSample
  sampleTime, transform, linearVelocity, angularVelocity,
  covariance, sourceID, referenceSpace, quality

LensSample
  sampleTime, focalLength, focusDistance, aperture,
  distortionModelID, zoom, quality

DepthFrame
  frameID, captureTime, depthTexture, confidenceTexture,
  coordinateSpace, calibrationID

ClockSample
  sourceTime, hostMonotonicTime, uncertainty, sourceID
```

`quality`は少なくとも`nominal`、`degraded`、`estimated`、`lost`を持つ。UIと収録メタデータはこの状態を必ず表示・保存する。

### 4.2 プロ機材アダプタ

| 種別 | 例 | 出力ストリーム | 留意点 |
| --- | --- | --- | --- |
| 映像I/O | SDI/HDMIキャプチャ、NDI | VideoFrame、Timecode | pixel buffer共有、形式検証 |
| カメラトラッカー | Mo-Sys、stYpe、Ncam、FreeD | PoseSample、LensSample | 座標系とレンズ校正の変換 |
| 光学トラッカー | OptiTrack等 | PoseSample | 遮蔽と原点再定義を通知 |
| レンズエンコーダ | FIZ、ズーム／フォーカス | LensSample | サンプル遅延を補正 |
| 同期装置 | Genlock、PTP、LTC/VITC | ClockSample | ロック状態と不確かさを監視 |

アダプタは動的プラグインとして追加可能にする。本番で使うアダプタは、署名、互換性、入出力形式、遅延測定値を登録してから有効化する。

## 5. iPhone対応設計

### 5.1 iPhoneの役割

iPhoneは「モバイル・キャプチャノード」として接続する。用途に応じ、以下を個別に有効化できる。

- 映像カメラ: AVFoundationで取得した映像を低遅延伝送する。
- トラッキング端末: ARKitのワールドトラッキングとCoreMotion IMUをPoseSampleとして送る。
- 深度端末: LiDAR搭載機ではシーン深度と信頼度マップを送る。非搭載機の深度推定はoptional capabilityとする。
- 校正端末: AprilTag／チェッカーボード等を用いたステージ原点合わせを支援する。
- リモートモニター: プレビュー、録画状態、テイク名、警告を表示し、許可された操作だけを送る。

### 5.2 iPhone Capture Node

```text
iPhone
  AVCaptureSession ───────┐
  ARSession ──────────────┼─ Capture Node ─ encrypted LAN transport ─ Mac
  CoreMotion ─────────────┤
  LiDAR / sceneDepth ─────┘

Mac
  iPhoneDeviceAdapter → VideoFrame / PoseSample / DepthFrame / ClockSample
```

映像とセンサー値を単に同時送信してはならない。各データに単調増加クロックによる取得時刻を記録し、Macとのクロック差、往復遅延、ジッターを継続測定する。

### 5.3 座標系と校正

- ARKitのローカルワールド座標系を、そのままステージ座標系として保存しない。
- 接続時に`T_stage_from_phoneWorld`を求め、PoseSampleをステージ座標系へ変換する。
- 変換は固定マーカー、既知のステージ基準点、またはプロトラッカーとの同時観測で校正する。
- ARセッションのリローカライズ、原点変更、追跡喪失を`referenceSpace`変更イベントとして扱う。無通知で連続座標として扱わない。
- ARKitのカメラ内部パラメータ、画像解像度、露出情報が得られる場合はフレームごとのメタデータに保持する。

### 5.4 品質制約とフォールバック

| 状態 | 判定例 | 動作 |
| --- | --- | --- |
| Nominal | 良好なトラッキング、許容ジッター内 | 通常の追従合成 |
| Degraded | 暗所、特徴点不足、Wi-Fi混雑 | 予測を短縮、UI警告、状態記録 |
| Limited | ARKitのlimited状態、深度信頼度低下 | 深度遮蔽を無効化または保守的に処理 |
| Lost | トラッキング／接続喪失 | 最終安定Poseを保持し、必要に応じて出力を保護 |

iPhone利用時は、Mac側でフレームバッファ遅延とセンサー時刻のズレを可視化する。プロ機材への切替時も、同じCamera Sourceを切り替えるだけでシーン、レンズモデル、出力設定を再利用できることを要件とする。

### 5.5 複数iPhoneとMacホスト

MacはVPX Hostとして複数のiPhone Capture Nodeを同時接続できる。各iPhoneは固有のnodeID、証明書、能力セット、クロック推定値を持つ独立した入力ソースであり、映像・Pose・深度・診断を他のNodeと混在させない。

```text
iPhone A ─ Video / Pose / IMU / Depth ┐
iPhone B ─ Video / Pose / IMU / Depth ├─ Wi-Fi ─ VPX Host on Mac
iPhone C ─ Video / Pose / IMU / Depth ┘
                                             ├─ per-node time alignment
                                             ├─ per-node jitter buffer
                                             └─ per-node health monitor
```

#### 接続と通信経路

Bluetoothは近距離発見および初回ペアリングの補助に限定する。映像、深度、Pose、IMUといった本データはWi-Fi（同一LANまたはpeer-to-peer Wi-Fi）を使用する。BluetoothのOSペアリング状態だけを信頼の根拠にせず、QRコードまたは確認コードを用いるアプリケーションレベルの相互認証を行う。

| 経路 | 用途 | 要件 |
| --- | --- | --- |
| Bonjour + Network.framework | Host発見、接続確立 | ローカルネットワーク権限、Node能力の照合 |
| TLS付き信頼性ストリーム | 認証、制御、設定、Take状態 | 順序保証、再送、監査ログ |
| 低遅延データグラム | Pose、IMU、深度メタデータ、診断 | 連番、取得時刻、期限切れパケットの破棄 |
| 低遅延映像ストリーム | HEVC/H.264等のエンコード映像 | フレームID、キーフレーム要求、遅延計測 |

Multipeer Connectivityは接続補助に使えるが、映像の本線には採用しない。セッション上限と基盤トランスポートの選択を制御できないためである。HostはNetwork.frameworkのリスナーで各Nodeに個別接続を割り当て、接続上限と帯域を明示的に管理する。

#### Node管理と帯域ポリシー

初期の標準プロファイルは2〜4台のiPhoneとする。対応台数は固定値ではなく、Hostのデコード能力、Wi-Fiアクセスポイント、要求解像度、フレームレート、深度送信の有無からAdmission Controlで決定する。

- Nodeを接続順ではなく、primaryCamera、secondaryCamera、trackerOnly、monitorOnlyの役割で管理する。
- 各Nodeに映像ビットレート、解像度、fps、深度fps、Pose送信レートの上限を割り当てる。
- 帯域不足では、低優先度Nodeの映像解像度を下げるか映像を停止する。Poseと制御チャネルは維持する。
- 各Nodeについて、往復遅延、映像フレーム年齢、ジッター、デコード遅延、ARKit状態、バッテリー、温度を表示・記録する。
- Nodeが切断した場合、他のNodeおよび本番出力の処理を停止させない。必要なソースだけを保護状態へ遷移する。

複数NodeのARKit座標系は相互に一致しないため、NodeごとにT_stage_from_nodeWorldを校正・保存する。各Nodeは再ローカライズや追跡喪失を独立したイベントとして通知し、別NodeのPoseへ影響させてはならない。

## 6. 時刻同期、センサーフュージョン、遅延制御

### 6.1 時刻モデル

内部時刻は`hostMonotonicTime`を基準にし、SMPTE Timecodeは記録・外部同期・テイク照合に使用する。全入力に対して次を推定する。

```text
alignedTime = sourceTime + clockOffset + driftCorrection
uncertainty = clockUncertainty + transportJitter + sourceJitter
```

Genlock/PTP/LTCがあるプロ構成ではそれらを優先クロックとしてロック状態を表示する。iPhone等の非同期入力ではネットワーク時刻推定を用い、不確かさが設定値を超える場合に「同期済み」と表示してはならない。

### 6.2 Pose Fusion

Pose Fusionは単純平均しない。各入力の共分散、遅延、座標系、品質を考慮して拡張カルマンフィルタまたは因子グラフとして実装する。

```text
IMU / ARKit / 光学トラッカー / エンコーダ
                 │
                 ▼
     Coordinate Transform + Time Alignment
                 │
                 ▼
           Fusion & Outlier Rejection
                 │
                 ▼
       Pose + Velocity + Covariance + Quality
```

レンダリング時は表示遅延を見込んだ短時間予測Poseを使用できる。ただし予測時間、推定値、実測値の差をテレメトリに残し、外挿が上限を超えた場合は予測を止める。

### 6.3 レイテンシ予算

プロファイルごとに入力、処理、出力の予算を設定する。初期目標は4K/60pの標準プロファイルで、合計1フレーム未満の追加処理遅延とする。ネットワーク経由のiPhone入力は、ネットワーク遅延を別枠で測定・表示する。

## 7. カメラ、レンズ、深度モデル

### 7.1 Camera Rig

```text
CameraRig
  Sensor: physical width/height, active resolution, pixel aspect
  Lens: focal length, focus distance, iris, distortion, breathing
  Shutter: exposure, shutter angle, rolling-shutter profile
  Pose: transform, velocity, covariance
  Calibration: intrinsics, extrinsics, validity range
```

プロカメラでは実測またはメーカー提供のレンズテーブルを使用する。iPhoneではフレームに関連付いた内部パラメータを基礎とし、必要に応じてユーザー校正を追加する。いずれも「推定値」と「実測校正値」を区別して保存する。

### 7.2 校正成果物

校正値はバイナリに埋め込まず、バージョン付きの独立成果物として管理する。

```text
CalibrationProfile
  profileID, deviceID, lensID, createdAt, operator
  intrinsics, distortion coefficients, breathing table
  stage transform, validity range, residual error
  source (measured | manufacturer | estimated)
```

校正画面では残差、適用範囲、有効期限、最後の検証日時を表示する。プロファイル変更はライブ中に即時反映せず、明示的に適用し、Takeメタデータに記録する。

### 7.3 深度・マット

深度は真値とは限らないため、深度テクスチャと信頼度テクスチャを常に組にする。合成マットはChroma、深度、時間的一貫性、人物セグメンテーションを信頼度重みで統合する。

```text
finalMatte = fuse(chromaMatte, depthMatte, temporalMatte, neuralMatte,
                  perPixelConfidence)
```

髪、半透明物、高速移動、被写体境界では、出所と品質をデバッグ表示できるようにする。

## 8. Realtime Frame Graph

### 8.1 標準パス

```text
Acquire → Normalize → Lens Undistort → Key/Depth
        → Camera Pose Resolve → 3D Render → Composite
        → Color Output Transform → Present / Encode / Output
```

各パスは入出力形式、色空間、必要な同期フェンス、品質レベルを宣言する。スケジューラは依存関係からMetalコマンドバッファを構成し、不要なCPU待機を避ける。

### 8.2 品質プロファイル

| プロファイル | 用途 | 方針 |
| --- | --- | --- |
| Live Fast | リハーサル、iPhoneの小規模撮影 | Raster中心、低コストキー、動的解像度 |
| Live Quality | 本番の標準 | Raster + 選択的RT、時間再構成 |
| Review Cinema | テイク再合成 | 高品質キー、追加サンプル、オフライン許容 |

品質を落とす順序は、再構成用内部解像度、任意のレイトレーシング、非必須のAIパスとする。Camera Pose、時刻整列、カラー変換、収録メタデータは劣化対象にしない。

### 8.3 カラー処理

```text
Input camera encoding
  → Input Device Transform
  → scene-linear working space (ACEScg候補)
  → render / composite
  → Output Device Transform
  → SDR / HDR / LED / recording
```

入力の色メタデータが欠ける場合は推定として扱い、操作者が明示選択するまで本番プリセットを自動適用しない。LUTは変換の一部としてバージョンとハッシュをTakeに記録する。

## 9. シーン、LED、出力

### 9.1 シーン

OpenUSDをシーン交換形式の中心とし、レイヤー、バリアント、アセット参照を保持する。ライブ中に変更可能な値は、明示したRuntime Parameterに限定する。

### 9.2 LED Wall

LED構成はパネル配置、物理寸法、色、輝度、遅延、スキャン設定を`LEDWallProfile`として保存する。カメラPoseに基づくoff-axis frustumを生成し、プロファイルと同期状態が有効な時だけ本番出力を許可するポリシーを選択可能にする。

### 9.3 出力

- プレビュー: Metal表示。fps、遅延、入力品質、同期状態をオーバーレイ表示する。
- 収録: ProRes等の映像、音声、主要な補助パスを収録する。
- ライブ出力: SDI、HDMI、NDI等をアダプタ経由で実装する。
- リモート: 認証済み端末へ読み取り中心の監視データを配信する。

## 10. Takeと再構成可能な収録

各Takeは完成映像だけでなく、再合成に必要な状態を保存する。

```text
Take_0027/
  manifest.json
  video/camera.mov
  video/composite.mov
  auxiliary/matte.exr
  auxiliary/depth.exr
  tracking/pose-stream.bin
  calibration/profile-references.json
  scene/scene.usda
  color/transform-manifest.json
  audio/program.wav
  diagnostics/timing.json
```

`manifest.json`にはソフトウェア版、プラグイン版、デバイス、入力形式、フレーム欠落、同期品質、校正プロファイル、シーンとアセットのハッシュを含める。後日のレビュー時に同じ条件を再現・検証できる。

## 11. UI／UX設計

作業モードは`BUILD`、`CALIBRATE`、`REHEARSE`、`LIVE`、`RECORD`、`REVIEW`とし、モードごとに必要な操作だけを前面へ出す。

- BUILD: USDシーン、ライト、メディアを構成する。
- CALIBRATE: カメラ、iPhone、レンズ、ステージ原点、LEDを検証する。
- REHEARSE: 合成品質とレイテンシを確認する。本番出力は明示的に有効化する。
- LIVE / RECORD: 大きな状態表示、誤操作防止、詳細な診断ログを優先する。
- REVIEW: Takeを再生し、補助パスと当時の設定を比較する。

すべてのユーザー向け文言と状態ラベルは英語、日本語、简体中文を提供する。数値、単位、タイムコード、警告種別は翻訳に依存しない構造化データとして管理する。

## 12. プラグインとセキュリティ

プラグイン種別は`VideoIO`、`Tracking`、`Lens`、`Depth`、`Codec`、`Protocol`、`Output`とする。プラグインはcapability、対応形式、最悪遅延、必要権限、バージョンを宣言する。

- iPhone Capture Nodeはペアリング済み端末のみ接続できるようにする。
- 複数Nodeの初回ペアリングは、Bluetoothによる近距離発見を補助に使いつつ、QRコードまたは確認コードで相互認証する。
- ローカルネットワーク上の映像・制御通信は認証と暗号化を使用する。
- リモート操作はロールを分離し、LIVE中の危険な設定変更は確認または権限制御を要求する。
- 機材切断、時刻同期喪失、ストレージ不足、温度／性能低下、フレーム落ちは監視対象とする。
- Takeと校正成果物の改変は監査可能にする。

## 13. 性能・信頼性の受け入れ基準

初期リリースでは対応Macと対応デバイス構成を明示した上で、次を測定する。

| 項目 | 基準 |
| --- | --- |
| 標準入力 | 4K/60p、10-bit入力を対象にする |
| フレーム処理 | 本番プロファイルで連続運転中に期限超過を検出・記録できる |
| 遅延 | 入力→出力を計測し、経路別内訳を表示できる |
| 映像経路 | 対応機器ではCPUコピー回数をテレメトリで確認できる |
| トラッキング | Poseの年齢、ジッター、品質、追跡喪失を表示・記録できる |
| iPhone | 接続、クロック差、ARKit状態、深度信頼度をNodeごとに表示できる |
| 複数iPhone | 2〜4台の標準プロファイルで、Nodeごとの帯域・遅延・フレーム落ちを監視し、他Nodeを止めずに切断復旧できる |
| 収録 | テイクに設定、校正、診断、補助パスの参照を保存できる |
| 復旧 | 入力断・トラッキング断の挙動がプロファイル通りである |

## 14. 開発ロードマップ

- [Done] 設計書を、プロ機材とiPhoneを共通アダプタ／時刻モデルで扱う方針へ更新。
- [Next] MVP: 1入力映像、1カメラPose、基本レンズ補正、3D背景、合成、プレビュー、Take manifest。
- [Next] iPhone Capture Node: 映像、ARKit Pose、CoreMotion、対応端末の深度、クロック品質の送信。
- [Next] 複数iPhone Host: Bonjour発見、QRまたは確認コードによる相互認証、Node別Wi-Fi接続、帯域制御、状態監視。
- [Next] 校正ワークフロー: ステージ座標合わせ、カメラ内部パラメータ、レンズプロファイル、品質可視化。
- [Later] SDI/NDI出力、外部トラッカー／レンズエンコーダ、Genlock/PTP対応。
- [Later] LED wall向けfrustum、選択的RT、再合成用の高品質処理。
- [Later] 署名付きプラグイン配布、リモート監視・運用管理。

## 15. 実装開始時の決定事項

実装開始前に、次をプロジェクト設定として固定する。

1. MVPで最初に対応する入力（iPhone、UVC、または特定のSDIキャプチャ機器）。
2. 基準解像度・フレームレート、および許容遅延の測定方法。
3. ステージ座標系の単位・軸方向・原点の規約。
4. Take Packageのスキーマと互換性方針。
5. iPhone Capture Nodeの最低OS、対応機種、LiDARを必須にするかどうか。
6. 本番モードへ入るために必要な校正・同期チェックのポリシー。
7. 同時接続するiPhone数、Nodeごとの映像プロファイル、使用するWi-Fiアクセスポイントの要件。

この設計により、iPhoneは簡易機材として別系統に扱われるのではなく、品質・同期の制約を明示した正規のデバイスとして、VPX Studioの同一パイプラインへ参加する。
