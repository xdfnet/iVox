# iVox 开发日志

## v2.8.8 — 2026-08-02

### 修复

- **AudioPlayer.drain 回调丢失根治** — `scheduleBuffer` 原用旧 API（`.dataPlayedBack` 语义），播放末尾引擎 auto-shutdown 时完成回调永不触发，`pendingCount` 不归零，`drain()` 只能靠超时兜底强制返回（每段末尾丢尾/超时 WARN）。现改用 `completionCallbackType: .dataConsumed`（数据被播放器读出即回调，不依赖引擎存活），从根上消除回调丢失
- **取消后计数污染** — `cancelPendingPlayback()` 归零后旧 buffer 回调再 `-= 1` 把 `pendingCount` 减成负数（曾见 -772），drain 必走超时、账目失真。现递增 `generation` 使旧世代回调经 guard 丢弃，计数保持干净
- 新增 `docs/audio-player-drain.md` 固化问题与三层解决方案（超时兜底 / 世代计数 / `.dataConsumed`），`docs/playback-queue.md` 同步维护约束

## v2.8.7 — 2026-08-02

### 修复

- **语音输入事件线程生命周期** — `stop()` 原先用 `CFRunLoopGetCurrent()` 在调用线程的 runloop 上移除事件线程的 source，`CFRunLoopRun` 永不退出导致线程泄漏；权限轮询无退出条件，stop 后还会自动拉起新线程。现改为记录事件线程自己的 runloop、用 `CFRunLoopStop` 唤醒退出，轮询检查停止标志，事件 tap / runloop / 线程引用统一用队列保护（消除 TOCTOU），事件回调与 `eventTap!`/`refcon!` 强制解包一并清理
- **强制解包清理** — `WeChatClient` 4 处 `URL(string:)!` 与 `group.next()!` 改为 guard + 抛错；`TextCleaner` 的 `try! NSDataDetector` 改 `try?`，失败时降级返回原文
- **静默吞错** — `MediaController` 暂停/恢复失败、应用启动失败不再静默，记录日志并返回失败；`ClipboardInjector` Enter 事件创建失败改为抛错
- **socket 阻塞超时** — `SocketClient` 连接设置 10s 读写超时；`SocketServer` 对客户端连接设置 10s 读超时，坏客户端不关闭连接时读取不再无限挂起
- **命令退出码** — `ivox say`（守护进程未运行）、`ivox restart`（重启失败/未注册）、`ivox voice list`（配置加载失败）不再静默返回 0
- **硬编码路径集中** — 新增 `AppPaths`（HOME 未设时退回 `NSHomeDirectory`），7 处重复的 `~/.config/ivox/ivox.sock` 统一收敛，微信配置引导的二进制路径一并修正
- **输入校验** — `ivox listen` 语言参数只允许纯字母（防协议注入），stdin 改分块读取并限 100MB（防内存耗尽）；微信扫码 `qrKey` 补 URL 编码；ASR 语言码校验
- **StreamFrame 超大帧防护** — 声明帧超过 100MB 直接清空缓冲终止解析，防恶意流缓冲膨胀（新增 2 个单测）
- **socket 文件清理** — bind/listen 失败时 unlink 残留 socket 文件；`chmod` 提前到 listen 前执行
- **脚本健壮性** — `install-binary.sh` 按 CPU 架构（arm64/x86_64）精确选择 release 资产，避免下到不兼容二进制；`runtime.sh` bundle 缺失时输出明确警告

### 其他

- 清理编译 warning：`MediaHTTPServer` 多余 `await`、`WeChatClient` 非可选 `??`

## v2.8.6 — 2026-08-01

### 修复

- **hook 过滤过短纯西文确认** — Claude 会话工具间隙输出的 `true`/`ok`/`done` 等 ≤5 字符纯西文确认不再播报（hook.sh 提取时置空，跳过微信与 TTS）
- **AudioPlayer.drain 超时兜底** — `drain()` 依赖 buffer 播放回调归零 `pendingCount`，一旦 AudioEngine 被系统事件（设备切换/休眠等）停止，已排队 buffer 回调集体丢失导致 `pendingCount` 永不归零、播放队列被单个 job 永久阻塞（实测最长卡 3.9 小时，堆积 14 个请求）。现按本段已写帧数估算播放时长 + 2s 余量强制返回，日志关键字 `drain 超时强制返回`

