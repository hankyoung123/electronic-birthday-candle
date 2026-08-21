# 真机校准手册（系统 AEC + 低频风噪检测）

> 目标：用 Debug Panel 的实时数据，在真机上确认系统回声消除（Voice Processing）把
> 自家音乐从麦克风里消掉，并校准 80–500 Hz 低频风噪检测的最终参数。
> 本手册只针对真机（Debug 构建），Release 不包含可调入口。

## 0. 当前检测链路（唯一生产路径）

```text
Music → Speaker
          │
          ▼
iOS Voice Processing / AEC（系统回声消除，AudioEngine 启动时启用）
          │
Mic ──────┘
          ↓
Clean Mic PCM
          ↓
Low-frequency Wind Detector（BlowDetector，80–500 Hz）
          ↓
Temporal Confirmation（CeremonySession：Start/Maintain/Duration/Decay）
          ↓
Blow Intensity → 火焰响应 / extinguish()
```

- **AEC**：`AudioEngine.start()` 先 `inputNode.setVoiceProcessingEnabled(true)`，
  失败即启动失败（不 fallback）；tap 装在 voice-processed input 上。
- **Wind Detector**（`BlowDetector`，无自适应基线/无宽带/无 delta）：

```text
totalRMS          = 时域 RMS
windBandPower     = FFT 80–500 Hz 功率和
windRatio         = power(80–500) / power(80–5000)
windBandRMS       = totalRMS × √(80–500 能量占比)   # Parseval，与 totalRMS 同量纲

windEnergyScore   = normalize(windBandRMS, windStart, windFull)
windRatioScore    = normalize(windRatio,  windRatioStart, windRatioFull)
rawScore          = windEnergyScore × 0.75 + windRatioScore × 0.25   # 全加法
```

- 无硬乘门槛、无固定峰值频率、无 A&&B&&C。High/宽带/平坦度/自适应基线**已整体删除**。

熄灭判定（`CeremonySession`，偏宽松）：`Start=0.35 / Maintain=0.18 / Duration=0.35s / Decay=0.40`。

## 1. Debug Panel

- `Input Route` / `Sample Rate` / **`Voice Processing: On/Off`**（确认 AEC 已启用）
- `RMS / dBFS`
- `Wind Power` / `Wind RMS` / `Wind Ratio`
- `Wind Energy Score` / `Wind Ratio Score` / `Raw Score` / `Smoothed`
- `Strong`（已累计 / 所需）

**Live Tuning**：`Wind Start / Full`、`Wind Ratio Start / Full`、`Energy Wt / Ratio Wt`、
`Start / Maintain / Duration / Decay`、`Music Volume`。
**Copy Values** 10 键；**Copy Snapshot** / **Copy 3s Avg**。

## 2. AEC 验证（真机，任务 8）

逐项观察 `Wind RMS / Wind Ratio / Raw Score / Smoothed`：

| 场景 | 期望 |
| --- | --- |
| A. 安静 | Wind RMS 接近底噪，Raw ≈ 0 |
| B. 音乐 30% | **Raw 不明显上升**（AEC 消掉了扬声器音乐）|
| C. 音乐 70% | 同上（音量再大也不显著增加）|
| D. 音乐 100% | 持续 30s：Raw 仍不涨、不熄灭 |
| E. 正常吹气 | **Wind RMS / Raw 明显上升** |
| F. 音乐 70% + 吹气 | 吹气仍能可靠熄灭 |

**判定**：`音乐音量增大 → Blow Score 不明显增加`；`真实吹气 → Wind 明显上升`。
若 B/C/D 里 Raw 随音量增大而显著上升 → AEC 未按预期工作，先检查
`Voice Processing: On` 与输出设备（扬声器必须走同一 AVAudioEngine 才能被 AEC 参考）。

> 已知边界（合成信号已证实）：**浊音讲话/低音音乐本身也是低频主导，windRatio≈0.94–0.97**，
> 该软特征无法区分“浊音”与“低频气流”——区分靠 AEC 去掉音乐 + 时长确认。
> 这就是本轮把音乐误触的解决押在 AEC 上、而非继续加检测特征的原因。

## 3. 定参规则（对照数据）

1. **Wind Start/Full**（默认 0.03 / 0.14，RMS 量纲）：真机轻吹 Wind RMS 偏低 → 调低
   Start（火焰更快响应）；讲话稳态误触发 → 调高 Full 或 Start。
2. **Wind Ratio Start/Full**（默认 0.35 / 0.65）：用于滤掉高频/噪声类声音（纯音、白噪、
   拍手等 ratio 低）。若这些仍误触发 → 调高 Start。
3. **Energy/Ratio Wt**（默认 0.75/0.25）：真吹主要靠能量 → 保持 Energy 主导；噪声误触发
   多 → 适度提 Ratio Wt。
4. **Start/Maintain/Duration/Decay**：保持偏宽松；真机误触发再上调 Start。

## 4. 固化步骤

1. 真机跑完第 2 节 A–F，用 **Copy Values** 拿到 10 键，把非默认值写回
   `BirthdayCandle/Audio/BlowDetectionConfiguration.swift`。
2. 连测 3 轮。
3. Release 自动不含 Inspector（全部 `#if DEBUG`）。

## 5. 验收

- [ ] 音乐 100% 音量持续 30s → 不熄灭（AEC 生效）。
- [ ] 音乐音量突然变化 → 不熄灭。
- [ ] 正常讲话 → 不轻易熄灭。
- [ ] 普通力度吹气 → 火焰立即明显响应。
- [ ] 持续吹 0.3–0.8s → 稳定熄灭。
- [ ] 音乐 + 普通吹气 → 稳定熄灭。

## 6. 第二阶段（仅在需要时）

若 AEC + 80–500Hz 风噪仍分不清吹气与音乐，再考虑：

```text
Normalized FFT → Blow Reference Spectrum → Cosine Similarity
rawScore = windEnergy×0.60 + windRatio×0.20 + templateSimilarity×0.20
```

不直接上 MFCC / ML。当前先做 v1，收真机 A–F 数据再决定。
