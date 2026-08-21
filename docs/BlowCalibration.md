# 真机吹气校准手册（宽带中低频 · 最小模型）

> 目标：用 Debug Panel 的实时数据，把 `BlowDetectionConfiguration.standard` 的最终参数在
> 真机上定下来。本手册只针对真机（Debug 构建），Release 不包含可调入口。

## 0. 当前检测模型（本轮）

核心原则：**先把频谱数据做对，再用最简单、偏宽松的频谱模型识别吹气，不堆算法参数。**

```text
Blow Score = Energy Score × 0.65   # 声音够强（RMS 归一化响度）
           + Broadband Score × 0.35 # 80–2000 Hz 是否“整片抬升”（宽带形状）

Broadband Score = 80–2000 Hz 内 power ≥ 带内峰值 × 25% 的 bin 占比
                  映射 0.25→0.70 归一化
```

- 四频段 `Low 80–300 / Mid 300–800 / Up 800–2k / High 2k–5k` 只做**观察**：
  原始 mean power 仅内部使用，UI 与导出显示**占比（Ratio，和 ≈ 1）**。
- 频段不参与最终判定（未硬塞权重，不堆参数）。
- 仍是**加法模型**，绝不用 `energy × texture` 硬乘门槛。

> **权重为何是 0.65 / 0.35（偏离最初建议的 0.40 / 0.60）**：
> 实测发现宽带“形状”指标与响度无关——极轻的白色底噪（≈ -31 dBFS）会拿到与真吹气
> 几乎相同的 Broadband（≈0.9）。若按 0.40/0.60，安静房间的空调/风扇噪声也会把蜡烛吹灭，
> 违反验收。因此能量项必须承担“够不够响”的分量：响度低（quiet 噪声）不触发、
> 嘴巴贴麦的响吹通过、讲话/音乐靠宽带项（≈0）排除。真机数据到位后，
> 用 `Energy Wt / Broadband Wt` 滑杆向纯宽带方向回调即可。

默认判定参数（保持不动）：

```text
Start=0.45  Maintain=0.25  Duration=0.40s  Decay=0.40
```

## 1. Debug Panel 怎么看

| 指标 | 含义 | 校准用途 |
| --- | --- | --- |
| Input Route | 当前麦克风（确认 iPhone 前置内置） | 确认前置麦克风 |
| Sample Rate | 输入采样率（44100 / 48000 Hz） | 归一化正常 |
| RMS / dBFS | 能量绝对值（dBFS = 20·log10(RMS)） | 响度分界 |
| Low / Mid / Up / High | 频段能量占比（%） | 看吹气能量落在哪（观察） |
| Broadband Act | 80–2000 Hz 活跃 bin 占比（%） | Broadband 的原始输入 |
| Broadband Score | 归一化后的宽带分 0–1 | 加法模型第 2 项 |
| Energy Score | RMS 归一化响度 0–1 | 加法模型第 1 项 |
| Raw Score | 两项加权原始分 0–1 | 判断用输入 |
| Smoothed | 平滑后最终分（驱动火焰） | 与阈值对比 |
| Spectral Flatness | 显示用，**不参与判定** | 下一阶段特征对照 |
| Start / Maintain / Required Duration / Strong | 判定阈值 + 已累计时长 | 观察累计与衰减 |

**Live Tuning** 滑杆（实时生效，无需重编译）：

- `Start` / `Maintain` / `Duration` / `Decay`（熄灭判定）
- `Energy Wt` / `Broadband Wt`（加法模型两项权重）
- `BB Relative` / `BB Min Active` / `BB Full Active`（宽带判定三参数）

**Copy Values**：复制 9 个调参值；**Copy Snapshot**：复制一帧；**Copy 3s Avg**：最近 3 秒
平均值 + 峰值（dB 用线性功率平均后转 dB；峰值超过 3 秒自动消失）。

## 2. 测试矩阵（每项录 Copy Snapshot + 3s Avg）

