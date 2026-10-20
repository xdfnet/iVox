# 运行时家当 — `~/.config/ivox/` 里都是什么

iVox 守护进程的全部运行时文件都在 `~/.config/ivox/`。**这份文档随代码走**（在版本库里），
说清每个文件是谁写的、能不能删、删了会怎样。

> 一句话：删东西前先回来看这张表。10G 里 10G 是模型，其余加起来不到 4M。

## 目录结构

```
~/.config/ivox/
├── model/          10G  ← 两个模型，iVox 的命，别动
├── voices/         1.7M ← 参考音频（每个音色一个 wav）
├── wechat/          28K ← 微信 agent 的工作区与会话
├── recordings/     136K ← 语音输入的录音临时文件
├── lastturn/       132K ← 「会话 → 最后一摞」对照表
├── pagebuf/          0  ← 攒整页正文的临时缓冲
├── integrations/    28K ← 分发前的 hook / pi 扩展素材源
├── signing/          4K ← 自签证书 + 私钥（备份，钥匙串重置后照它的 README 恢复）
├── *.log            日志与崩溃现场
├── *.sock           Unix socket
└── config.toml      配置（TOML，能写注释）
```

## 大头：模型（10G，别删）

| 模型 | 体积 | 谁在用 | 删了会怎样 |
|---|---|---|---|
| `Qwen3-TTS-12Hz-1.7B-Base-8bit` | 5.8G | **播报**（每次出声） | 播报彻底不能用 |
| `Qwen3-ASR-1.7B-8bit` | 4.6G | **语音输入**（按住右⌘说话） | 只有那个功能报错，其余照常 |

想省地方的话 4.6G 的 ASR 是唯一候选——前提是你不用语音输入。重装模型见仓库的
`scripts/download-models.sh`。

## 文件逐个说明

### 配置与素材

| 文件 | 谁写 | 能删吗 |
|---|---|---|
| `config.toml` | 你手改 / `ivox init-config` 生成 | ❌ 主配置，删了播报与音色全没 |
| `hook.sh` | `install-hooks.sh` 从 `integrations/` 铺过来 | ❌ Claude 的播报 hook 入口 |
| `integrations/` | `make update` 时铺一次 | ⚠️ 删了下次 update 会补回来 |
| `signing/` | 我（一次性备好） | ⚠️ 删了钥匙串重置后就没法用同一张证书签名了（权限会再掉一次） |

### 改配置（`config.toml`）

- 格式是 **TOML**：`#` 写注释，`[hotkeys]` 是段名，等号右边是值。文件里每一项旁边都有
  一句说明，照着改就行。
- **改完要 `ivox restart`** 才生效（只重启守护进程，不动登录自启开关）。
- 里面能改的：热键（含语音键，默认只右⌘）、语音输入、划词翻译服务与代理、字幕、
  音色（`sourceVoices.default` 是默认音色）、微信 token 与白名单。
- **改不了的**（在代码里）：Web 控制台的开关与端口（一直是 8888）、模型路径、合成参数、
  内置音色清单。
- 写错键名不会静默：`ivox status` 与 `daemon.log` 会点名「这个键没人认领」，
  还会猜你是不是想写别的名字。

### 运行时状态

| 文件 | 谁写 | 能删吗 | 说明 |
|---|---|---|---|
| `ivox.sock` | daemon 启动时 | ✅ 停了就能删 | 主 daemon 的 socket |
| `ivox-tts.sock` | 誊清员启动时 | ✅ 停了就能删 | 誊清员的 socket；崩了会留残file，下次 bind 时自动覆盖 |
| `lastturn/` | hook 每次 Stop | ✅ | 每个 Claude 会话一个 36 字节文件，记「这会话最后一摞是哪个」，给 Stop 反查用。**只在会话还活着时有用**，hook 里已加「超过 7 天的每次 Stop 顺手扫掉」 |
| `pagebuf/` | hook 攒整页正文 | ✅ | 正常情况是空的（有文件说明有一页没收完） |
| `recordings/` | 语音输入 | ✅ | **代码里写死只保留最近 2 个**，多的自动删。看到 2 个就是正常的 |
| `wechat/` | 微信 agent | ❌ | 删了微信 Agent 的历史会话就没了 |

### 日志（排障时看这里）

| 文件 | 谁写 | 说明 |
|---|---|---|
| `daemon.log` | daemon | 主日志，**超过 5M 自动轮转**成 `daemon.log.old` |
| `tts.log` | 誊清员进程 | 合成侧日志。跟 daemon.log 分家是有意的：出事时「哪个文件里有现场，就是哪个角色的错」 |
| `hook.log` | hook.sh | 每批增量的审计行（截前 40 字） |
| `crash.log` / `tts-crash.log` | CrashTrap | 崩溃现场（含调用栈）。当前 0 字节 = 近期没崩过 |
| `crash.count` / `tts-crash.count` | CrashTrap | 累计崩溃次数，各 1 字节 |

> 轮转：`daemon.log` 与 `hook.log` 都在 5M 阈值上把主文件改名成 `.old`（旧的被覆盖），
> `tts.log` 同样。`hook.log` 的这条是 2026-10-20 补上的——原先只有 `daemon.log` 有阈值，
> 它只增不减，用久了会涨到几百 M。

## 怎么把服务开起来

```bash
ivox on                    # 装回 LaunchAgent：登录自启 + 崩溃自动重启（日常用这条）
~/.local/bin/ivox serve    # 只在前台跑，关掉就没了（纯调试用，不自启）

ivox off                   # 停并卸掉 LaunchAgent
ivox restart               # 只重启守护进程（改完配置跑它，不动自启开关）
```

查状态：`ivox status`，或 `curl -s localhost:8888/health`。

**停不掉的时候**：`kill`/`pkill` 都不管用（SIGTERM 收信号不退），只有 `kill -9`。
而且拆成子进程后要杀两个：

```bash
pkill -9 -f 'ivox serve'
pkill -9 -f 'tts --serve'    # 誊清员，daemon 挂了它不会跟着死
```

## 排障入口

| 症状 | 先看哪 |
|---|---|
| 没声音 | `curl -s localhost:8888/health` 看 `engine` 字段；`daemon.log` 搜「合成失败」 |
| 某一摞没念完 | `daemon.log` 搜 `seq=`，再用同一个号去 `tts.log` 里对——三处日志都带它 |
| 播报断了但服务还在 | `daemon.log` 搜「已拉起誊清员」，看监督者有没有重启 |
| daemon 莫名重启 | `crash.log` 有栈；`crash.count` 是累计次数 |
| 麦克风/快捷键没反应 | 多半是 TCC 权限掉了，去系统设置重新勾「输入监控」「辅助功能」「麦克风」。**正常更新不会再掉**（用的是固定的自签证书，见 `signing/`）；换了证书才会 |
| 改了配置没生效 | 忘了 `ivox restart`（守护进程只在启动时读一遍配置） |
| 配置里的某项像是不起作用 | `ivox status` 会列出「没人认领」的键——多半是键名写错了 |