## v2.8.5 — 2026-07-31

### 新功能

- **`type:tts` 合成返回 PCM 协议** — 发送 `{type:tts,source:…,voice:…}\n<文本>`,iVox 合成但不播放、不入队,流式分块返回 48kHz Int16 mono PCM(`[4B 小端长度][数据]` 帧,4 个 0 的 `end` 结尾),供调用方自己播放(如 iAgent AEC 回声消除的参考信号)。客户端断开时立即停止合成,释放 GPU

### 修复

- **麦克风权限描述缺失** — launchd plist 未声明 `NSMicrophoneUsageDescription`,通过 `-sectcreate` 嵌入 `__TEXT,__info_plist` 让 TCC 能找到用途描述,避免麦克风权限被拒

## v2.8.4 — 2026-07-31

### 新功能

- **`__IVOX_STOP_PLAYBACK__` 停止播放协议** — 通过 socket 发送该文本，立即取消当前及排队播放（不退出服务），供 iAgent 播报打断（Barge-In）使用

## v2.8.3 — 2026-07-26

### 修复

- **并发安全** — TTSEngine 多 waiter 共享数组替代单 continuation、失败时也 resume；AudioPlayer deinit 恢复 drainContinuation；MediaHTTPServer generation 防 stop/start 竞态；ClipboardInjector 串行队列防多线程竞态；SpeechInputService deinit 防悬空指针
- **注入防护** — hook.sh `--` 防参数注入、后台进程关 fd3；install-hooks.sh `jq --arg` 消除命令注入
- **脚本健壮性** — install-binary.sh heredoc 展开 `$HOME`、darwin asset 过滤；download-models.sh clone 前后 `rm -rf`；runtime.sh bootstrap 失败给明确提示、去无差别 `pkill`；Makefile sed/grep 兼容 Linux
- **WeChatPlatform** — session 过期时 `verifyToken()` 刷新替代死循环
- **SocketServer** — client socket 加 `SO_NOSIGPIPE`，防 SIGPIPE 杀 daemon
- **ASRClient** — `defer` 移到 `write` 之前，写失败也能清 temp file

## v2.8.2 — 2026-07-24

### 修复

- **语音输入后音乐恢复时序** — ⌘ 松开后立即 `media.resume()` 可能抢在 TTS 入队前恢复音乐，导致播报和音乐重叠。改为延迟 2 秒调用 `resumeIfIdle()`，仅在队列真正空闲时才恢复
- **processNext 竞态恢复音乐** — 旧一代的 `processNext` 在 yield 后判断 `jobs.isEmpty` 可能误恢复音乐，而此时新一代 task 已入队。引入 `generation` 计数，只有最新一代的 task 能执行 `media.resume()`

### 改进

- **`resumeIfIdle()`** — PlaybackQueue 新增安全恢复接口，外部（如语音输入）可在不确定队列状态时安全请求恢复音乐，仅在 `jobs.isEmpty && currentTask == nil` 时执行
- **切换到 Swift 6.4 工具链** — 之前因 `performSILProcessing` 栈溢出 bug 锁定在 6.3.2，该 bug 已在 `swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-06-15-a` 中修复。改用 `xcrun --toolchain swift-latest swift` 构建

## v2.8.1 — 2026-07-20

### 修复

- **PlaybackQueue peek + claim** — v2.8.0 的"catch 还回 job"修复在队列空时会重听当前段（DEL 被解读为"重听 A"）。改用 peek + claim 模式：队首 job 直到 `synthesizeStream` 拿到 stream 才 `removeFirst`，cancel 撞不上这条同步路径，catch 块不再动 `jobs`

## v2.8.0 — 2026-07-20

### 修复

- **AudioPlayer 自愈** — 写入前自检引擎状态，异常时自动 `reset() + start() + play()` 重建；之前会静默丢弃 PCM
- **TextCleaner 过滤统一** — 千分位逗号、ASCII hyphen 纳入白名单保留；Tab / NBSP / 全角空格等 Unicode 空白统一当空格合并；emoji 修饰符（含肤色）一并砍掉
- **PlaybackQueue race 修复** — DEL/取消时若 job 已被 `removeFirst` 取出但未开始播放，还回队首避免静默丢段

## v2.7.0 — 2026-07-15

### 新增

