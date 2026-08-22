# 真机校准手册（原版 Wind Detector + Apple 强讲话否决）

> 目标：回到**已证明能工作**的 80–500 Hz 风噪检测（0f4104e 思路），Apple Sound Analysis
> 只做“强讲话否决”（不参与证明吹气）。真机 Debug 构建用，Release 无可调入口。

## 0. 当前路径（唯一生产路径）

```text
Voice Processing / AEC
↓
Mic PCM
↓
原版 Wind Detector（FFT）
├─ 80–500 Hz Wind Energy（windBandRMS, Parseval 归一）
└─ 80–500 / 80–5000 Wind Ratio（软形状约束）
↓
Blow Intensity（0…1，同时驱动火焰 + 吹气候选）
↓
CeremonySession
├─ 原版 Start / Maintain / Duration 状态机
└─ Strong Speech Veto（Apple 只否决）
↓
Extinguish
```

```
windEnergyScore = normalize(windBandRMS,  0.03, 0.14)
windRatioScore  = normalize(windRatio,     0.35, 0.65)
rawScore = windEnergyScore × 0.75 + windRatioScore × 0.25   # 全加法
attack 0.28 / release 0.10
```

- **无 silenceFloor 硬门槛**：低能量自然经 `windStart` 归零——避免 Voice Processing
  瞬时压低 RMS 时整帧失效。
- **无** Peak Hold / Direct 带通取代 FFT / Adaptive Baseline / Delta / Broadband /
  多频段评分。
- **Apple 只读 speechConfidence**；`wind_noise_microphone / breathing / music /
  Top 5` 仅 Debug 展示，不入判定、不作为吹气证据。

### 熄灭状态机（CeremonySession）

```text
Start 0.35 / Maintain 0.18 / Required 0.35s / Decay 0.40

if evidence > 0:
    intensity >= maintain → evidence += dt
    else                 → evidence = max(0, evidence − dt×decay)
else if intensity >= start:
    evidence += dt          # 必须先跨过 Start 才建立候选（Maintain 不能从 0 起算）
```

### Strong Speech Veto（P1）

```text
candidate 未建立: speech >= 0.80 → 本帧禁止累计，evidence 快速衰减（−2.0×dt）
candidate 已建立: speech >= 0.90 → 同样否决
否则完全不干预（Apple 不削弱真实吹气）
```

## 1. Debug Panel

- `Voice Processing On/Off`、`Mic Permission`、`Session Active`、`Start Failure`（DEBUG）
- `Input Route`、`Sample Rate`
- `RMS / dBFS`、`Wind Band RMS`、`Wind Ratio`
- `Wind Energy Score`、`Wind Ratio Score`、`Raw Blow Score`、`Smoothed Blow`
- `Blow Candidate Active`、`Speech Confidence`、`Top 5`、`Classifier Error`
- `Evidence / Start / Maintain / Required / Decay`、`Music Volume`
- **Live Tuning**：Wind Start/Full、Ratio Start/Full、Energy/Ratio Wt、Start/Maintain/Duration/Decay、Music

**重点观察**：
- 正常吹气：Blow Intensity 稳定跨过 0.35，Speech 通常低于 veto。
- 讲话：即使 Blow Intensity 越过 0.35，Speech 稳定升高触发 veto，不累计。

## 2. 真机验收

| # | 场景 | 目标 |
| --- | --- | --- |
| 1 | 无音乐普通吹气 ×10 | ≥9/10 熄灭，0.4–0.8s |
| 2 | 轻吹 ×10 | 立即明显火焰反馈 |
| 3 | 正常讲话 30s | 不熄灭 |
| 4 | 大声讲话 | 不熄灭 |
| 5 | 持续“啊—” | 不熄灭（speech veto）|
| 6 | 音乐 34% + 吹气 | 可靠熄灭 |
| 7 | 音乐 72% + 吹气 | 可靠熄灭 |
| 8 | 音乐 72% 单独 30s | 不触发 |

## 3. 定参规则

1. Wind Start/Full（0.03/0.14）：轻吹响应不足 → 调低 Start；讲话/底噪误触发 → 调高。
2. Ratio Start/Full（0.35/0.65）：滤纯音/白噪/拍手；**别让 Ratio 阻碍真实吹气**（权重 0.75/0.25）。
3. Start/Maintain/Required/Decay（0.35/0.18/0.35/0.40）：真机误触/漏检调。
4. Speech Veto（0.80/0.90）：若真实吹气被 Apple 误判 speech → 把已建立候选的 0.90 再调高或去掉二段统一 0.85+。
5. 已知边界：浊音/低音音乐低频主导 → 依赖 VP 消音乐 + veto 防讲话；音乐音量随 Raw 显著上升 → 先查 VP。

## 4. 固化

1. 验完用 **Copy Values**（10 键）写回 `BlowDetectionConfiguration.swift`。
2. 连测 3 轮。Release 自动不含 Inspector。

## 5. 后续（仅在需要时）

仍分不清吹气/音乐时再考虑：`Normalized FFT → Blow Reference → Cosine Similarity`
（`rawScore = wind×0.60 + ratio×0.20 + template×0.20`）。不上 MFCC / ML。
