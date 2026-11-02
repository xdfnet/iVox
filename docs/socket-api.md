# iVox Socket 开发文档

其他程序通过 Unix Socket 调用 iVox 的 TTS 播报和 ASR 识别。
协议极简：文本头 + 可选二进制体，一行 `\n` 分隔。

> **播报的唯一入口是 `ivox speak`**（2026-11-02）：`ivox speak --source X [--voice Y] -- "<正文>"`
> 是客户端拼好的命令，它把这段请求发到这个 socket 上。**来源与音色是客户端的事**——
> 客户端自己读 `config.toml` 的 `[playback.sourceVoices]` 查音色、自己把 source 与 voice 带上；
> **服务端照单念，不猜、不管、不拒**（缺 voice 就走默认音色，缺 source 就按 `default` 记）。
> 曾经还有一路「流式连接」（长度帧 / `{end}` / `{cancel}`），随 pi 改走 `ivox speak` 一并删除。

## Socket 路径

```
~/.config/ivox/ivox.sock
```

## API 接口

### 1. TTS — 文本转语音

发送文本，iVox 播报。

```
请求（纯文本）:
  {source:myapp,voice:taozi}你好世界

或直接发送纯文本（使用默认音色）:
  你好世界
```

**参数**

| 字段 | 必填 | 说明 |
|------|------|------|
| `source` | **是**（`ivox speak` 在命令行上把关） | 来源标识（谁在说话）。**微信永不出声**（那个 claude 不挂钩子，回复压根不进队列），所以没有保留来源 |
| `voice` | 否 | 音色 ID。**客户端自己从 `config.toml` 的 `[playback.sourceVoices]` 取**（该来源自己的键，取不到退回 `default` 键），连同 source 一起发过来。**省了就走默认音色**（服务端用 `[playback.sourceVoices].default`）。服务端不猜：猜错的后果是整页用错音色念出来，而现场没人发现 |
| `now` | 否 | **必须写成 `key:value` 形式**（如 `now:1`；裸 `now` 不生效——字段按 `,` 切分再按第一个 `:` 拆成键值，只认成对的；值本身不校验）。表示**现在就念**：播报**暂停**（缓冲原样留着，一条不删），这句从**独立播放节点**出声，念完从原处接着播。**与 source 无关**——Opt+Z 划词译文走的就是这条路；它**不进队列**，所以队列顺序一点没变、其余排队的一个不丢 |

**无响应**（fire-and-forget）

**一次请求 = 一页**（一条 assistant 消息的全文）。服务端清洗、切句后入队为**一页**，
页与页之间**先来先进**，不分组、不排队次：

```bash
echo "{source:claude,voice:taozi}一整页的正文" | nc -U ~/.config/ivox/ivox.sock
```

> **source 与 voice 由客户端负责**（2026-11-02）：客户端说清「谁在说话」「用哪个音色」，
> 音色的真源仍是 `config.toml` 的 `[playback.sourceVoices]`，只是**读它的人从守护进程换成了客户端**
> （`hook.sh` 与 pi 扩展各自读）。
> **服务端不猜、不管、不拒**：`source` 缺了就按 `default` 记，`voice` 缺了就走默认音色——
> 它只是不得不有个缺省，不是它管的。

⚠️ 字段里不要出现 `,`（协议按它切分字段）。

**示例（bash）**
```bash
echo "{source:myapp,voice:taozi}任务完成" | nc -U ~/.config/ivox/ivox.sock
```

**示例（Swift）**
```swift
import Darwin

func speak(_ text: String, source: String, voice: String?) {
    // source 必填；voice 可省（省了服务端走默认音色）
    let prefix = voice.map { "{source:\(source),voice:\($0)}" } ?? "{source:\(source)}"
    
    let msg = Data((prefix + text).utf8)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    // ... connect + write + close
}
```

### 2. ASR — 语音识别

发送 WAV 音频，iVox 返回识别文本。

```
请求（头 + 二进制体）:
  {type:asr,lang:zh}\n<WAV 字节>

响应:
  识别结果\n
```

**参数**

| 字段 | 必填 | 说明 |
|------|------|------|
| `type` | 是 | 固定 `asr` |
| `lang` | 否 | 语言，`zh`/`en`，默认 `zh` |

**WAV 格式**：16kHz、16-bit PCM、mono、带 RIFF 头

**示例（bash）**
```bash
cat 录音.wav | { printf '{type:asr,lang:zh}\n'; cat -; } | nc -U ~/.config/ivox/ivox.sock
```

**示例（Swift）**
```swift
let header = "{type:asr,lang:zh}\n".data(using: .utf8)!
var payload = header
payload.append(wavData)

// connect → write(payload) → shutdown(SHUT_WR) → read → close
// 返回的字符串就是识别文本
```

### 3. TTS 合成回传 PCM — 合成但不播放

合成 TTS 并把 PCM 分块写回，供调用方自己播放（如 AEC 回声消除的参考信号）。不播放、不入队。