- **⌦ 快捷键** — 按 Forward Delete 跳过当前播报，直接播队列里下一个；队列空才停
- **`skipCurrent()`** — 新增 PlaybackQueue 异步方法：取消旧 task → await 退出 → 启动新 processNext 接队列，避免并发写 player

### 改进

- **FIFO 排队** — `enqueue()` 不再 `removeAll`，队列可累积多条任务按顺序播完
- **不打断正在播** — 去掉 `config.interruptCurrent` 强制切换逻辑，新任务入队不打断当前
- **processNext 改 while 循环** — 一次性消费队列里所有 jobs，播完再统一 `media.resume()`

## v2.6.0 — 2026-07-13

### 改进

- **AudioPipeline 精简** — 去掉 AudioPlayer 自动复活、TTSEngine 重试循环、PlaybackQueue 的 while/async let/defer，线性流程：暂停→播→恢复
- **打断逻辑修复** — `enqueue()` 打断时先 `cancelPendingPlayback()` 静音再启动新 Task，消除新旧音频重叠
- **取消不丢任务** — `try?` 改为 `try`，取消信号不会丢失导致任务漏播
- **Config 简化** — 去掉 `maxRetries`、`retryDelayMs`

### 工具

- **Makefile 精简** — 只保留 `make install` 和 `make update`，去掉 deploy/launchd/restart 中间目标

## v2.5.0 — 2026-07-09

### 改进

- **过滤逻辑重构** — TextCleaner 第二层改为白名单模式，只保留字母/数字/中文 + 语气标点（`。！？%`），其余符号全部过滤
- **断句逻辑移除** — 内容直接一段发给 TTS，不做句末标点切分
- **日志精简** — 核心业务 INFO，调试信息 DEBUG，移除重复/装饰性日志
- **媒体控制简化** — 移除远程控制分支，只保留本地 MPRemoteCommandCenter

## v2.4.3 — 2026-07-08

### 修复

- **drain 超时估算修正** — 分句播报时偶尔出现约 30 秒停顿。问题原因：drain 用 `chunks * streamingInterval(0.08)` 估算播放时长，但 streamingInterval 是模型输出 chunk 的间隔，不等于 chunk 对应的实际音频时长。实测每 chunk 平均 0.33 秒，远大于 0.08 秒，导致 105 chunks 实际需要 34.7 秒播完，但估算只有 8.4 秒，触发误判重启。修复：系数从 0.08 改为 0.4

## v2.4.2 — 2026-07-02

### 改进

- **ASR 时自动取消 TTS** — 按 Cmd 录音前先停掉正在播和待播的语音，避免音响声音被麦克风采集干扰 ASR
- **媒体控制界面重新布局** — 顺序调整为锁屏→App→音量→播放控制
- **播放键改为模拟空格键** — playpause 从 `MRMediaRemote` 切换改为 `CGEvent` 空格键，需要辅助功能权限
- **锁屏改回按钮** — 滑块方案取消，保持顶部位置用红色按钮

### 修复

- **ASR 取消 TTS 后无声音** — `cancelAll()` 误调 `player.stop()` 导致引擎关闭且 `started=false`，后续 `write()` 静默丢弃所有音频数据
- **bundle 部署命中旧包** — `runtime.sh` 用 `find` 扫全部 `.build` 目录，`head -1` 可能选中 debug 旧包，锁定 release 路径

### 文档

- **`docs/stability.md`** — 新增架构稳定性评估文档

## v2.4.1 — 2026-07-01

### 重构

- **hook 脚本改名** — `hook-speak.sh` → `hook.sh`，所有文档、脚本、配置同步更新

### 文档

- **`docs/stability.md`** — 新增架构稳定性评估文档

## v2.4.0 — 2026-07-01

### 新增

- **微信 iW 集成** — 接入 WeChat ilink 协议，长轮询接收消息 → 注入 Claude Code
- **微信配置** — `config.json` 新增 `wechat` 段：`token`、`base_url`、`allow_from`、`long_poll_timeout_ms`
- **微信命令** — `ivox wechat setup`、`ivox wechat status`、`ivox wechat text`

### 修复

- **URLSession 超时兼容长轮询** — `withThrowingTaskGroup` 手动超时，绕过长轮询 TCP 保活导致 URLSession 空闲超时不触发的问题
- **`GetUpdatesResp.ret` 改为可选** — 长轮询空响应不返回 `ret` 字段，`DecodingError.keyNotFound` 导致轮询卡死
- **轮询日志增强** — 所有错误都打日志，不再静默吞掉非网络类错误
- **Swift 6.4 编译器崩溃** — MLXAudioTTS 在 `-O` 下 `performSILProcessing()` 栈溢出，固定使用 Swift 6.3.2 工具链编译

