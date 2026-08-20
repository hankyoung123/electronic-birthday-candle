# 真机吹气校准手册（宽带中低频模型）

> 目标：用 Debug Panel 的实时数据，把 `BlowDetectionConfiguration.standard` 的最终参数在
> 真机上定下来。本手册只针对真机（Debug 构建），Release 不包含可调入口。

## 0. 当前检测模型（本轮）

```text
Wind Energy ≈ Low(80–300) × 0.45
            + Mid(300–800) × 0.35
            + Up(800–2k)   × 0.15
            + High(2k–5k)  × 0.05      # 高频只作辅助

Blow Score = Energy Score × 0.7       # 响度归一化（RMS）
           + Broadband Score × 0.3    # 80–2000 Hz 是否“整片抬升”

Broadband Score = 80–2000 Hz 内功率 ≥ 峰值×25% 的 bin 占比
                  映射到 0.35–0.70 区间归一化（纯音≈0，噪声≈1）
```

**关键点**：不再用 `energy × texture` 硬乘法门槛。吹气同时抬升“响度 + 宽带”，
讲话只抬响度（谐波/尖峰多，宽带低）→ 加法模型下讲话自然落在阈值下方。

默认判定参数（宽松初始值，需真机验证/微调）：

```text
Start=0.45  Maintain=0.25  Duration=0.40s  Decay=0.40
```

## 1. Debug Panel 怎么看

| 指标 | 含义 | 校准用途 |
| --- | --- | --- |
| Input Route | 当前麦克风（应显示 iPhone 前置内置麦克风） | 确认走前置麦克风 |
| Sample Rate | 输入采样率（44100 / 48000 Hz） | 确认归一化正常 |
| RMS / dBFS | 能量绝对值（dBFS = 20·log10(RMS)） | 响度分界 |
| Low / Mid / Up / High | 四频段平均功率，按最强段归一化 | 吹气能量落在哪 |
| Wind Energy | 加权频段能量（见上） | 吹气强度观测 |
| Energy Score | RMS 归一化响度 0–1 | 加法模型第 1 项 |
| Broadband | 80–2000 Hz“整片抬升”程度 0–1 | 加法模型第 2 项，区分吹气/讲话 |
| Final / Flame | 平滑后的最终 Blow Score（驱动火焰） | 与阈值对比 |
| Strong | 已累计吹气时间 / 需要总时长 | 观察累计与衰减 |

**Live Tuning** 滑杆（改完立即生效，无需重编译）：

- **Start**：`strongBlowThreshold` — 首次跨过才开始累计。
- **Maintain**：`strongBlowMaintainThreshold` — 已开始后维持累计的下限。
- **Duration**：`requiredStrongBlowDuration` — 累计满多少秒熄灭。
- **Decay**：`strongBlowDecayRate` — 低于 Maintain 后每秒丢多少进度。
- **Energy Wt** / **Broadband Wt**：加法模型两项权重。

**Copy Values** 复制当前 6 个调参值；**Copy Snapshot** 复制当前一帧；
**Copy 3s Avg** 复制最近 3 秒平均值 + 峰值。

## 2. 测试矩阵（每项录 Copy Snapshot + 3s Avg）

| 场景 | 期望 | 关键观察 |
| --- | --- | --- |
| 安静 3s | Final < 0.2 | 底噪、Broadband 是否误高 |
| 正常讲话 3s | Final < Start，Strong 不涨 | 讲话峰值、Broadband |
| 大声讲话 / 喊 3s | Final 尽量 < Start（允许短暂触碰） | 大声时 Broadband 是否仍低 |
| 拍手 3 次 | 不误触发 | 拍手瞬间 Energy/Broadband |
| 生日音乐 3s（音量 40–70%） | 不自行触发 | 音乐 Energy/Broadband |
| 轻吹 3s（8–15cm） | Final 明显上升、火焰有反馈 | 轻吹稳态 Final、Broadband |
| 正常持续吹 0.5–1s | 稳定熄灭 | 吹气谷值（要高于 Maintain） |
| 强吹 | 更早熄灭，不卡住 | 峰值 Final、累计速度 |
| 音乐 + 吹气 | 仍能熄灭 | 抗干扰余量 |

## 3. 定参规则（对照数据，不是猜）

1. **Start**：取“讲话/音乐/拍手”场景 Final 的最高峰值，加 0.08–0.12 余量。
   - 例：讲话峰值 0.34、音乐峰值 0.30 → `start ≈ 0.45`。
2. **Maintain**：取“正常持续吹”过程中 Final 的最低谷值，减 0.05 余量，
   但仍要高于“大声讲话”的稳态 Final。
   - 例：吹气谷值 0.38、大声讲话稳态 0.16 → `maintain ≈ 0.25–0.30`。
3. **Duration**：0.35–0.5s。轻吹有反馈、正常吹 0.5–1s 稳定熄灭即可。
4. **Decay**：初始 0.4。若“吹一下停再吹”熄不了，降 0.3。
5. **Energy Wt / Broadband Wt**（默认 0.7 / 0.3）：
   - 若讲话/音乐仍误触发：降 `energyScoreWeight`、升 `broadbandScoreWeight`
     （如 0.6/0.4），让“宽带”成为硬条件。
   - 若轻吹 Final 太低（< 0.35）：升 `energyScoreWeight`（如 0.75）。
6. **RMS 标定**：若所有场景 Energy Score 都居高（讲话就到 1），把
   `fullScaleRMS` 从默认 0.12 调高（0.15–0.2），给讲话留余量；反之轻吹 Energy 太低就调低。

## 4. 固化步骤（最终）

1. 用 **Copy Values** 拿到：

   ```text
   start=0.45
   maintain=0.25
   duration=0.40
   decay=0.40
   energyWt=0.70
   broadbandWt=0.30
   ```

2. 把 `start/maintain/duration/decay/energyWt/broadbandWt`（以及 RMS 标定、
   若需要可同时调 `fullScaleRMS`）写回
   `BirthdayCandle/Audio/BlowDetectionConfiguration.swift` 的默认值。
3. 连测 3 轮验收矩阵。
4. Release 构建自动不含 Inspector 与可调入口（全部 `#if DEBUG`）。

## 5. 验收标准

- [ ] 轻吹：Final 明显上升、火焰明显摆动（8–15cm 即可，不必对准麦克风）。
- [ ] 正常持续吹 0.4–1s：稳定熄灭，3 轮一致。
- [ ] 正常讲话：不轻易熄灭（Strong 基本不涨）。
- [ ] 生日音乐：不自行触发。
- [ ] 调试参数实时可改、Copy Values / Copy Snapshot / Copy 3s Avg 可粘贴。

## 6. 真机数据回填对比

把每场景 **Copy 3s Avg** 粘到这里便于对比（一次一轮）：

| 场景 | dBFS | Low E | Mid E | Up E | High E | Energy | Broadband | Final |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 安静 | | | | | | | | |
| 正常讲话 | | | | | | | | |
| 大声讲话 | | | | | | | | |
| 拍手 | | | | | | | | |
| 轻吹 | | | | | | | | |
| 正常持续吹 | | | | | | | | |
| 强吹 | | | | | | | | |
| 生日音乐 | | | | | | | | |
| 音乐 + 吹气 | | | | | | | | |

> 判定要点：**吹气的 Broadband 要显著高于讲话/音乐**；能量权重决定了“多响才算吹”。
> 数据收齐后据此微调，而不是继续猜。
