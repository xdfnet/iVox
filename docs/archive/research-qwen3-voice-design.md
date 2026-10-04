# 调研：Qwen3-TTS VoiceDesign 在 MLX 上的失败尝试

**日期**：2026-10-05
**结论**：放弃 VoiceDesign，维持 Base 模型 + 参考音频的克隆方案。

## 起因

看到 [Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS) 支持 VoiceDesign（自然语言描述任意捏音色），且官方博客的"拟人感"示例（`自然感的女声，语调活泼带笑意，模仿别人‘嘘’你时压低嗓音，就是平时聊天的感觉`）非常惊艳，想替换现有克隆音色。

## 尝试过程

1. **加 instruct 双模式**：`VoiceInfo` 新增可选 `instruct`，有则走 VoiceDesign、无则走克隆。
2. **逐版捏描述**：从"沉稳主持人"→"清爽少年"→官方七维度公式（年龄/音调/音色/语速/语气/用途），始终"不像"。
3. **8bit → bf16**：怀疑量化损伤表现力，换 mlx-community bf16 原版（3.57GB），无明显改善。
4. **流式 → 非流式**：加 `tts.streaming` 开关做整段合成对比。核实流式/非流式底层是同一个 `generateVoiceDesign` 采样循环，音色理论一致，实际也无差别。

## 排查结论

逐层比对，本地与官方**无实质差异**：

| 排查项 | 结论 |
|---|---|
| instruct 写法 | 与官方七维度公式一致 |
| prompt 拼接 | 逐字相同（`<\|im_start\|>user\n{instruct}<\|im_end\|>\n`） |
| 采样参数 | temperature 0.9 / top_p 1.0 / repetition_penalty 1.05 一致 |
| 权重 / config | bf16 版文件与官方一一对应 |
| 流式 | 不影响音色 |

**唯一剩下的差异是推理后端**：官方示例在 CUDA + PyTorch bf16 上生成，iVox 依赖第三方移植的 mlx-audio-swift。其模型实现在 Apple Silicon 上复现不出官方的拟人感，属移植层差距，非配置可解决。

此外，VoiceDesign 每次生成带随机采样（temperature 0.9），同一描述音色会飘；官方示例大概率是多条人工挑选的最佳结果，单次本地生成本就难以复现。

## 取舍

- **还原**：代码回退全部实验改动（instruct 字段、合成前热重载、非流式开关），运行时配置切回 `Qwen3-TTS-12Hz-1.7B-Base-8bit` 克隆方案，实验模型已删除。
- **后续**：若仍想要官方拟人感，需等 mlx-audio-swift 上游改进，或有 NVIDIA GPU 时用官方 `qwen-tts` 验证，不再在配置层反复尝试。