```
请求（头 + 文本体）:
  {type:tts,source:myapp,voice:taozi}\n<文本>

响应（分块帧，直到 end）:
  [4B 小端 UInt32 长度 N][N 字节 PCM]   ← 重复
  [0x00 0x00 0x00 0x00]                ← end
```

**参数**

| 字段 | 必填 | 说明 |
|------|------|------|
| `type` | 是 | 固定 `tts` |
| `source` | **是** | 来源标识（谁在说话） |
| `voice` | **是** | 音色 ID（同样由客户端从 `[playback.sourceVoices]` 取好带上；缺任一 → 请求被拒） |

**响应格式**：48kHz、16-bit PCM、mono，流式分块；文本为空或合成失败也以 `end` 帧结尾

> ⚠️ 发送后必须 `shutdown(SHUT_WR)`（或 close）触发服务器处理——服务器读到 EOF 才开始合成回传

**示例（Python）**
```python
import socket, struct
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect("/Users/admin/.config/ivox/ivox.sock")
s.sendall("{type:tts,source:myapp,voice:taozi}\n你好".encode())
s.shutdown(socket.SHUT_WR)          # 关键：half-close
data = b""
while c := s.recv(65536):
    data += c
frames, off = [], 0
while off + 4 <= len(data):
    (n,) = struct.unpack("<I", data[off:off+4]); off += 4
    if n == 0: break                 # end
    frames.append(data[off:off+n]); off += n
pcm = b"".join(frames)               # 48kHz Int16 mono 流式合成结果
```

### 4. 状态查询 — 功能健康与权限

请求头，无 body：

```
{type:status}
```

回复为 `DaemonStatus` JSON（字段语义：功能健康值 `ok` / `off` / `loading` / `error:<原因>`；麦克风 `authorized` / `denied` / `notDetermined` / `restricted`）：

```json
{
  "version": "6.0.0",
  "features": {
    "playback": "ok",
    "speechInput": "ok",
    "translation": "ok",
    "quickActions": "ok",
    "wechat": "ok",
    "mediaControl": "ok",
    "screen": "ok"
  },
  "permissions": {
    "microphone": "authorized",
    "deviceControl": true
  }
}
```

> `features` 对应**七个**能力域，彼此平级（`screen` = 屏幕锁那套 Web 滑块）。`mediaControl` 就是那个 Web 控制台（打开 `http://<本机IP>:8888` 远程控制音乐），它的健康度即 Web 服务的健康度。

权限状态由 daemon 进程自查，反映 daemon 自身授权（非调用方终端）。`ivox status` 即此接口的中文渲染。

### 5. 打断两档 — 掐 + 掀

请求头，无 body：

```
{type:skip,mode:page,by:ivox-skip}    # 掐 + 掀页（同 Ctrl+1）：掐断在播的，丢掉正在听的那一页剩下的内容
{type:skip,mode:all,by:ivox-skip}     # 掐 + 全掀（同 Ctrl+2）：停当前 + 清空排队
```

另有一个可选字段 `tag`（自报标签，会打进打断归因的日志），如 `{type:skip,mode:page,by:ivox-skip,tag:selftest}`。

无回复。`mode` 缺省按 `page`。**头的尾随 `\n` 是必需的路由依据**——没有它，服务端会把整条请求当传统整段播报体交给 `handleTTS`。

**`by`：请求方自报的身份**（可选，缺省记「未署名」），记进打断归因（`全掀·请求方 ivox-skip`）——「谁打断的」要答得出来，就得有个人报名。**为什么不查内核里的对端 pid**：`ivox skip` 这种发完就退的短命进程，等服务端读到帧时它早没了（实测 `getsockopt(LOCAL_PEERPID)` 返回 -1），查出来是残值更糟。自报是唯一稳的渠道。

给热键一个命令行对应物（`ivox skip --page` / `--all`），供自检脚本、压测、远程排查使用；热键路径本身不经过这里。两个 mode 落到的是 `PlaybackQueue.skipCurrentPage` / `cancelAll`，与热键完全同一条代码路径。两档都**只碰播报、不碰背景音乐**（音乐只归语音输入）。

> `{type:stop}` 停止帧（旧的 `ivox quiet`）已删除，服务端收到只记日志忽略——那一支保留作护栏，防止旧脚本发来的停止帧落进正文分支被念出来。

掀页的靶心是**资料室自编的页号**（`PlaybackPage.localID`）：掀页总是掀得掉，
不依赖来源给不给外部编号。2026-11-02 起队列里只有页，页号自编，掀页掀得干净。
全掀**不留墓碑**：这一下之后再来的内容照常入队照常播。

### 6. 播报总开关 — 单独关掉播报

请求头，无 body，**无回复**：

```
{type:playback,enabled:1}    # 打开播报
{type:playback,enabled:0}    # 关掉播报
```

关掉之后：正在念的立刻闭嘴、排队的全清空、之后进来的内容一律丢弃（不留着等开回来）；
**其余能力照常**（热键、划词翻译、微信、Web 控制台）——这与 `ivox off`（停整个守护进程）
是两件事。

