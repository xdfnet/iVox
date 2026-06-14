# iVox 开发日志

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