### 构建

- **`.swift-version` 移除** — 改用 `TOOLCHAINS=swift-6.3.2-RELEASE` 环境变量
- **Makefile 新增 `SWIFT` 变量** — `$(SWIFT) build` 自动使用 6.3.2 工具链
- **`docs/compiler-bugs.md`** — 记录 Swift 编译器已知问题

## v2.3.1 — 2026-06-22

### 新增

- **ASR 对外开放** — `ivox listen` CLI + Unix Socket 协议，`{type:asr,lang:zh}` + WAV，任何本地程序可用
- **TTS 长文本分段播放** — 按句切分到 ≤80 字，逐段 TTS 合成，批次编号 + 段编号日志
- **Socket API 文档** — `docs/api.md`，供其他 App 接入 TTS/ASR

### 优化

- **块级节点自动补句号** — 段落/标题/列表/代码块末尾无标点时自动补 `。`，TTS 语气有边界
- **按钮朴素化** — 移除 busy 锁，所有按钮无阻塞点击

## v2.3.0 — 2026-06-22

### 架构

- **媒体控制从 iDict 迁移到 iVox 内建** — 通过 `MediaRemote` 私有框架直接控制系统媒体，不再依赖外部 iDict HTTP 服务
- **双模调度** — `baseURL` 为空时走本地原生引擎，非空时保留远程模式，向后兼容
- **嵌入式 HTTP 服务器** — 移植 iDict 的 `MediaHTTPServer`，提供 Web UI 和 REST API（可选启用）

### 新增

- **原生媒体引擎** — `MediaRemoteBridge` 动态加载 `MRMediaRemoteSendCommand`，支持 play/pause/toggle/next/prev
- **`AudioAppRegistry`** — 从 MediaController 中提取应用注册表，职责单一
- **Web UI** — `http://127.0.0.1:8888` 移动端远程控制界面（需配置 `httpServerEnabled: true`）
- **`make deploy` 自动复制资源包** — `iVox_iVox.bundle` 含 index.html 和图标

### 优化

- **音频播报暂停不再走 HTTP** — PlaybackQueue 和 SpeechInputService 直接调原生引擎，消除 iDict 依赖
- **锁屏交互简化** — 滑块改为按钮，直接触发
- **MediaHTTPServer 线程安全** — `OSAllocatedUnfairLock` 保护共享状态
- **应用启动等待延长** — 从 2.3s 增加到 8s，适配 Electron 应用（抖音/汽水音乐）
- **页面移除状态指示器** — 干净简洁，播放按钮改为固定图标走 `MRMediaRemoteSendCommand(.toggle)`
- **`MediaControlConfig` 默认改为本地模式** — `baseURL: ""`，新用户开箱即用

### 修复

- **`AudioAppRegistry` 短名匹配 bug** — `bundleID.split(".").last` 取到 `"desktop"` 而非 `"douyin"`，导致 `toggle_douyin` 失败

## v2.2.1 — 2026-06-21

### 修复

- **Emoji 过滤误杀数字** — `isEmojiPresentation` 漏掉对象 emoji（📟📊🔄 等），改 `isEmoji` 但误杀 ASCII 数字，最终加 ASCII 白名单
- **mlx-audio-swift 更新** — 同步最新 main (3f6b055)，含 CustomVoice 语音解析修复

## v2.2.0 — 2026-06-20

### 架构

- **Task 取消架构** — PlaybackQueue 从 generation-counter 迁移到 Swift 结构化 Task 取消：`currentTask?.cancel()` + `defer` 清理 AudioPlayer，消除打断时的竞态条件
- **AudioPlayer 职责收敛** — 移除 `activeGeneration` 和 generation 参数传递，AudioPlayer 只负责音频写入，不再参与取消逻辑
- **TextCleaner 精简** — 102 行 → 53 行，去掉 block 拆分和硬编码 `。` 拼接，纯文本收集 + 块间空格分隔

### 修复

- **打断播放静音 bug** — `cancelPendingPlayback()` 在 enqueue 和 processNext 各调一次，第二次误清新 job 的音频缓冲区

### 编译

