# iVox

<p align="center">
  <img src="https://img.shields.io/badge/Swift-6.4-FA7343?logo=swift&logoColor=white" alt="Swift 6.4">
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple_Silicon-M1%2B-A2AAAD?logo=apple&logoColor=white" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/TTS%2FASR-MLX_Local-7B68EE?logo=mlflow&logoColor=white" alt="MLX Local TTS/ASR">
  <img src="https://img.shields.io/badge/license-MIT-green?logo=opensourceinitiative&logoColor=white" alt="MIT">
</p>

<p align="center">
  <b>macOS 本地语音助手</b> — TTS 播报 · ASR 语音输入 · 划词翻译 · 微信消息桥接<br>
  语音全本地 MLX 推理；划词翻译默认 Google，也可换任意 OpenAI 兼容服务
</p>

---

## 功能

| <img width="44" src="https://cdn.jsdelivr.net/gh/twitter/twemoji@14.0.2/assets/svg/1f5e3.svg"><br>**自动播报** | <img width="44" src="https://cdn.jsdelivr.net/gh/twitter/twemoji@14.0.2/assets/svg/1f39b.svg"><br>**媒体控制** | <img width="44" src="https://cdn.jsdelivr.net/gh/twitter/twemoji@14.0.2/assets/svg/1f399.svg"><br>**语音输入** | <img width="44" src="https://cdn.jsdelivr.net/gh/twitter/twemoji@14.0.2/assets/svg/1f4d6.svg"><br>**划词翻译** | <img width="44" src="https://cdn.jsdelivr.net/gh/twitter/twemoji@14.0.2/assets/svg/26a1.svg"><br>**快速操作** | <img width="44" src="https://cdn.jsdelivr.net/gh/twitter/twemoji@14.0.2/assets/svg/1f4ac.svg"><br>**微信桥接** |
|---|---|---|---|---|---|
| AI 回复边生成边念，跳过代码与噪音；可开屏幕字幕（贴底跟随声音）；手动打断三档：`Ctrl+Esc` 掀页 · `Ctrl+1` 掀摞 · `Ctrl+2` 全掀 | Web 控制台：远程控制音乐播放 / 暂停 / 切歌 / 音量 | 按住说话，松开识别粘贴，浮窗实时显示波形 | 选中即译，屏幕下方歌词式浮窗出译文并可朗读 | 在当前目录开终端 / 开终端跑 `claude`、`codex`、`pi` / 复制 Finder 选中路径 | 微信消息直通常驻 Claude，回复以文字转发回微信（**不念**） |
| 装好即用 | 打开 `127.0.0.1:8888`，手机同局域网用 `http://<本机IP>:8888` | 右 ⌘ / 右 ⌃ | `Cmd+D` | `Opt+Z` · `Opt+A` · `Opt+X` · `Opt+Q` · `Opt+C` · `Opt+S` | `ivox wechat setup` |

---

**手感上的几处讲究**（都不需要你操作，只是别以为是卡了）：按住右⌘ 不足 0.15 秒就松手会被当作误触
忽略掉；麦克风没插时按右⌘，播报不中断、音乐不停，只有 `daemon.log` 里留一句原因（它会写清是没插设备
还是没给授权）；Cmd+D 连按是「换了个选区再译一次」而非丢弃，所以翻译请求会等浮窗稳 0.2 秒才发——误触最多
闪一个空窗，不会白花一次请求；同一段文字反复译只发一次请求。

