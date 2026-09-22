# AuK 调研记录

> 调研日期：2026-09-22。腾讯混元 2026-09-09 开源的语音基础模型，作为 Qwen3-TTS 的潜在替代方案跟踪。

## 模型概况

- **名称**：AuK（腾讯混元，联合上海交大、南洋理工）
- **参数量**：1.5B，MIT 许可证
- **架构**：flow-matching 扩散 transformer（Qwen2.5-Omni-3B 语义编码器 + 音频 VAE，24kHz → 50Hz latent + MMDiT/DiT），与自回归 TTS 路线不同
- **能力**：一个模型、自然语言指令覆盖 16 种任务 —— 零样本/指令 TTS、语音内容编辑、降噪、人声分离、情感/音色编辑等；训练数据约 195 万小时
- **AuK-Flash**：蒸馏版，4 步采样，约 4.5× 加速
- 权重：HF / ModelScope，base 与 Flash 均为 6.1GB

## 与 Qwen3-TTS 对比（官方技术报告口径）

Seed-TTS-Eval（test-en/test-zh/test-zh-hard 平均）：

| 模型 | WER ↓ | 说话人相似度 ↑ |
|---|---|---|
| **AuK** | **2.65** | **0.795** |
| AuK-Flash | 2.85 | 0.790 |
| Qwen3-TTS | 3.07 | 0.745 |
| Seed-TTS | 3.65 | 0.778 |

注意：

- 双方报告各用各的评测设置，Qwen3-TTS 自家报告中数字也很好，第三方独立实测尚少
- AuK 真正强项是编辑类任务，纯 TTS 只是其能力之一
- 结论需以同文本 + 同参考音频的 A/B 听感为准

## Apple Silicon 支持

官方有 `feat/mlx-apple-silicon` 分支（2026-09-13，原生 MLX 后端，Python）：

- M4 Pro 48GB：fp32 峰值 ~24.3GB，**8bit 量化 ~9.1GB**，sequential 模式 ~6.1GB
- 速度（M4 Pro）：base 32 步 RTF 4~6（不可用）；**Flash 4 步 RTF 0.6~1.8**，接近实时
- 全任务支持，但权重需自己从 PyTorch 转换，无预转 MLX 权重
- 坑：4bit 量化中文发音劣化；只兼容 Qwen2.5-Omni-3B（Qwen3-Omni 不行）；无 Gradio/ComfyUI；分支很新

## 接入 iVox 的障碍

- 官方 MLX 支持是 **Python**，而 iVox 用 [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) 直接在 Swift 进程内推理
- 截至 2026-09-22，mlx-audio-swift 无任何 AuK 相关 issue/PR；扩散架构与现有自回归 TTS 封装差异大，短期不会支持
- 短期若试，只能走 Python 独立服务（HTTP）的方式，无法像现在这样嵌入守护进程

## 后续计划

1. HF 上用同一段文本 + 参考音色，A/B 对比 AuK 与 Qwen3-TTS 听感
2. 本地 Python 跑 MLX 分支 Flash + 8bit，验证 Mac 实际音质与 RTF
3. 验证通过再讨论接入形态（独立 HTTP 服务 / 等待 mlx-audio-swift 支持）

## 参考链接

- HF：https://huggingface.co/tencent/AuK
- GitHub：https://github.com/Tencent-Hunyuan/AuK
- MLX 分支：https://github.com/Tencent-Hunyuan/AuK/tree/feat/mlx-apple-silicon
- 技术报告：https://www.alphaxiv.org/abs/2609.08936
