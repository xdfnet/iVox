# iVox 文档索引

## 核心文档

| 文档 | 内容 |
|---|---|
| [architecture.md](architecture.md) | 整体架构：actor 模型、守护进程生命周期、构建系统 |
| [hook-chain.md](hook-chain.md) | 从 AI 助手回复到出声的完整 Hook 链路（含踩坑清单） |
| [socket-api.md](socket-api.md) | Unix Socket IPC 协议：TTS 播报与 ASR 识别 |
| [dsh-tts.md](dsh-tts.md) | DeepSeek Harness 语音播报接入方案 |
| [playback-queue.md](playback-queue.md) | PlaybackQueue 状态机与媒体控制场景矩阵 |
| [CHANGELOG.md](CHANGELOG.md) | 开发日志与版本变更 |

## archive/ — 历史复盘与调研

问题已修复或为一次性记录，保留供追溯，不再持续更新。
命名规范：`incident-` 事故复盘、`guide-` 手册流程、`research-` 调研、`review-` 评估快照。

| 文档 | 内容 |
|---|---|
| [incident-swift-compiler-crash.md](archive/incident-swift-compiler-crash.md) | Swift 6.4 快照编译器崩溃（2026-06-15 快照已修复） |
| [incident-audio-drain-callback.md](archive/incident-audio-drain-callback.md) | AudioPlayer drain 回调丢失修复记录（2026-08） |
| [incident-hook-tts-leak.md](archive/incident-hook-tts-leak.md) | 后台进程文本泄漏进播报的排查记录（2026-08） |
| [guide-install-network.md](archive/guide-install-network.md) | 安装期网络问题与兜底方案（HTTP/2 截断、模型下载 fallback） |
| [guide-release-flow.md](archive/guide-release-flow.md) | 早期发布流程（最新流程见根目录 [CLAUDE.md](../CLAUDE.md)） |
| [research-auk.md](archive/research-auk.md) | 腾讯混元 AuK 语音模型调研（2026-09-22） |
| [review-stability-2026-07.md](archive/review-stability-2026-07.md) | 架构稳定性评估快照（2026-07-01） |