播报**不打断你在听的背景音乐**——只有你按住右⌘ 说话时，音乐才让开给麦克风（录音需要安静）。一条命令安装，用 `ivox on/off` 控制启停（LaunchAgent 托管：登录自启 + 崩溃自动重启）。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/xdfnet/iVox/main/scripts/install-binary.sh | bash
```

安装会一并装好：二进制、hook 集成、配置（含全量热键）、4 个音色的参考音频、MLX 模型，
并把守护进程拉起来（登录自启 + 崩溃自动重启）。装完只剩三件要你手动做：给**麦克风**与
**输入监控**权限、`ivox wechat setup` 扫码微信、试一下 `Cmd+D`。

需要编译？克隆后 `make` 即可（需 Xcode 26+，自带 Swift 6.4）。

## 使用

安装完服务已在后台运行。常用命令：

```bash
ivox speak "你好"           # 手动播报
ivox skip --page            # 掀页（Ctrl+Esc，可省）；--stack 掀摞（Ctrl+1）；--all 全掀（Ctrl+2）
ivox translate "hello"      # 划词翻译（--selection 取当前选中文本，--json 结构化输出）
ivox voice list             # 列出音色
ivox status                 # 版本、各功能健康状态、权限、模型/音色文件体检
ivox listen -f 录音.wav     # 语音识别
ivox on                     # 启动（并配置登录自启 + 崩溃自动重启）
ivox off                    # 停止并关闭自启（卸下 job + disable；plist 保留，ivox on 恢复）
ivox restart                # 只重启守护进程（改完配置跑一次即生效，不动自启开关）
ivox update                 # 检查 GitHub 最新版并自动升级（备份旧版、重签、重启）
```

**健康检查**（Web UI 端口，默认 8888）：

```bash
curl -s 127.0.0.1:8888/health
# {"status":"ok","version":"5.3.0","model":"Qwen3-TTS-…","engine":"ready","queued":0,"playing":false}
```

**微信**：配置后微信消息自动注入 Claude Code，AI 回复以**文字**转发回微信，不经 TTS 播报——
聊天窗口里已经有文字了，再念一遍是打扰（裁决见 `docs/playback/purpose.md`）。

```bash
ivox wechat setup              # 扫码登录微信机器人的 ilink bot
ivox wechat status             # 查看配置状态
```

音色匹配：`--voice` 指定 > `sourceVoices` 映射 > `sourceVoices.default`

| 音色 | 说明 |
|------|------|
| 甜妹桃子 taozi | 活泼甜美，默认 |
| 湾湾小何 wanwan | 温柔知性 |
| 米仔 mizai | 温暖自然 |
| 大易 dayi | 沉稳可靠 |

> 音色基于 `refAudio` + `refText` 做声音克隆。可自定义：`ivox voice add -i my -n "我的" --ref-audio ~/voice.wav --ref-text "内容"`

## 开发

```bash
make build     # release 编译（自动使用 Xcode 26 自带的 Swift 6.4）
make run       # 编译 + 前台调试
make update    # 停服 + 编译 + 部署 + 启动守护进程
make test      # 运行测试（iVoxKit 纯逻辑，秒级）
make check-tts # 播报黑盒自检（压真实 daemon，发版前手动跑）
make clean     # 清除 .build
```

> `make check-tts` 需先 `ivox on` 且模型就绪；自检脚本本身是 Node 写的，缺 node 会提示 `brew install node`（注意与微信常驻 Agent 无关——那条链路是 Swift 直连 claude，本来就不经 node）。它通过 Unix socket + `/health` + 增量 tail `daemon.log` 校验协议、合成时长、轮次隔离、密集打断、尾音完整等 **20 个用例**。它是**排障工具**——平时不必每次改动都跑，但**动播报核心（收尾 / 打断 / 入队）时必须跑全量**。常用：`make check-tts ARGS="-f tail"` 只跑某组、`ARGS="--strict"` 让 advisory 用例也计入失败、`ARGS="--managed"` 由脚本自行重启守护进程。

> 构建用 `xcrun --toolchain swift-latest swift`，该 toolchain 即 Xcode 26 自带的 Swift 6.4。
> 曾需要 `swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-06-15-a`（早期快照的编译器崩溃，见
> [`docs/archive/incident-swift-compiler-crash.md`](docs/archive/incident-swift-compiler-crash.md)），现已不需要。

## 配置

配置分三层，各管各的：

| 层 | 位置 | 谁改 | 升级时 |
|---|---|---|---|
| **代码内配置** | `Sources/iVoxKit/Config.swift`：`ModelPaths`（模型路径）、`TTSConfig.default`（合成参数）、`VoiceCatalog`（内置音色） | 随代码发布 | 跟着升级更新 |
| **外部配置** | `~/.config/ivox/config.toml`（**就这一个文件**，TOML 格式，能写注释） | 你手改 | 不动（安装脚本只做加法） |
| **用户数据** | `~/.config/ivox/recordings/`、`wechat/context_token.json` | 程序写 | 保留 |

判据：**凭据**（微信 token、翻译 apiKey）、**你常改的**（开关、键位、端口、翻译服务与模型、选音色）放外部配置；
**产品内容**（模型路径、合成参数、内置音色清单）写在代码里，不占你的配置。

`~/.config/ivox/config.toml` 主要字段（**键名一律驼峰**）。格式是 **TOML**：`#` 后面是注释，
方括号是段名，等号右边是值——比 JSON 好读，因为能写注释：