| 场景 | 期望 | 关键观察 |
| --- | --- | --- |
| 安静 3s | Smoothed < 0.2 | 底噪、Broadband Act 是否误高 |
| 正常讲话 3s | Smoothed < Start，Strong 不涨 | 讲话峰值、Broadband |
| 大声讲话 / 喊 3s | Smoothed 尽量 < Start | 大声时 Broadband 是否仍低 |
| 拍手 3 次 | 不误触发 | 拍手瞬间 Energy/Broadband |
| 生日音乐 3s（音量 40–70%） | 不自行触发 | 音乐 Energy/Broadband |
| 轻吹 3s（8–15cm） | Smoothed 明显上升、火焰有反馈 | 轻吹 Smoothed、Broadband |
| 正常持续吹 0.4–1s | 稳定熄灭 | 吹气谷值（要高于 Maintain） |
| 强吹 | 更早熄灭，不卡住 | 峰值、累计速度 |
| 音乐 + 吹气 | 仍能熄灭 | 抗干扰余量（见下方注意） |

> **注意（音乐+吹气）**：当前宽带模型用“带内峰值”做参考，单个很响的谐波峰值
> 可能压低 Broadband（纯音乐本身不会误触发，但“吹着唱/放歌吹”需要真机验证）。
> 真机上嘴贴近麦克风、音乐从扬声器且已压低，通常吹气会主导输入；若不够，
> 用 `BB Relative`（调高）或 `Broadband Wt`（调高）收紧/加强宽带条件。

## 3. 定参规则（对照数据，不是猜）

1. **Start**：取“讲话/音乐/拍手”场景 Smoothed 的最高峰值，加 0.08–0.12 余量。
2. **Maintain**：取“正常持续吹”过程中 Smoothed 最低谷值减 0.05，仍高于“大声讲话”稳态。
3. **Duration**：0.35–0.5s；**Decay**：初始 0.4。
4. **Energy Wt / Broadband Wt**（默认 0.65/0.35）：
   - 讲话/音乐误触发 → 升 `broadbandWt`、降 `energyWt`（宽带成为硬条件）。
   - 轻吹 Smoothed 太低 → 升 `energyWt`。
   - 安静底噪误触发 → **降 `broadbandWt`**（宽带形状对轻白噪天然≈满格）。
5. **BB Relative / Min / Full**（默认 0.25 / 0.25 / 0.70）：
   - 吹气 Broadband 偏低（>2kHz 衰减太明显）→ 降 `relative`（更宽松，但注意会放大轻白噪）。
   - 讲话/音乐 Broadband 误高 → 升 `relative` 或升 `min active`。
6. **RMS 标定**：若讲话 Energy Score 经常到 1 → 升 `fullScaleRMS`（0.15–0.2）；
   若轻吹 Energy Score 太低 → 降 `fullScaleRMS`。

## 4. 固化步骤（最终）

1. 用 **Copy Values** 拿到：

   ```text
   start=0.45
   maintain=0.25
   duration=0.40
   decay=0.40
   energyWt=0.65
   broadbandWt=0.35
   bbRelative=0.25
   bbMinActive=0.25
   bbFullActive=0.70
   ```

2. 写回 `BirthdayCandle/Audio/BlowDetectionConfiguration.swift` 默认值（含 RMS 标定）。
3. 连测 3 轮验收矩阵。
4. Release 构建自动不含 Inspector 与可调入口（全部 `#if DEBUG`）。

## 5. 验收标准

- [ ] 轻吹（8–15cm，不必对准麦克风）：Smoothed 明显上升、火焰明显摆动。
- [ ] 正常持续吹 0.4–1s：稳定熄灭，3 轮一致。
- [ ] 正常讲话：不轻易熄灭（Strong 基本不涨）。
- [ ] 生日音乐：不自行触发。
- [ ] 3s 历史 N≈90 且不随运行时长增长；旧峰值 3 秒后消失。

## 6. 真机数据回填对比

| 场景 | dBFS | Low% | Mid% | Up% | High% | Broadband Act | Broadband | Energy | Final |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 安静 | | | | | | | | | |
| 正常讲话 | | | | | | | | | |
| 大声讲话 | | | | | | | | | |
| 拍手 | | | | | | | | | |
| 轻吹 | | | | | | | | | |
| 正常持续吹 | | | | | | | | | |
| 强吹 | | | | | | | | | |
| 生日音乐 | | | | | | | | | |
| 音乐 + 吹气 | | | | | | | | | |