- **ICE 已修复** — Swift 6.4-dev (2026-06-15) 快照包含 LICM 修复，全局 `-Osize` 编译通过，Makefile 去掉 `-Onone`，Package.swift 去掉 per-target `unsafeFlags(["-O"])`
- **二进制体积** — 68MB → 55MB（-19%）

## v2.1.1 — 2026-06-19

### 优化

- **编译优化** — iVox/iVoxKit 单独开 `-O`，MLX 依赖继续用 `-Onone` 绕 ICE，推理编排代码显著提速
- **进程优先级** — launchd `ProcessType` 从 `Background` 改为 `Standard`，避免调度优先级过低导致推理卡顿
- **流式间隔调整** — `streamingInterval` 从 0.08s 增加到 0.15s，累积 2 帧再回调，减少音频片段开销
- **二进制安装简化** — 二进制和 Metal shader 合并为 `tar.gz` 单包，安装脚本只下载一个文件

### 修复

- **二进制安装签名** — `install-binary.sh` 新增 ad-hoc 签名步骤，避免从 GitHub Release 下载的二进制在部分系统上无法运行

## v2.1.0 — 2026-06-18

### 改进

- **AudioEngine 崩溃自动恢复** — 引擎崩溃不会永久静默，30s 冷却期后自动重试
- **媒体控制冷却** — 服务不可用时 5s 冷却期，不再连续重试轰炸
- **TTS 文本管道重写** — 从"去噪音"改为"文本自然化"：
  - 保留句号/问号/感叹号，让 LLM TTS 获得完整节奏信号
  - 短代码块（≤3行且≤80字）转为 inline 保留，不丢弃关键信息
  - commit hash 只删 16 位以上完整 SHA，保留短引用
  - 块间用空格分隔，不再所有段落用顿号拼接

### 修复

- **编译 ICE 绕过** — `-Onone` 替代 `-Osize`，mlx-swift 在 Swift 6 下优化阶段会崩溃
- **launchd 目录缺失** — 补了 `~/.local/share/ivox/runtime/`，修复守护进程启动失败

### 文档

- README、CHANGELOG 更新到 v2.1.0

## v2.0.1 — 2026-06-15

### 移除
- Pi 集成支持：删除 ivox.ts 扩展、install-hooks.py 中 Pi 安装逻辑、runtime.sh 中 Pi 部署
- dayi 音色保留，配置中 `sourceVoices` 去掉 `"pi": "dayi"`
- `--source` 选项帮助文本更新为 `claude/codex`
- 文档同步清理：README、architecture.md、hook-chain.md

## v2.0.0 — 2026-06-14

### 架构变更：iLLM API → 本地 MLX 推理

- 新增 `mlx-audio-swift`，TTS / ASR 改为进程内本地模型推理
- 配置 `api.baseURL` / `api.ttsModel` → `models.ttsPath` / `models.asrPath`
- 音色重新支持本地 `refAudio` + `refText` 参考音频配置
- ASR 模型仅在语音输入启用时加载，减少禁用场景的启动成本
- TTS PCM 转换改为按模型采样率重采样到播放器采样率，避免固定 24k 假设导致变速
- 新请求会立即取消正在合成/播放的旧播报，避免长文本占住队列导致后续消息卡住
- 新增 `tts` / `playback` / `mediaControl` 配置块，可调语言、流式间隔、重试、输出采样率、打断策略和 iDict 地址
- Daemon 启动顺序优化：先监听 socket，再后台加载/预热 TTS 与 ASR，冷启动时 hook 不再误判服务未启动
- Makefile 清理：删除旧 `model` phony、修正 `run`/`sign` 职责、增加 `restart`，并让 `launchd` 重启更幂等
- 新增 `make models`：通过 ModelScope 从 `mlx-community` 下载默认 TTS / ASR MLX 模型，安装流程自动执行，已有模型会跳过
- Makefile 重构为流程编排层，部署细节下沉到 `scripts/runtime.sh`；新增 `make update` 作为日常更新入口
- 部署流程新增参考音频初始化：内置默认 `ref_*.wav`，`make deploy` 自动补齐 `~/.config/ivox/voices/` 中缺失的默认音色
- Release 构建切换为 `-Osize`，规避 `MLXAudioTTS` 在 Swift `-O` 下触发的编译器崩溃
- 测试更新到新的 `models` 配置结构

