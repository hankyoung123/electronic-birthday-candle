# 真机验证手册（Airflow Candidate + Delayed Speech Veto）

## 生产路径

```text
Voice Processing / AEC
↓
唯一 Mic PCM tap
├─ FFT Wind Detector → airflow intensity → flame + candidate
└─ Apple Sound Analysis → timestamped SpeechObservation
                                      ↓
                              delayed speech veto
                                      ↓
                              CeremonySession → extinguish
```

Apple 分类器不再作为吹气的正向条件。`wind_noise_microphone`、`breathing`、`music`
和 Top 5 只用于 Debug 观察；生产判定只读取 `speech`，并保留
`SNClassificationResult.timeRange`。

## 产品时序

```text
.lit
Music 0.72
火焰响应声音
Extinguish OFF

↓ 1.7s

.wishing
Music fade → 0.15（300ms）
Extinguish 仍 OFF

↓ fade 完成

Airflow Candidate ON
```

因此音乐最高的 `.lit` 阶段无法累计 candidate。Voice Processing 继续保留，但降低扬声器
音量是进入吹气阶段时减少 `Speaker → Air → Mic` 干扰的第一道措施。

## Candidate 状态机

```text
idle

↓ airflow intensity >= 0.35

accumulating
连续累计 0.35s
低于 0.35 → 立即回到 idle

↓ evidence 达标（不会立即熄灭）

awaitingSpeechCheck

↓ 收到 timeRange 覆盖 candidate 开始到达标区间的新 Apple result

speech >= 0.80 → reject → idle
speech <  0.80 → extinguish
```

Candidate 的开始和达标时间使用 Sound Analysis PCM 流的 `CMTime`；SpeechObservation 使用
同一流的 `CMTimeRange`。不能用系统 uptime 与 `timeRange` 直接比较。旧结果或只覆盖候选后半段
的结果没有确认权。

## 真机验收

| # | 场景 | 目标 |
| --- | --- | --- |
| 1 | `.lit` 音乐 72%，不吹气 | 不熄灭，candidate 不建立 |
| 2 | `.lit` 持续吹气 | 火焰响应，但不熄灭 |
| 3 | 进入 `.wishing` | 音乐约 300ms 降至 15%，之后才开放检测 |
| 4 | `.wishing` 普通吹气 ×10 | ≥9/10 熄灭，感知延迟约 0.5–0.7s |
| 5 | `.wishing` 正常讲话 30s | 不熄灭，覆盖结果的 speech 通常 ≥0.80 |
| 6 | `.wishing` 大声讲话/持续“啊—” | candidate 被 Speech Veto 拒绝 |
| 7 | `.wishing` 音乐单独播放 30s | 不熄灭 |
| 8 | `.wishing` 音乐 + 普通吹气 | 仍可可靠熄灭 |

Debug 时重点记录：airflow intensity、candidate/awaiting 状态、Speech confidence、Apple
结果的 start/end time，以及从吹气开始到熄灭的总延迟。不要继续调整 Wind Start、Wind Ratio、
Energy Weight，也不要增加新的声学特征；若有问题，先判断是 airflow candidate 未成立，还是
SpeechObservation 的覆盖时序/阈值导致拒绝。
