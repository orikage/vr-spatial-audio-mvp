# VR空間音声 MVP

*2026年3月*

---

## 成功条件

> **空間上を動く音源ポインタが、自分との距離に応じて「クリアな近傍ボイス」と「こもった遠方アンビエント」に切り替わること**

---

## スコープ

| 項目 | 内容 |
|------|------|
| 入力 | wavファイルをループ再生する疑似音源ポインタ |
| 出力 | 距離に応じた音量減衰＋ローパスフィルタ処理 |
| UI | Canvas 2D上でポインタを移動させて確認 |
| 人数 | 2〜5人（概念実証） |
| VR対応 | 対象外 |
| ネットワーク | 対象外（ローカル動作のみ） |

---

## 技術スタック

追加ライブラリなし。HTMLファイル1個で動作する。

- **PannerNode**：距離に応じた音量減衰・定位
- **BiquadFilterNode**：遠方のローパスフィルタ（こもり感）
- **GainNode**：ゾーン切り替え・アンビエント合成
- **Canvas 2D**：音源ポインタの可視化

---

## ゾーン設計

```
0 ────────── d_near ────────── d_trans ────────── ∞
    nearゾーン     transitionゾーン    ambientゾーン
```

ゾーン境界は会場の背景騒音レベル（`ambientNoiseSPL`）から導出する。

```javascript
// ソース別に SPL_ref を設定可能（デフォルト: 会話 65dB、叫び 85dB）
const SPL_ref_default = 65; // 会話音声の平均 [dB]
const SPL_ref_shout   = 85; // 叫び声相当 [dB]

// 音源ごとに dynamicSPL を決定（UI で選択可能）
const SPL_ref = sourceType === 'shout' ? SPL_ref_shout : SPL_ref_default;

const d_near  = Math.pow(10, (SPL_ref - ambientNoiseSPL - 15) / 20); // SNR=15dB
const d_trans = Math.pow(10, (SPL_ref - ambientNoiseSPL - 5)  / 20); // SNR=5dB
```

**応援上映（ambientNoiseSPL=75dB）の場合：**

| ゾーン | 距離 | 処理 |
|--------|------|------|
| near | 0〜3.2m | クリア再生、HRTFで定位 |
| transition | 3.2〜10m | 音量・cutoff・定位を連続的に変化 |
| ambient | 10m〜 | ローパス＋アンビエントバスに合成 |

---

## 音響パラメータ

### cutoff周波数（距離から物理的に導出）

```javascript
// 遠方の「こもり感」を演出する経験的モデル（ISO 9613-1は数百m以上スケールのため強調した値を使用）
f_cutoff(d) = 30000 / Math.pow(d, 2/3)  // [Hz]

// ゾーン境界でのcutoff（ambientNoiseSPL=75dBの場合）
f_near  = f_cutoff(d_near)   // 例：〜13800Hz（d_near=3.2mのとき）
f_trans = f_cutoff(d_trans)  // 例：〜6500Hz （d_trans=10mのとき）
```

### transitionゾーンの補間（完全クロスフェード）

```javascript
const t   = (d - d_near) / (d_trans - d_near); // 0.0〜1.0
const t_s = 3*t*t - 2*t*t*t;                   // smoothstep

const gain_physical = 1 / d;  // 逆距離則（全ゾーン共通の基準）

// 直達パス（near+trans）：合計は常に gain_physical で一定（+6dB境界ジャンプなし）
const G_clear = gain_physical * (1 - t_s);     // nearパスのgain
const G_trans = gain_physical * t_s;           // transパスのgain
nearGain.gain  = G_clear;
transGain.gain = G_trans;
// 確認: G_clear + G_trans = gain_physical （物理減衰で一定）

// ambientバスへの寄与（transitionゾーンで徐々に増える）
// = transパスと同じ t_s で補間（同一経路でも別経路でもリスナーは同じ物理エネルギーを知覚）
const G_amb_indiv = gain_physical * t_s;
indivAmbGain.gain = G_amb_indiv;

// cutoff（対数補間：人間の周波数知覚は対数的）
cutoff = Math.exp(Math.log(f_near) * (1 - t_s) + Math.log(f_trans) * t_s);
```

### ambientゾーンの密度補正（実効人数 N_eff ベース）

各音源の `indivAmbGain` は距離減衰だけ担当する。正規化はAmbGainで一括処理する。

