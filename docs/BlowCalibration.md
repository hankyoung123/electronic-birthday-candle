# P1 真机验证手册（Apple Sound Analysis）

## 当前生产链路

```text
AVAudioSession（playAndRecord + speaker）
→ AVAudioEngine Voice Processing / AEC
→ 唯一一个 input tap
   ├─ BlowDetector：80–500 Hz 带通 RMS → 火焰动画强度
   └─ SoundClassifier：Apple 内置声音分类 → 吹气置信度 → 熄灭
```

`SoundClassifier` 使用 `SNClassifySoundRequest(classifierIdentifier: .version1)`，
分析窗口为 0.5 秒、重叠率为 0.8。吹气置信度公式固定为：

```text
airflow = max(wind_noise_microphone, breathing × 0.7)
blowConfidence = clamp(airflow × (1 − speech), 0...1)
```

音乐置信度仅显示，不参与扣分。`BlowDetector` 不判断声音语义，也不能触发熄灭。

## 熄灭策略

生产参数只有三个：

| 参数 | 默认值 | 含义 |
| --- | ---: | --- |
| Confidence Threshold | 0.55 | 高于该值时累计证据 |
| Required Duration | 0.25 s | 累计达到该时长后熄灭 |
| Decay Rate | 1.5× | 低于阈值时证据衰减速度 |

这些值在 Debug Inspector 中只读显示。避免一边采样一边随意调参；先完成固定场景矩阵，
再基于误触发和漏触发数据决定是否修改默认值。

## 固定真机场景矩阵

每个场景至少重复 3 次，记录 Inspector 的 Top 5、四个目标置信度、吹气置信度和结果。

| # | 场景 | 期望 |
| --- | --- | --- |
| 1 | 安静环境，普通吹气 | 稳定熄灭 |
| 2 | 安静环境，轻吹 | 火焰立即响应；分类达到阈值时熄灭 |
| 3 | 安静环境，正常讲话 | 不熄灭 |
| 4 | 安静环境，持续元音 | 不熄灭 |
| 5 | 安静环境，拍手/敲击 | 不熄灭 |
| 6 | 生日音乐 30%，不吹气 | 不熄灭 |
| 7 | 生日音乐 70%，不吹气 | 不熄灭 |
| 8 | 生日音乐 100%，不吹气 | 不熄灭 |
| 9 | 生日音乐 70%，普通吹气 | 稳定熄灭 |
| 10 | 生日音乐 100%，普通吹气 | 稳定熄灭 |

## 验收记录

- [ ] Debug 真机显示 Voice Processing 为 On，且没有 classifier error。
- [ ] 只有吹气分类置信度能改变 Evidence；Visual Intensity 单独变化不会熄灭。
- [ ] 讲话场景的 speech 抑制能让吹气置信度保持低于 0.55。
- [ ] 音乐本身不会累计 Evidence，伴随音乐的吹气仍可识别。
- [ ] Debug / Release 的模拟器与真机构建均通过。

P1 是根据用户明确指示在完成完整真机数据矩阵前启用的。因此代码和自动化测试通过后，
Apple 内置分类模型在目标设备与实际环境中的准确率仍必须用上述矩阵验证；单元测试只验证
置信度组合公式与时间状态机，不声称验证 Apple 模型准确率。
