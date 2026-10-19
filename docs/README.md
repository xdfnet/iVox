# iVox 文档索引

按「回答什么问题」分三类。**先读这里，再进具体文档。**

| 类别 | 回答 | 更新时机 |
|---|---|---|
| **架构文档** | 系统现在长什么样 | 改动代码就改它 |
| **历史归档** | 曾经踩过什么坑、为什么这么定 | 定案即冻结，不再更新 |
| **版本流水** | 每次发布改了什么 | 每次发版追加 |

## 架构文档（现在是什么样）

| 文档 | 内容 |
|---|---|
| [architecture.md](architecture.md) | 整体架构：actor 模型、守护进程生命周期、各子系统 |
| [hook-chain.md](hook-chain.md) | 从 AI 助手回复到出声的完整 Hook 链路（含踩坑清单） |
| [socket-api.md](socket-api.md) | Unix Socket IPC 协议：TTS 播报、ASR 识别、打断三档 |
| [native-bridge.md](native-bridge.md) | 微信链路「Swift 直连 claude」的实测依据（v3.4.0 已实施） |

### 播报四层 — 按这个顺序读

播报是最复杂的一块，拆成四份。**上面的表看不出层次，层次在这里**：

| 顺序 | 文档 | 回答 |
|---|---|---|
| 1 | [playback/paper.md](playback/paper.md) | **比喻层**（先读这个）：一摞纸 / 一张纸 / 一个字条，播报到底怎么跑起来的。**它不做裁决** |
| 2 | [playback/purpose.md](playback/purpose.md) | **目的层**：播报为什么存在，遇到取舍听谁的 |
| 3 | [playback/sources.md](playback/sources.md) | 接入方层：谁在说话，各拿得出什么身份 |
| 4 | [playback/requirements.md](playback/requirements.md) | 需求层：必须做到什么、场景清单、底线 |
| 5 | [playback/queue.md](playback/queue.md) | 实现层：今天代码怎么写的、改它有什么坑 |

**先读第 1 份建立直觉，冲突的裁决在第 2 份。** 两者分工：paper.md 讲「播报怎么跑起来的」，
purpose.md 讲「取舍时听谁的」——每条原则下面都记着它裁决过什么，只有带裁决记录的原则才算数，
好听的口号一律不作数。

## 版本流水

- [CHANGELOG.md](CHANGELOG.md) — 每个版本改了什么。**只追加**，
  不受下面规则 1（核心文档只写现状）约束：它记录的就是历史本身。

## archive/ — 历史归档

已定案、只供追溯，**不再更新**。命名规范：
`incident-` 事故复盘、`guide-` 手册流程、`research-` 调研、`review-` 评估快照。

| 文档 | 内容 |
|---|---|
| [incident-swift-compiler-crash.md](archive/incident-swift-compiler-crash.md) | Swift 6.4 快照编译器崩溃（2026-06-15 快照已修复） |
| [incident-audio-drain-callback.md](archive/incident-audio-drain-callback.md) | AudioPlayer drain 回调丢失复盘（2026-08） |
| [incident-hook-tts-leak.md](archive/incident-hook-tts-leak.md) | 后台进程文本泄漏进播报的排查记录（2026-08） |
| [incident-playback-queue-fixes.md](archive/incident-playback-queue-fixes.md) | 播报队列历史修复清单（v2.7.0 ~ 2026-08） |
| [guide-install-network.md](archive/guide-install-network.md) | 安装期网络问题与兜底（HTTP/2 截断、模型下载 fallback） |
| [guide-release-flow.md](archive/guide-release-flow.md) | 早期发布流程（现行流程见根目录 [CLAUDE.md](../CLAUDE.md)） |
| [research-qwen3-clone-issues.md](archive/research-qwen3-clone-issues.md) | Base 模型声音克隆的已知坑与社区经验（2026-10-05） |
| [research-qwen3-voice-design.md](archive/research-qwen3-voice-design.md) | VoiceDesign 在 MLX 上的失败尝试（结论：维持 Base + 参考音频克隆） |
| [research-auk.md](archive/research-auk.md) | 腾讯混元 AuK 语音模型调研（2026-09-22） |
| [review-stability-2026-07.md](archive/review-stability-2026-07.md) | 架构稳定性评估快照（2026-07-01） |

## 三条规则（分类的依据，也是防止再次漂移的护栏）

1. **架构文档只写现在是什么样。** 事故、教训、历史方案一律进 `archive/`，
   架构文档最多留一句指针 + 落到代码注释里。
   写进文档时：**保留「结论 + 为什么」，删掉「什么时候、怎么演变的」**——
   日期和叙事属于 archive。同一段理由在两处出现时，架构文档只留指针。
2. **带日期的一律进 `archive/`。** 调研若尚未启动，它也不属于核心区——
   启动时移出，完结后归档。
3. **取舍有分歧听目的层**（purpose.md），**机制听不懂看比喻层**（paper.md）。
   两份各管一头，别把「先读」当成「拍板」——paper.md 不做裁决，裁决全在 purpose.md。

> 违反规则最典型的症状：文档里出现了已删除的符号名（`anyTurnInFlight`、`QueueBucket`……），
> 或写着「尚未实施」而代码早已落地。发现即修——**文档比代码旧，比文档坏更危险**。