```javascript
// 各音源（AmbientBusに流す直前）
// ゾーンによって値が変わる。N_eff正規化はAmbGain側で実施
indivAmbGain = (1 / d) * t_s;  // transitionゾーン（t_s: 0→1）
indivAmbGain = 1 / d;          // ambientゾーン（t_s=1 で上式と一致）

// 実効人数の計算（フレーム毎に全音源を走査）
let N_eff = 0;
for (let source of allSources) {
  const t_s = computeSmoothstep(source.distance, d_near, d_trans);
  N_eff += t_s * t_s;  // 寄与率の二乗和
}

// AmbGain（バス出口で1回だけ更新）
const gain_normalized  = 1 / Math.sqrt(Math.max(N_eff, 1)); // ゼロ割対策
const density_boost_dB = 6 * Math.tanh(N_eff / 30);
const gain_density     = Math.pow(10, density_boost_dB / 20);
AmbGain                = gain_normalized * gain_density;
// N_eff が変化したときここだけ更新すればよい
```

**Why:** N_eff = Σ(t_s_i²) は transitionゾーンの音源の実質的な寄与度を反映するため、人数変動時のダッキングが滑らかになる。

---

## ノードグラフ

```
[Source]
  ├→ [HighShelf +2dB] → [HRTF Panner]  → [NearGain]  ──────────────────────→ [Master Out]
  ├→ [LowPass(可変)]  → [Equal Panner] → [TransGain] ──────────────────────→ [Master Out]
  └→ [IndivAmbGain]  → [AmbientBus]（全音源合算）
                              ↓
                        [AmbGain = 1/√N_eff × 密度ブースト]
                              ↓
                  [VirtualGain_0..7 = 1/√8（固定値）× Oscillator_0..7]
                              │ （各 Oscillator は独立した周波数・位相）
                              ↓
                  [VirtualPan_0..7]（0°/45°/90°…315°に配置）
                              ↓
                        [Reverb or バイパス]
                              ↓
                          [Master Out]
```

ゾーン切り替えはgainで制御する。`disconnect()`/`connect()`は使わない（ただし、300人規模では完全に沈んだ音源のgainを明示的に0にセットするか `disconnect()` で接続解除を推奨）。

```javascript
// 常時全ノードを接続しておき、gainで0にする
nearGain.gain.linearRampToValueAtTime(g, ctx.currentTime + 0.05);
```

---

## ユーザー設定パラメータ

```javascript
const venueConfig = {
  ambientNoiseSPL: 75,  // 会場の背景騒音レベル [dB SPL]
  maxNearVoices:   5,   // 近傍同時再生上限
};
```

これ以外のパラメータはすべて導出または固定。

---

## 実装上の注意点

