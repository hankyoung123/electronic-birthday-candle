# 真机校准手册（Voice Processing AEC + 带通风噪 + Peak Hold + 时间证据）

> 目标：真机确认 Voice Processing 消掉自家音乐，并校准 80–500 Hz 带通风噪、
> Peak Hold 与证据累计的最终参数。只针对真机（Debug 构建），Release 无可调入口。

## 0. 当前检测链路（唯一生产路径）

```text
AVAudioSession（.playAndRecord + .default + .defaultToSpeaker）
→ AVAudioEngine Voice Processing / AEC（setVoiceProcessingEnabled）
→ 80–500 Hz Direct Band-pass RMS（6 阶，时间域）
→ Wind Ratio（FFT：80–500 / 80–5000）
→ Blow Score = WindEnergy×0.90 + Ratio×0.10
→ Peak Hold（150ms）
→ attack/release smoothing
→ 连续 0…1 intensity（驱动火焰）
→ Evidence Accumulator（CeremonySession）→ Extinguish
```

- **AEC**：Voice Processing 是唯一 AEC 路径（Echo-Cancelled Input 已撤销——iPhone 15
  Pro Max 上 `isEchoCancelledInputEnabled` 强制校验会直接启动失败）。
  统一 `configureInputPath()` = `configureSession → enableVoiceProcessing → installTap`，
  首次启动/中断恢复/Route Change 全走同一顺序；VP 启用失败 → 启动失败（无第二条 AEC 路径）。
- **Wind Detector／Evidence 继续保留**：不恢复 Adaptive Baseline / Delta / Broadband /
  多频段评分 / silenceFloor 硬门槛。

### 证据累计（CeremonySession）

```text
intensity ≥ start(0.28)           → evidence += 1.0 × dt
intensity ≥ maintain(0.10)        → evidence += 0.60 × dt
否则                              → evidence = max(0, evidence − 0.40 × dt)
evidence ≥ required(0.28s)        → extinguish()
```

### Peak Hold（BlowDetector，150ms）

```text
if rawScore >= heldPeak            { heldPeak = rawScore; holdRemaining = 0.15s }
else if holdRemaining > 0          { holdRemaining -= dt }
else                               { heldPeak = rawScore }
有效的 score = hold 内 max(rawScore, heldPeak)，再进 attack/release 平滑
```

目标：真实吹气出现 `0.65 / 0.58 / 0.09(VP 短暂压制) / 0.54 / 0.61` 时，有效强度保持连续。

## 1. Debug Panel

- `Voice Processing: On/Off`；`Mic Permission`；`Session Active`；`Start Failure`（DEBUG，例如
  `Voice Processing initialization failed`）
- `Input Route` / `Sample Rate`
- `Total RMS / dBFS`、`Wind RMS`、`Wind Ratio`
- `Wind Energy Score`、`Wind Ratio Score`、`Raw Score`、`Held Score`、`Smoothed Score`
- `Evidence` / `Required Evidence`；`Music Volume`
- **Live Tuning**：`Peak Hold`、`Wind Start/Full`、`Energy/Ratio Wt`、`Start/Maintain/Duration/Decay`、`Music Volume`
- **Copy Values** 11 键；**Copy Snapshot / Copy 3s Avg**

## 2. 真机验证（顺序）

| # | 场景 | 期望 |
| --- | --- | --- |
| 1 | 无音乐 + 普通吹气 | 0.3–0.8s 熄灭 |
| 2 | 无音乐 + 轻吹 | 火焰立即明显响应 |
| 3 | 正常讲话 | 不轻易熄灭 |
| 4–6 | 音乐 30 / 70 / 100% | Raw 不明显增加（VP 生效） |
| 7–8 | 音乐 70/100% + 普通吹气 | 可靠熄灭 |

另重点：持续吹气中偶发掉分（VP 瞬时压制）→ 仍能正常熄灭（Peak Hold + 证据容忍）。

若音乐音量增大而 Raw 显著上升 → 先查 `Voice Processing: On`、输入输出同一 engine。

## 3. 定参规则

1. **Wind Start/Full**（默认 0.012 / 0.055，带通后 RMS 量纲）：轻吹响应不足 → 调低 Start；
   讲话/底噪误触发 → 调高。
2. **Energy/Ratio Wt**（0.90 / 0.10）：**Wind Energy 主特征、Ratio 仅轻量辅助**——
   不要让 Ratio 阻碍真实吹气。
3. **Peak Hold**（默认 0.15s）：真机仍有明显“高→低→高→低”掉分 → 略增大。
4. **Start/Maintain/Duration/Decay**（0.28 / 0.10 / 0.28 / 0.40）：真机调。
5. **已知边界**：浊音讲话/低音音乐低频主导，合成下 raw 偏高——依赖 VP 消音乐 + 真机调参；
   高频噪声 raw≈0.11 高于 maintain，持续大声高频声可能慢积累，必要时调高 maintain。

## 4. 固化步骤

1. 按 §2 验完，用 **Copy Values** 拿 11 键写回 `BlowDetectionConfiguration.swift`。
2. 连测 3 轮。Release 自动不含 Inspector。
3. 第二阶段仅在“VP 带通仍分不清”时上 Template Matching（见 §6），当前不加。

## 5. 验收

- [ ] 音乐 100% 持续 30s → 不熄灭（VP 生效）。
- [ ] 正常讲话 → 不轻易熄灭。
- [ ] 普通吹气 → 0.3–0.8s 稳定熄灭。
- [ ] 轻吹 → 火焰立即明显响应。
- [ ] 持续吹气中偶发掉分 → 仍能正常熄灭。

## 6. 第二阶段（仅在需要时）

```text
Normalized FFT → Blow Reference Spectrum → Cosine Similarity
rawScore = windEnergy×0.60 + windRatio×0.20 + templateSimilarity×0.20
```
不直接上 MFCC / ML。