```toml
# 划词翻译
[hotkeys]
translate = "cmd+d"     # 我常用 cmd+shift+d，改完跑 ivox restart 生效
```

主要字段：

| 字段 | 说明 |
|------|------|
| `speechInput.enabled` | 语音输入开关 |
| `translation.provider` | 划词翻译服务：`google`（默认，免配置）/ `openai`（OpenAI 兼容） |
| `translation.speechEnabled` | 划词翻译后是否朗读译文 |
| `translation.proxyURL` | 直连不通时的兜底代理，如 `http://192.168.100.6:10808`（只在直连失败后才用） |
| `hotkeys` | 热键（键位写法见下）；首次安装会写全量默认键位 |
| `wechat.token` / `wechat.allowFrom` | 微信 ilink bot token / 允许发消息的那个用户 |
| `sourceVoices` | 按接入方分别选音色；其中 `default` 键就是**默认音色**（没有来源时用它） |
| `voices` | **只放你自建或覆盖的音色**；内置的四个在代码里（`ivox voice list` 会标出哪个是内置） |

**写错的键不会静默**：守护进程启动时会把「写了但没人认领」的键打进 `daemon.log`，
还会猜你是不是想写别的名字（如 `allow_from` → 「是不是想写 allowFrom？」）；
`ivox status` 里也直接列出来。

完整字段见 `Sources/iVoxKit/Config.swift`，默认模板见 `Sources/iVoxKit/ConfigTemplate.swift`
（`ivox init-config` 写的就是它）。

### 改快捷键

热键写在配置 `~/.config/ivox/config.toml` 的 `hotkeys` 段。**首次安装会写全量默认键位**（下表那些），
改哪一行改哪一行；没写的项用内置默认值。
改完跑 `ivox restart` 生效（守护进程重读配置；`restart` 只重启进程，不动登录自启开关）。

```toml
[hotkeys]
translate = "cmd+shift+d"
skipPage = "ctrl+alt+right"
voice = "rightcmd"
```

| 动作名 | 默认键位 | 干什么 |
|---|---|---|
| `translate` | `cmd+d` | 划词翻译 |
| `openTerminal` | `opt+z` | 在当前目录开终端 |
| `openTerminalClaude` | `opt+a` | 开终端跑 `claude` |
| `openTerminalCodex` | `opt+x` | 开终端跑 `codex` |
| `openTerminalPi` | `opt+q` | 开终端跑 `pi` |
| `copyPath` | `opt+c` | 复制 Finder 选中路径 |
| `paste` | `opt+s` | 粘贴：把剪贴板贴到当前光标（配 `opt+c` 用，一步到位） |
| `escInterrupt` | `ctrl+2` | 闭嘴（全掀） |
| `skipBucket` | `ctrl+1` | 跳整摞 |
| `skipPage` | `ctrl+esc` | 读下一页（掀页） |
| `voice` | 右 ⌘ | 长按说话；可写 `rightcmd`（默认）/ `rightctrl` / `rightcmd+rightctrl` / `none` |

