# 真机校准手册（Echo-Cancelled 输入 + 带通风噪 + 时间证据）

> 目标：真机确认 AEC 消掉自家音乐，并校准 80–500 Hz 带通风噪 + 证据累计的最终参数。
> 本手册只针对真机（Debug 构建），Release 不包含可调入口。
> ⚠️ 要求 iOS 18.2+（本工程部署目标已从 17.0 提升到 18.2，以使用
> `setPrefersEchoCancelledInput`——计划指定的唯一 AEC 路径）。

## 0. 当前检测链路（唯一生产路径）

```text
Music → Speaker
          │
          ▼
iOS Echo-Cancelled Input（AEC，AVAudioSession setPrefersEchoCancelledInput）
          │
Mic ──────┘
          ↓
Clean Mic PCM
          ↓
80–500 Hz 带通（6 阶，时间域）→ windBandRMS → Wind Energy Score
FFT windRatio（80–500 / 80–5000）→ Wind Ratio Score
          ↓
rawScore = WindEnergy×0.85 + Ratio×0.15
          ↓
BlowDetector → 连续 0…1 intensity（驱动火焰，实时）
          ↓
CeremonySession Evidence Accumulator → 达标后 extinguish()
```

- **AEC**：`configureSession()` 统一设置
  `.playAndRecord + .default + .defaultToSpeaker` + `setPrefersEchoCancelledInput(true)`；
  失败/未生效 → 启动失败（不 fallback）。首次启动、中断恢复、Route Change 全走同一配置路径。
  面板显示 `Echo Cancelled: On/Off`（`isEchoCancelledInputEnabled`）。
- **Wind Energy**：时间域 6 阶 Butterworth 带通 80–500 Hz → 直接 RMS；
  **FFT 只负责 Wind Ratio**。
- **无**：Voice Processing、silenceFloor 硬门槛（低能量由 windStart/Full 控制）、
  自适应基线、宽带、delta 特征、硬乘门槛。

### 证据累计（CeremonySession，P1）

```text
intensity ≥ start(0.30)            → evidence += dt
intensity ≥ maintain(0.12)         → evidence += dt × 0.65
否则                               → evidence = max(0, evidence − dt × decay(0.35))
evidence ≥ required(0.30s)         → extinguish()
```

强吹快积累、弱吹慢积累、短暂掉分只轻微衰减、停止吹气明显归零。

## 1. Debug Panel

- `Input Route` / `Sample Rate` / **`Echo Cancelled: On/Off`**
- `RMS / dBFS`
- `Wind RMS` / `Wind Ratio`
- `Wind Energy Score` / `Wind Ratio Score` / `Raw Score` / `Smoothed`
- `Evidence` / `Required Evidence`
- **Live Tuning**：`Wind Start / Full`、`Wind Ratio Start / Full`、`Energy Wt / Ratio Wt`、`Start / Maintain / Duration / Decay`、`Music Volume`
- **Copy Values** 10 键；**Copy Snapshot / Copy 3s Avg**

## 2. 真机验证（按计划三轮回）

**第一轮：只验证 P0（AEC + 带通）**
逐项记录 `Wind RMS / Wind Ratio / Raw / Smoothed`：

| 场景 | 期望 |
| --- | --- |
| 安静 | Wind RMS≈0，Raw≈0 |
| 讲话 | Raw 低，不触发 |
| 音乐 30/70/100% | **Raw 不明显增加**（AEC 生效）|
| 正常吹气 / 轻吹 | **Wind RMS 明显上升**；轻吹 Raw>0.15（火焰明显响应）|

若音乐音量增大而 Raw 显著上升 → AEC 未生效，先查 `Echo Cancelled: On` / 输出输入同一 engine。

**第二轮：P1（Evidence）**
- 普通力度吹气 → 0.3–0.8s 熄灭。
- 吹气中偶发掉分 → 不影响熄灭（0.65 慢积累 + 衰减容忍）。
- 停止吹气 → evidence 自动消退、不熄灭。

**第三轮**：仍出现明显的“高→低→高→低”掉分，才加 Peak Hold（120–150ms）。当前未实现。

## 3. 定参规则

1. **Wind Start/Full**（默认 0.015 / 0.065，带通后 RMS 量纲）：轻吹响应不足 → 再调低 Start；
   讲话/底噪误触发 → 调高 Start/Full。
2. **Wind Ratio Start/Full**（0.35 / 0.65）：滤纯音/白噪/拍手等高频声。
3. **Energy/Ratio Wt**（0.85 / 0.15）：保持能量主导；高频误触发多 → 微调高 Ratio Wt。
4. **Start/Maintain/Duration/Decay**（0.30 / 0.12 / 0.30 / 0.35）：真机调。
5. **已知边界**：浊音讲话/低音音乐本身是低频主导，合成信号下 raw 会偏高（音乐≈0.5、
   讲话≈0.39）——这正是依赖 AEC 消音乐 + 真机调参的原因；第二阶段仅在“AEC+带通仍分不清”时
   上 Template Matching（见 §6）。

## 4. 固化步骤

1. 三轮回完，用 **Copy Values** 拿 10 键写回 `BlowDetectionConfiguration.swift`。
2. 连测 3 轮。
3. Release 自动不含 Inspector。

## 5. 验收

- [ ] 音乐 100% 持续 30s → 不熄灭（AEC 生效）。
- [ ] 讲话 → 不轻易熄灭。
- [ ] 普通吹气 → <0.8s 稳定熄灭。
- [ ] 轻吹 → 火焰明显响应。
- [ ] 音乐 + 普通吹气 → 稳定熄灭。
- [ ] 连续吹气中短暂检测掉分 → 不丢失整个过程（evidence 不归零）。

## 6. 第二阶段（仅在真机数据需要时）

```text
Normalized FFT → Blow Reference Spectrum → Cosine Similarity
rawScore = windEnergy×0.60 + windRatio×0.20 + templateSimilarity×0.20
```
不直接上 MFCC / ML。
