# 真机吹气校准手册（自适应基线 · 频谱增量）

> 目标：用 Debug Panel 的实时数据，把 `BlowDetectionConfiguration.standard` 的最终参数在
> 真机上定下来。本手册只针对真机（Debug 构建），Release 不包含可调入口。

## 0. 当前检测模型（Adaptive Blow Detection）

核心：**检测的是“比环境高了多少 dB”的频谱变化，而不是绝对响度。**

```text
Spectrum (Low/Mid/Upper/High + Broadband)
  → Adaptive Baseline（环境频谱，慢 EMA，疑似吹气时冻结）
  → Delta Features（dB 增量）
  → Spectral Delta Score
  → rawScore → smoothed → CeremonySession 时间确认后熄灭
```

```text
deltaDB(band) = 10 * log10((currentPower + ε) / (baselinePower + ε))

lowScore   = normalize(lowDeltaDB,   1.5, 8.0)
midScore   = normalize(midDeltaDB,   1.5, 8.0)
upperScore = normalize(upperDeltaDB, 1.0, 7.0)

spectralDeltaScore = lowScore ×0.40 + midScore×0.35 + upperScore×0.15
rawScore = spectralDeltaScore × 0.85 + broadbandScore × 0.15
```

- **High 段（2000–5000 Hz）只显示不参与评分**；无硬乘法门槛；无固定峰值频率；
  不再以绝对 RMS 作为主要判定（RMS/dBFS 仅 Debug）。
- Baseline：第一帧以当前环境建立（点蜡烛时环境已在），前 0.6s 快速 EMA（α=0.25），
  此后慢 EMA（α=0.02）；**当 smoothed > 0.20（疑似吹气）时基线冻结**，
  持续吹气不会被吸进环境基线。

熄灭判定（`CeremonySession` 不变）：

```text
Start=0.40  Maintain=0.20  Duration=0.40s  Decay=0.40
```

## 1. Debug Panel

| 指标 | 含义 |
| --- | --- |
| Input Route / Sample Rate | 前置麦克风 / 采样率 |
| Current dBFS / Baseline dBFS | 当前响度 / 环境响度 |
| Total ΔdB | 总带功率相对环境的增量 |
| Low/Mid/Up/High | 频段占比 % + 各自 ΔdB |
| Broadband Act | 80–2000 Hz 活跃 bin 占比 |
| Broadband / Broadband Δ | 宽带形状分 / 相对环境的形状增量 |
| Spectral Δ Score / Raw / Smoothed | 三级打分 |
| Strong Duration | 已累计 / 所需时长 |

**Live Tuning**（实时生效）：

- `Baseline α`：基线慢 EMA 系数（默认 0.02）
- `Low/Mid/Up Δ Start / Full`：各段 dB 归一化上下限（默认 1.5/8.0, 1.5/8.0, 1.0/7.0）
- `Low/Mid/Up Wt`：谱段权重（默认 0.40/0.35/0.15）
- `Broadband Wt`：宽带确认权重（默认 0.15；剩余权重归 spectral）
- `Start / Maintain / Duration / Decay`：熄灭判定

**Copy Values** 复制 15 个调参键；**Copy Snapshot** 一帧；**Copy 3s Avg** 3 秒均值+峰值。

## 2. 已用合成信号锁定的行为（回归测试）

| 场景 | 结果 |
| --- | --- |
| 稳定音乐 60 帧 | baseline 吸收 → 0.00 ✓ |
| 稳定白噪声 60 帧 | 吸收 → ~0.09 ✓（旧绝对模型会误触发） |
| 稳定谐波人声 60 帧 | 吸收 → 0.00 ✓ |
| 安静后吹气 | Δ 高 → 0.59 触发 ✓ |
| 音乐上吹气 | Δ 高 → 0.56 触发 ✓（旧模型此处失效） |
| 持续吹 60 帧 | 冻结 → 不被吸收 0.80 ✓ |
| 音量微调 (+2.5dB) | 瞬态后回落，不误触发 ✓ |
| 环境小幅变化 | baseline 重新收敛 ✓ |

## 3. 真机定参规则（对照数据）

1. **Δ Start / Full**：决定“多响的变化算吹气”。
   - 真机轻吹 ΔdB（各段）偏低 → 调低 start 或调高灵敏度。
   - 讲话/音乐峰值 ΔdB 误触发 → 调高 start（如 low 2.5、mid 2.5、up 2.0）。
2. **Low/Mid/Up Wt**：真吹气若偏低频 → 升 lowWt；偏中频 → 升 midWt。
3. **Broadband Wt**：误触发多 → 升（宽带成为更强确认）；真吹不识别 → 降。
4. **Baseline α**：环境变化快/背景音乐呼吸感强 → 适当调高（更快跟环境）；
   稳定房间 → 保持 0.02。**数值高会让慢速吹气被部分吸收**，注意权衡。
5. **Start/Maintain/Duration/Decay**：保持默认，按真机误触发情况微调。

## 4. 已知边界（真机重点验证）

- **大幅环境台阶**（例如点蜡烛后突然放很大声的背景音乐，或手动把音量 +6dB 以上）
  会被当作“疑似吹气”而冻结 baseline，首个 0.4s 若 Δ 足够大会触发。
  **规避**：应用流程是"检测开始前音乐已就绪、检测后只做淡入淡出"，已避开此场景；
  若真机遇到，用 `Baseline α`/`Start` 上调规避，或用 `Broadband Wt` 强化宽带确认。
- 单一很响的谐波峰值可压低 Broadband（最大相对参考），但 Δ 评分仍能工作。

## 5. 真机验收（§12）

- [ ] 持续播放音乐 10s：不熄灭。
- [ ] 正常讲话：不轻易熄灭。
- [ ] 正常吹气：火焰立即响应。
- [ ] 持续吹 0.4–1s：稳定熄灭，3 轮一致。
- [ ] 音乐 + 吹气：可可靠熄灭。
- [ ] 停止吹气后：基线恢复更新（Debug 看 Baseline dBFS / Total ΔdB 回到环境水平）。

## 6. 固化步骤

1. 用 **Copy Values** 拿到 15 键，把非默认值写回
   `BirthdayCandle/Audio/BlowDetectionConfiguration.swift` 对应私有默认值。
2. 连测 3 轮。Release 自动不含 Inspector 与可调入口。