写法：修饰键 `cmd` `ctrl` `opt` `shift`（也认 `command` `control` `option` `alt`），用 `+` 连主键；
主键可用 `a-z`、`0-9`、`esc`、`space`、`tab`、`return`、`backspace`、`delete`、`f1`-`f12`、方向键。

配错了**不会静默**：守护进程启动时会在 `daemon.log` 里写清楚是哪个动作、错在哪、退回了哪个默认键位；
两个动作抢同一个键位也会说明（配的优先，另一个退回默认）。

## 架构

```
Claude Code → hook ─┐
pi 扩展（逐句流式）──────────┴→ Unix Socket → Daemon
                                            ├── TSPRemote ─→ 誊清员进程 (独立, MLX 合成)
                                            ├── WeChatPlatform (ilink 长轮询)
                                            │       └─ 常驻 Claude Agent (Swift 直连 claude)
                                            ├── GlobalKeyTap (键盘事件层：一个 tap，按归属路由)
                                            │       ├─ SpeechInput  (右 ⌘ / 右 ⌃ + ASR)
                                            │       ├─ Translation  (Cmd+D 划词翻译 + 浮窗)
                                            │       ├─ QuickActions (Opt+Z/A/Q/X/C)
                                            │       └─ 手动打断三档 (Ctrl+Esc 掀页 / Ctrl+1 掀摞 / Ctrl+2 全掀)
                                            └── MediaHTTPServer (Web UI)
```

微信消息经守护进程发给一个常驻 `claude` Agent（Swift 经 stdio NDJSON 直连，无 node 依赖），后台任务可跨消息持续运行；Agent 工作目录隔离在 `~/.config/ivox/wechat/workspace`，发 `/new` 可开新会话。

详见 [架构文档](docs/architecture.md)。

## 权限

| 权限 | 用途 | 是否必需 |
|------|------|:--------:|
| **麦克风** | 语音输入（按住右 ⌘ / 右 ⌃ 说话 → ASR） | 不用语音输入可不给 |
| **设备控制与数据访问** | ① 监听修饰键 ② 剪贴板粘贴注入 ③ 媒体控制 | **是** |
| **输入监控** | 划词翻译的 `Cmd+D` 等**普通键**热键 | 要划词翻译才需要 |
| **自动化（Finder）** | QuickActions 读取 Finder 当前目录 / 选中项 | 只用 Opt+Z/A/Q/X/C 才需要 |
| **代码签名** | ad-hoc 自签，每次重建哈希变化 → TCC 权限失效 | 部署后重新勾选 |

> **划词翻译要「输入监控」**：只给"设备控制与数据访问"时，右 ⌘ 语音照常，但 `Cmd+D` 毫无反应——tap 明明创建成功，却收不到普通键，最难排查。`ivox status` 的「划词翻译」一行会如实反映。

设备控制与数据访问路径：系统设置 → 隐私与安全性 → 设备控制与数据访问 → 勾选 `ivox`。

> 重建二进制后 ad-hoc 签名变化，TCC 记录的权限会失效。`make update`（`deploy-bin`）会自动重新签名，但如果权限丢了，需要去系统设置重新勾选。

## 依赖

- macOS 14+ / Apple Silicon
- Xcode 26+（自带 Swift 6.4）
- [Claude Code](https://claude.com/claude-code) CLI — 微信常驻 Agent（Swift 经 stdio 直连）
- [Ghostty](https://ghostty.org) — 终端模拟器；快速操作的「开终端跑 `claude`/`codex`/`pi`」（`Opt+A`/`Opt+X`/`Opt+Q`）用它（`brew install --cask ghostty`）
- [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) — 本地 MLX 推理
- [Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS) — TTS 模型（[官方博客](https://qwen.ai/blog?id=qwen3tts-0115)）
- Qwen3-ASR-1.7B — 本地语音识别模型（首次安装自动下载）

## 许可

MIT