**顺带把 TTS 模型释放掉**：关播报时模型（远程引擎那几 G 显存）一并收回——播报是 TTS
唯一的用途，播报关了模型就没有存在理由。开着播报但守护进程启动时 `playback.enabled`
本来就是 false 的，**启动时就不加载模型**（省下整个启动期的显存）。

释放的是**内存，不是能力**：之后真有人要合成（别的入口直连 `{type:tts}`），引擎会按需把
模型加载回来。`ivox playback on` 同理——模型重新驻留（后台加载，不挡着开关返回）。

CLI 侧 `ivox playback on|off`：它先改 config.toml 的 `playback.enabled`（**配置是真源**，
重启后仍然照它走），再发这一帧让运行时立刻生效。

### 7. 快速操作 — 五个快捷键的第二扇门

请求头，无 body，**无回复**：

```
{type:quick,action:terminal}    # 开终端（Opt+Q）
{type:quick,action:claude}      # 开终端跑 claude（Opt+A）
{type:quick,action:codex}       # 开终端跑 codex（Opt+X）
{type:quick,action:pi}          # 开终端跑 pi（Opt+S）
{type:quick,action:copy-path}   # 复制 Finder 选中路径（Opt=C）
```

动作**由 daemon 执行**，不在客户端做——它们要摸主线程。CLI 侧 `ivox quick <action>`：
daemon 没在跑就**静默返回**（随手按的快捷键不该因为服务不在而报错）。
`copy-path` 会调 AppleScript，与合成并发时曾把 MLX 撞崩过（2026-10-18 实测两次
`mutex lock failed`）——有这条命令就能自动复现，不必手按热键。

> ⚠️ 这里的 `codex` 是**开终端跑 codex**（QuickActions 能力域），与播报链路无关；
> codex 的**播报**链路 2026-10-19 已整条删除。

### 8. 锁屏 / 解锁 — 走 HID 真键

请求头，无 body，**有回复**（这两件事是「开门」动作，失败必须让人知道）：

```
{type:lock}\n      # 锁屏（Ctrl+Cmd+Q）
{type:unlock}\n    # 解锁：唤醒屏幕 → 输密码 → 回车
```

回复一行 JSON：

```json
{"result":"ok"}
{"result":"failed","error":"设备不可达（…）"}
```

**为什么必须走 HID 真键而不是合成键**：macOS 锁屏后**不把 CGEvent 合成键交给 loginwindow**——
合成键能锁屏，**醒不来**。所以锁屏与解锁都发真硬件事件（常驻 ESP32-S3 注入设备，
见 `HidInjector`）。

**覆盖范围**：只做「锁屏」这一种。**重启后的解锁不在范围内**——重启后要先进系统才有
daemon，daemon 没起来就发不出解锁键。解锁还要求系统**没睡眠**（睡眠了进程被冻结）。

密码是 AES-GCM 密文，写死在 `ScreenControl.swift` 里，运行时解开。

### 9. CLI 工具

```bash
# TTS
ivox speak -s claude "你好"                # 来源必填；音色省了就走默认音色
ivox speak -s claude -v taozi "你好"       # 指定音色
ivox speak -s myapp -v mizai "hello"      # 换来源换音色
ivox speak -s claude -v taozi --now "打断先念这句"   # 插队：主节点只暂停、这句从独立节点念，念完接着播原来的（= {now:1}）

# ASR
ivox listen < 录音.wav                     # stdin
ivox listen -f 录音.wav                    # 文件
ivox listen -l en < english.wav           # 英文

# 打断两档（掐 + 掀；两个参数对应两个快捷键，缺省 --page）
ivox skip --page                           # 掀页（Ctrl+1）
ivox skip --all                            # 全掀（Ctrl+2）

# 快速操作（= {type:quick}，daemon 不在则静默返回）
ivox quick terminal                        # Opt+Q
ivox quick copy-path                       # Opt=C

# 锁屏 / 解锁（= {type:lock} / {type:unlock}；daemon 不在则报错）
ivox lock                               # 锁屏
ivox unlock                             # 解锁（唤醒 + 输密码 + 回车）

# 誊清员（一般由主进程 spawn，不用手敲）
ivox tts --serve                           # 起合成子进程，监听 ~/.config/ivox/ivox-tts.sock
```

**跨进程免责**：主进程与誊清员之间**不走本文件的接口**，走的是
`[4B 小端 UInt32 N][N 字节 PCM]` 的长度帧（`iVoxKit/StreamFrame`），带一个自己的 socket
`ivox-tts.sock`。本文件描述的是**跑腿的 → 主进程**这一段。

## 错误处理

- 守护进程未运行 → connect 失败，`ECONNREFUSED`
- ASR 识别失败 → 服务端日志记录，客户端 read 返回 0 字节（无响应）
- ASR 结果为空 → 返回空字符串 + `\n`
- TTS PCM 合成失败或文本为空 → 仍以 `end` 帧结束
- TTS PCM 中途客户端断开 → 服务端停止合成并关闭连接（`daemon.log` 记录 WARN）
- TTS 从不报错（fire-and-forget），有问题看 `~/.config/ivox/daemon.log`