### 移除
- iLLM TTS / ASR TCP/HTTP 客户端链路
- `api.baseURL` / `api.ttsModel` 配置

### 文档
- README：更新徽章、模型目录、配置示例、依赖说明
- 架构文档：数据流图改为本地 MLX 推理链路

## v1.3.1 — 2026-06-12

### 稳定性加固
- AudioPlayer 自愈策略优化：空闲复活前移到播报前，避免首段 PCM 写入时重启引擎导致短播报静默或残缺
- AudioPlayerNode 自动恢复播放：补充 `node.isPlaying` 检查，处理引擎运行但播放节点停止的边缘状态
- 音频配置变更延迟处理：设备/采样率变化时先标记，下次播报前统一重启引擎，减少播放中断
- 版本号更新为 `1.3.1`

## v1.3.0 — 2026-06-09

### 正式版
- 发布 TextCleaner 新过滤架构：Markdown AST 结构过滤 + 轻量行内噪音过滤
- 文档同步到当前实现：README、架构文档、Hook 链路和 CHANGELOG 全部更新
- 版本号更新为 `1.3.0`

## v1.2.2 — 2026-06-09

### 文本过滤
- TextCleaner 改为基于 `swift-markdown` AST 做结构过滤，跳过代码块、行内代码、HTML、图片、表格和分隔线
- 移除 artifact 行级预处理，输入统一按完整 Markdown 解析
- 新增轻量行内噪音过滤：清理 URL、常见路径、UUID、commit hash、ANSI 转义、速度/ETA 噪音和状态符号
- 保留版本号、API 名、函数名、百分比和普通语义文本，减少误删关键信息

### 工程
- `iVoxKit` 新增 `swift-markdown` 依赖
- 更新 TextCleaner 测试，覆盖 Markdown 结构过滤和行内噪音过滤
- 版本号更新为 `1.2.2`

## v1.2.1 — 2026-06-06

### 稳定性加固
- 代码噪音过滤放宽：保留文件扩展名、环境变量名、版本号、时间戳和函数调用，避免朗读丢失关键上下文
- AudioPlayer 引擎自动复活：监听休眠唤醒/耳机插拔/音频配置变更，空闲 10 分钟主动重启
- drain() 超时检测：根据 chunk 数动态计算等待时间，超时自动重启引擎
- 日志精简：TTS 流式只打印第一块，不再每块输出

### 架构安全
- MediaController 异步化：URLSession + semaphore → async/await，消除死锁风险
- 优雅退出：signal() → DispatchSource，SIGINT/SIGTERM 时停 AudioPlayer、关 Socket、删文件
- ConnectionHandler 非阻塞分发：nonisolated + DispatchQueue，不占用 Swift 并发线程池
- make deploy 自动签名，sign 目标使用固定证书 Hash，不再按名称 grep

### 清理
- AudioPipeline.swift：删除未使用的 modelSampleRate/outputSampleRate/streamChunkMs/chunkBytes/iterPCMChunks
- Package.swift：iVoxKit 移除未使用的 MLXAudioTTS 依赖
- Resources/com.user.ivox.plist：删除（Makefile 内联生成，此文件无人使用）
- AudioPlayer.swift：删除 isStarted 属性，initError 改为局部变量
- ServeCommand/RestartCommand：过期提示 "ivox setup" → "make" / "make launchd"
- Config.swift：var → let
- Makefile：简化 cp -n + 死回退模式

### 文档
- 新增 docs/hook-chain.md：从 AI 工具触发到扬声器出声的完整链路文档
- README：修复不存在的命令引用（make debug/restart, ivox model pull）
- install.sh：移除对已删除 setup/model 子命令的调用，改用 make 目标

## v1.2.0 — 2026-05-31

### 版本号统一管理
- 新增 `Sources/iVox/Utilities/Version.swift` 作为单一版本源
- `VersionCommand` 引用 `iVoxVersion` 常量，不再硬编码
- Makefile 新增 `version` 目标：`make version V=v1.2.0` 自动改文件、commit、打 tag
- 架构文档移除 `make sign`，替换为 `make version`

### 文档
- README、架构文档、Makefile help 同步更新

## v1.1.1 — 2026-05-31

### 播放队列优化
- 新播报请求入队时自动丢弃队列中所有未开始的待播任务
- 正在合成/播放的不打断，播完自动切到最新一条
- 避免连续对话中旧回复堆积，始终优先播最新内容

