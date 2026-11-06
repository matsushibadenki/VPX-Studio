# Phase 1：Metal合成MVP

## 操作

1. 入力パネルの「glTFシーンを開く」で`Examples/Phase1/CubeAndFloor.gltf`を読み込む。カメラは未校正の場合だけシーン全体に合わせて配置する。
2. Inspectorの「カメラ校正を読み込む」で`Examples/Phase1/CameraCalibration.json`を読み込む。サンプル値は推定値であり、実機の測定値ではない。
3. ローカルカメラまたはベンチマークを選択する。「入力色変換」が自動の場合、既知のRec.709原色とsRGB／Rec.709／Linear伝達特性だけを受け付ける。不明な場合は保護表示となり、操作者が入力を確認して明示的に選択する。
4. 表示パスで合成、CG、補正後実写、アルファマットを切り替えて検証する。クロマキーは線形化した映像から独立したマットを生成するため、旧版と同じしきい値が同じ結果を保証するものではない。
5. 診断履歴の「入力形式別の計測」で、取込時間、色変換GPU時間、予算超過回数を確認する。診断JSON v5は描画設定、校正、カメラ変換、入力形式別統計、GPU期限超過数、保護状態も保存する。

LIVE／RECORDではシーン・校正・入力色・品質・デバッグ表示の変更とベンチマーク開始を禁止する。デバッグ表示は合成へ戻る。校正使用中は校正と食い違う手動焦点距離・K1変更を禁止し、breathingテーブルのフォーカス距離のみ調整できる。校正の解除と追跡基準の再設定は本番モードを離れてから行う。

## glTFサブセット

[Khronos glTF 2.0仕様](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html)に基づく、静的・不透明・無テクスチャのTRIANGLESサブセットを実装する。

- JSON `.gltf`、埋込みbase64または同一ディレクトリ以下の外部バッファ。ネットワークURIやディレクトリ外参照は拒否する。
- FLOAT VEC3 POSITION／NORMAL、非正規化の8／16／32-bitインデックス。NORMAL省略時は面法線を生成する。
- ノードのTRSまたは列優先4×4アフィン行列、階層、選択シーン。非有限値、循環、不正参照、反転／特異変換、範囲外アクセスは拒否する。
- metallic-roughness PBRのbaseColorFactor、metallicFactor、roughnessFactor。Cook–TorranceのGGX・Schlick近似で描画する。
- 1灯の`KHR_lights_punctual` directional light。省略時はアプリの標準ライトを使用する。1024×1024の深度シャドウマップを生成する。

GLB、画像テクスチャ、double-sided、透明マテリアル、スキン、アニメーション、morph、sparse accessor、圧縮拡張、ポイント／スポットライトは対象外とし、読込エラーを表示する。これはOpenUSDやglTF全体の実装完了を意味しない。JSONは64MiB、個別バッファ128MiB、バッファ合計256MiB、展開頂点合計200万を上限とする。

## カメラ校正

JSONのスキーマはサンプルファイルを基準とする。`fx/fy/cx/cy`は校正画像上のpixel単位、画像サイズは校正時の解像度、外部変換はm単位の右手系でカメラ前方は−Z。レンズはBrown–Conradyの`k1/k2/k3/p1/p2`を使用する。表示解像度変更時には正規化した内部パラメータを使うが、センサークロップ・画角が変わる入力では再校正が必要である。

breathingテーブルは焦点距離とフォーカス距離の組で、距離順を検証して線形補間する。端点外は端点値を使う。`source`はmeasured／manufacturer／estimatedを明示する。実測精度やステージ残差の認定、デバイスへの校正紐付けはPhase 3で扱う。

トラッキングは最初の有効Poseを基準とした相対移動を、校正またはシーン初期カメラへ適用する。座標系revision変更時はPoseを隔離し、手動で「追跡基準を再設定」するまで復帰しない。これは絶対ステージ座標校正の代用ではない。

## GPUパスとSDR

```text
BGRA / YUV ─ normalize + lens undistort + SDR decode ─ linear video ─ matte
CG meshes ─ shadow map ─ linear PBR scene ─────────────────────────┤
                                               linear composite → sRGB drawable
```

BGRA8、8/10-bit 4:2:0 bi-planarのvideo/full rangeをCVMetalTextureCacheから直接取り込む。YUVのplaneをGPUで変換し、8-bit BGRAへのCPU往復変換は行わない。YCbCr行列はRec.601／709／2020を読み取り、原色が未対応の素材は自動でRec.709と決めつけない。手動選択はRec.709/sRGB原色であることを操作者が確認した上で行う。

合成作業空間はlinear Rec.709/sRGB。sRGB／Rec.709を線形化し、CGとアルファマットを合成した後、sRGB render targetが出力伝達特性を一度だけ適用する。HDR、P3／BT.2020原色の本格色管理、OCIO／ACES、LUTは対象外である。

変換パスのGPU時間を単独command bufferで計測し、共有イベントで後続へ接続する。shadow→scene、matte→composite、scene→compositeは明示的なMetal fenceを用いる。中間バッファはRGBA16Float、マットはR16Floatで、同一フレームの入出力依存関係をFrame Graphに登録する。

## 品質予算と保護

| プロファイル | 描画目標 | 入力期限 | Pose期限 | GPU期限 | 色変換予算 |
| --- | --- | --- | --- | --- | --- |
| Live Fast | 60fps | 500ms | 500ms | 16.67ms | 4ms |
| Live Quality | 60fps | 250ms | 150ms | 16.67ms | 4ms |
| Review Cinema | 15fps | 2s | 2s | 66.67ms | 16ms |

テクスチャ取込のCPU予算は2ms。各値は運用ポリシーであり、全対応機材で達成済みの認定値ではない。GPUの値は変換開始から最終合成完了までの経過時間であり、ディスプレイ表示待機は含めない。

入力期限は受信後経過と、分かる場合はHost時刻へ整列した取得後経過の両方に適用する。到着したばかりでも古い取得フレームは本番へ流さない。時計推定の不確かさを伴うため、機材ごとの遅延実測と併用する。

GPU期限超過が3回連続すると保護色へ切り替え、シーン／影のジオメトリ処理を抑える。10回連続で期限内に戻ると復帰する。LIVE／RECORDの追跡喪失・入力断、未対応入力形式、入力色不明でも保護する。リハーサルでの入力断は実写を外しCGを表示する。保護状態・GPU期限超過は既存の履歴とJSON／JSONL保存に接続する。

## 検証範囲

GPU画素読戻しで、sRGBの往復変換、緑の透明マット、8/10-bit YUV両レンジ、保護表示、PBRライト反映を確認する。ローダーの境界、投影、breathing、GPU復旧ヒステリシス、追跡revisionの隔離も自動テストする。実画面でglTF・校正読込、影、マット表示、LIVE保護、診断の形式別計測を確認済み。

対応Macごとの4K60／10-bit連続入力、実レンズの残差、実機切断・再接続、複数Node、フル解像度時の長時間安定性はPendingであり、小さなGPU画素テストや現在のウィンドウでの60fps表示から認定しない。