```javascript
// 1. sampleRateを明示（HRTF精度）
const ctx = new AudioContext({ sampleRate: 48000, latencyHint: 'interactive' });

// 2. Autoplay Policy対策
document.addEventListener('click', () => ctx.resume(), { once: true });

// 3. リスナーの向きを更新しないとHRTFの定位が崩れる。不連続な更新はグリッチの原因になるため
//    前フレームの値から16ms（1フレーム分）かけてスムージングしながら適用する。
ctx.listener.forwardX.linearRampToValueAtTime( Math.sin(angle), ctx.currentTime + 0.016);
ctx.listener.forwardZ.linearRampToValueAtTime(-Math.cos(angle), ctx.currentTime + 0.016);

// 4. CanvasとWeb Audio APIの座標系変換（Y軸が逆）
pannerNode.positionZ.value = -canvas_y / 20;

// 5. PannerNodeの距離減衰を必ずOFFにする（GainNodeで手動制御するため）
//    rolloffFactor=1（デフォルト）のままにすると、GainNodeの 1/d と二重減衰になる
pannerNode.rolloffFactor = 0;
pannerNode.maxDistance   = 10000;  // デフォルト値だが明示

// 6. linearRampToValueAtTimeは直前にsetValueAtTimeがないと動作未定義
//    必ずセットで使う。0への遷移はexponentialRampが使えないのでsetTargetAtTimeを使う
nearGain.gain.setValueAtTime(nearGain.gain.value, ctx.currentTime);
nearGain.gain.linearRampToValueAtTime(g, ctx.currentTime + 0.05);
// → 0に下げる場合はこちら（tau=20ms）
nearGain.gain.setTargetAtTime(0, ctx.currentTime, 0.02);

// 7. HighShelfのパラメータ（nearパスのみ。transゾーンでnearGainが0に近づくと自然に消える）
highShelf.type            = 'highshelf';
highShelf.frequency.value = 3000;  // [Hz] 明瞭感のプレゼンス帯域
highShelf.gain.value      = 2;     // [dB]

// 8. 仮想8音源の独立ゆらぎ（各 Oscillator に異なる周波数を割り当て）
const virtualGains = [];
const oscillators  = [];
const baseFrequencies = [0.35, 0.48, 0.62, 0.78, 0.94, 1.11, 1.29, 1.47]; // Hz
const phaseOffsets = [0, 45, 90, 135, 180, 225, 270, 315].map(deg => deg * Math.PI / 180);

for (let i = 0; i < 8; i++) {
  const osc = ctx.createOscillator();
  osc.frequency.value = baseFrequencies[i];
  osc.start();
  oscillators.push(osc);

  // OscillatorNode の出力を GainNode のゆらぎ制御用に接続
  // gain = (base * (1 + osc * 0.3)) の形式で modulateGain を実装
  const virtualGain = ctx.createGain();
  virtualGain.gain.value = (1 / Math.sqrt(8)) * 1.0; // base level
  osc.connect(virtualGain); // オシレータ出力でgainを変調
  virtualGains.push(virtualGain);
}

// 9. スケーラビリティ対策：300人規模の自動mute戦略
function updateAudioGraph(allSources) {
  let N_eff = 0;
  for (let source of allSources) {
    const t_s = computeSmoothstep(source.distance, d_near, d_trans);
    N_eff += t_s * t_s;

    // 完全に沈んだ音源（t_s < 0.01）の自動mute
    if (t_s < 0.01) {
      source.gainNode.gain.value = 0;  // またはdisconnect()で接続解除
    }
  }

  // AmbGain を N_eff で更新
  const gain_normalized = 1 / Math.sqrt(Math.max(N_eff, 1));
  const density_boost_dB = 6 * Math.tanh(N_eff / 30);
  ambGainNode.gain.value = gain_normalized * Math.pow(10, density_boost_dB / 20);
}

// 10. 位相問題（同一wavの多重再生）：
//     同じファイルを全音源で使うと位相が揃い、インコヒーレント合成の仮定(√N)が崩れる。
//     対策として再生開始時に `Math.random() * buffer.duration` のオフセットを入れる。
const source = ctx.createBufferSource();
source.buffer = audioBuffer;
source.loop = true;
source.start(0, Math.random() * audioBuffer.duration);

// 11. ソフトキャップ（音質の段差解消）：
//     near優先度 6-8位 の音源に対し、nearGainとindivAmbGainを 0.5 固定で割り振ることで
//     「クリア」から「アンビエント」への遷移に中間状態を設け、UX上の段差を解消する。
if (rank >= 6 && rank <= 8) {
  nearGain.gain.setTargetAtTime(g_phys * 0.5, ctx.currentTime, 0.05);
  indivAmbGain.gain.setTargetAtTime(g_phys * 0.5, ctx.currentTime, 0.05);
}
```

---

## 確認ポイント

- 近くと遠くで明確な音の差があるか
- ポインタ移動に追従してリアルタイムに変化するか
- ローパス適用でこもり感が出ているか
- 複数音源が混在しても近傍ボイスが埋もれないか
- 遠方アンビエントが群衆感として聞こえるか
- **transitionゾーン通過時の境界での+6dB音圧ジャンプがないか**
  （完全クロスフェード設計で直達合計 G_clear + G_trans = 1/d で安定）
- **N_eff 計算が動的に更新されているか**
  （各フレーム Σ(t_s_i²) を再計算し、人数変動が滑らかに反映されるか）
- **仮想8音源のゆらぎが非同期になっているか**
  （各Oscillatorが異なる周波数で動作し、脈動が聞こえないか）
- **叫び声相当のwav（高SPL）を使う場合は対応**：SPL_ref を sourceType で動的に設定。
  会話（65dB）と叫び（85dB）で異なるゾーン境界が得られることを確認。
- **300人規模テスト予定時**：沈んだ音源（t_s < 0.01）の自動mute実装により CPU コスト削減
- **ソフトキャップによる音質段差の解消**：Near上限付近で音源が入れ替わっても、音質が急変しないか
- **リスナーの向きの滑らかさ**：角度変化時にプツプツというノイズや定位の飛びがないか