### 媒体控制重构
- 从 `CGEvent` 系统媒体键改为调用 [iDict](https://github.com/xdfnet/iDict) HTTP API
- 移除 `entitlements.plist`，不再需要辅助功能权限
- 不再需要 Apple Development 证书签名
- `install.sh` 简化：跳过代码签名步骤

### 文档
- 更新 README、架构文档、CHANGELOG
- `install.sh` 移除过时的辅助功能权限提示

## v1.1.0 — 2026-05-29

### 安装简化
- Codex hook 不再修改 `~/.codex/config.toml`，首次触发时由 Codex 自动引导授权
- 移除旧版 Swift HookInstaller（逻辑迁入 Python 脚本）
- 清理 Installer 中的 `hashlib`/`re` 等已不需要的导入

### 文档
- 重构 README：从用户视角按命令分组，特性卡片 + shields.io 徽章
- 架构文档随代码同步更新
- 移除冗余的 release-notes 文件，内容已合并到 CHANGELOG
- 移除 Homebrew 安装方式说明

## v1.0.0 — 2026-05-29

### 正式发布
- 首个正式版本 v1.0.0
- GitHub Release + Git tag
- 发布说明：`docs/release-notes-v1.0.0.md`

### 媒体控制
- `MediaController`: CGEvent 系统媒体键，播报时自动暂停/恢复音乐
- 用 Apple Development 证书签名，辅助功能权限持久绑定
- Makefile 集成 `codesign` 步骤

### 播放队列
- `PlaybackQueue`: 竞态修复，尾递归重检查，防止处理期间新任务丢失
- 批量处理：while 循环替代递归 processNext
- 媒体控制集成：pause → 播放 → resume

### 安装脚本
- `install.sh`: 一键编译+签名+部署+初始化

### 文档
- README: shields.io 徽章 + 特性卡片 + 用户视角介绍
- `docs/release-notes-v1.0.0.md` 发布说明
- `docs/architecture.md` 更新：媒体控制、尾递归、部署结构
- `docs/CHANGELOG.md` 本日志

---

## 2026-05-29（开发期）

### 基础建设
- 修复 `setup` 时 `JSONSerialization` 写入 `\/` 的问题
- 模板 `config.example.json` 与运行配置对齐
- `hook-speak.sh` 从 90 行 Node.js 精简到 31 行 bash + python3
- `ivox.ts` Pi 扩展改为走 `ivox speak --source pi`，不再直连 socket
- Claude Code / Codex / Pi 三个工具统一走 `ivox speak --source`

### 参数链路
- `SpeakCommand`: `--voice` 参数修复，拼入 `{source:xxx,voice:yyy}` payload
- `ConnectionHandler.extractVoicePrefix`: 键值对解析，优先级 显式 voice > sourceVoices > defaultVoice

### 音频引擎
- `AudioPlayer` 重写：串行队列解决 AVAudioEngine 多 actor SIGSEGV
- `drain()` 改用 `scheduleBuffer` 完成回调 + 轮询等待，消除播放切尾
- 初始化保护：`initError` 状态 + `isStarted` 检查

### 流式合成
- `TTSEngine.synthesizeStream()`: `AsyncThrowingStream<Data>` 替换批量返回
- 重试机制：TTS 合成失败自动重试 2 次，每次间隔 500ms

### 模型预热
- `TTSEngine.warmup()`: daemon 启动后预热 GPU pipeline
- `Daemon.run()`: `loadModel()` 后立即 `await engine.warmup(voiceID:)`

### 新命令
- `ivox status` — socket 连接检查
- `ivox version` — v1.0.0
- `ivox restart` — launchd kickstart
- `ivox voice list` — 读 config 列出音色
- `ivox voice add` — 添加自定义音色
- `ivox voice remove` — 删除音色
- `ivox model pull` — 从 ModelScope 克隆 Qwen3-TTS 模型

### 运维
- 日志轮转：`daemon.log` 超过 5MB 自动归档 `.old`
- `saveConfig()` 公共 API，`\/` 自动清理
- `VoiceInfo` memberwise init

### 工程
- Git 初始化（main 分支），`.gitignore`
- Makefile: `build` / `debug` / `install` / `restart` / `clean`
- launchd plist 模板补完日志路径 + HOME 环境变量
- `installRuntimeArtifacts` 路径改为 `.build/release`
- 部署结构全部在 `~` 下，删项目无影响
