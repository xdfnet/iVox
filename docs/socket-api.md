# iVox Socket 开发文档

其他程序通过 Unix Socket 调用 iVox 的 TTS 播报和 ASR 识别。
协议极简：文本头 + 可选二进制体，一行 `\n` 分隔。

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
| `source` | 否 | 来源标识，默认 `default` |
| `voice` | 否 | 音色 ID，默认按 `config.json` 中 `sourceVoices` 映射 |
| `group` | 否 | 分组号 = **一摞**（一次回复）：同一摞分多次发时带上同一个值（Claude 传 `turn_id`），服务端把它们并进**同一摞**；掀摞/掀桌时按它拦住"这一摞的后续批次"。**不必发结束标记**——下一条 `group` 到来时，服务端自动把上一个盖上 |
| `end` | 否 | 出现即表示**这是该分组的最后一批**，收尾该摞（段可前移）。漏发它这段会一直开着，直到下一个分组到来才被兜底收尾 |
| `now` | 否 | 出现即表示**现在就念**：掐掉在播的，这句插到队首立刻念，念完接着播原来的。**与 source 无关**——Opt+S 划词译文走的就是这条路；机器里它也是唯一一条被允许插队的内容，其余排队的一个不丢、且不立墓碑 |

**无响应**（fire-and-forget）

**`group` 用法**（Claude 的 MessageDisplay 走的就是这条：一次回复按行批分多次送来）
```bash
echo "{source:claude,group:turn-1}第一段" | nc -U ~/.config/ivox/ivox.sock
echo "{source:claude,group:turn-1}第二段" | nc -U ~/.config/ivox/ivox.sock
# 一次回复说完就完了——下一条 turn-2 到来时，服务端自动把 turn-1 这一摞盖上
echo "{source:claude,group:turn-2}下一轮" | nc -U ~/.config/ivox/ivox.sock
```
`group` 里不要出现 `,` 和 `:`（协议按这两个字符切分字段）。

**示例（bash）**
```bash
echo "{source:myapp,voice:taozi}任务完成" | nc -U ~/.config/ivox/ivox.sock
```

**示例（Swift）**
```swift
import Darwin

func speak(_ text: String, source: String? = nil, voice: String? = nil) {
    let prefix: String
    var parts: [String] = []
    if let s = source { parts.append("source:\(s)") }
    if let v = voice { parts.append("voice:\(v)") }
    prefix = parts.isEmpty ? "" : "{\(parts.joined(separator: ","))}"
    
    let msg = Data((prefix + text).utf8)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    // ... connect + write + close
}
```

### 1b. 流式 TTS — 边生成边播报（turn）

整轮回复边生成边投递，服务端在安全边界切句，第一句生成完即开播，不必等整轮。
一条连接多帧，连接保持打开。帧分两类：

**正文帧用自描述长度帧**（v3.6.2 起，pi 已采用）：

```
L<UTF-8 字节数 N>\n   ← 帧头：大写 L + 纯 ASCII 十进制字节数 + 换行
<恰好 N 字节的原文>    ← 帧体：可含任意字节（\n、{end}、代码、emoji），不再靠 \n 定界
```

**控制帧仍裸行**（以 `\n` 结尾）：

```
{type:stream,source:pi,turn:<唯一id>}   首帧：开流（声明来源/音色/轮次）
{page}                                   分页帧：一条 assistant 消息开始 = 一页
                                         （pi 每个 turn 恰好一条 assistant 消息）
{end}                                    结束帧：flush 残尾并结束该轮保活（允许空段前移）
{cancel} / {cancel:<turn>}               取消帧（用户中断）
```

客户端直接断开（EOF）等价于 `{end}`。

> **为何引入 L 帧**：旧协议正文帧靠 `\n` 定界、控制帧是裸 `{end}`，于是正文中独立成行的 `{end}`/`{cancel}` 会被误判成控制帧（协议注入），正文里的换行也和帧定界符混淆。L 帧按字节精确切，正文可含任意内容。服务端**向后兼容**：行首不是 `L<数字>` 的仍按旧裸文本帧解析（裸文本 + `\n`），旧客户端无需改造。

**关键约定**

- 客户端**只转发原文增量，不要自己切句/清洗**。切句（`splitSentences`）与降噪（`cleanText`）真源只在服务端：按句末/段落边界（`。！？!?…；;` 及换行；不含英文 `.`，以免切碎小数/缩写）、且保证吐出前缀的代码围栏（```` ``` ````）自身配平后才抽出整段清洗，避免念出 Markdown/代码残片。
- 过短句块（「好的。」「明白。」）不立即开播：服务端 `StreamBuffer` 有最小 flush 颗粒（`minFlushChars`=24 字），边界只标记、攒够长度才在最近边界一次吐出（常含多句）；残尾由 `{end}`/EOF 兜底全播。客户端无需关心，照常逐 delta 转发即可。
- `turn` 必填且一次连接内不变。**新 turn 不打断旧 turn**——按到达序排入独立段，播完前一段才接；同一 turn 的帧顺序追加。
- **`turn` 的边界是「用户的一次输入」，不是接入方的内部循环单元**。pi 里一次输入会拆成 N 个 turn（每个 turn 恰好一条 assistant 消息、工具调用就再来一轮），整摞回复都在同一个 run 内——所以那条连接要跨完整个 run（`agent_start` 开流 / `agent_end` 关流），中途用 `{page}` 帧分页。**踩过的坑**：早先按 pi 的 turn 开合连接，等于把一次输入切成 N 摞，Ctrl+1 掀一次只掀掉一页、后面几页照播（与「多摞被焊成一摞」那类事故是同一问题的两面：那边掀过头、这边掀不到）。
- turn 未收到 `{end}` 前，句间队列瞬时排空也不判收尾（不盖章）、不退管道，继续等下一批块。
- 服务端**保证同一连接内按帧序执行**（首帧 → 各正文帧 → `{end}`/`{cancel}`，内部用 `StreamOpChain` 串成一链）。顺序是协议语义的一部分：`{end}` 之后该 turn 不再有帧可关，若内部执行乱序（关闭先落地、迟到的同轮分块后落地并把轮次重新打开），整条管道会在分块播完后永久挂起（`/health` 恒 `playing=true`）。
- **优雅半关**：发 `{end}`/`{cancel}` 用 `sock.end(...)`（等内核发完再 FIN），不要 `destroy()` 强杀——后者随 RST 可能丢掉最后一两个字。

**示例（Node，pi 扩展即此实现）**

```js
import { createConnection } from "node:net";
const sock = createConnection(`${process.env.HOME}/.config/ivox/ivox.sock`);
sock.write(`{type:stream,source:pi,turn:${turnId}}\n`);
const body = Buffer.from(deltaText, "utf8");
sock.write(`L${body.length}\n`);   // 长度帧头
sock.write(body);                  // 正文（任意字节，无需转义）
sock.end("{end}\n");               // turn 结束，优雅半关
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
| `source` | 否 | 来源标识，默认 `default` |
| `voice` | 否 | 音色 ID，默认按 `config.json` 中 `sourceVoices` 映射 |

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
  "version": "3.6.1",
  "features": {
    "playback": "ok",
    "speechInput": "ok",
    "translation": "ok",
    "quickActions": "ok",
    "wechat": "ok",
    "mediaControl": "ok"
  },
  "permissions": {
    "microphone": "authorized",
    "deviceControl": true
  }
}
```

> `features` 对应六个能力域，彼此平级。`mediaControl` 就是那个 Web 控制台（打开 `http://<本机IP>:8888` 远程控制音乐），它的健康度即 Web 服务的健康度。

权限状态由 daemon 进程自查，反映 daemon 自身授权（非调用方终端）。`ivox status` 即此接口的中文渲染。

### 5. 打断三档 — 掐 + 掀

请求头，无 body：

```
{type:skip,mode:page}    # 掐 + 掀页（同 Ctrl+Esc）：掐断在播的，丢掉这一页剩下的块
{type:skip,mode:stack}   # 掐 + 掀摞（同 Ctrl+1）：掐断在播的，丢掉这一摞全部段并立墓碑拦后续增量
{type:skip,mode:all}     # 掐 + 全掀（同 Ctrl+2）：停当前 + 清空排队
```

无回复。`mode` 缺省按 `page`。**头的尾随 `\n` 是必需的路由依据**——没有它，服务端会把整条请求当传统整段播报体交给 `handleTTS`（`{type:stop}` 正踩在这条边界上：它现在发无换行裸串，走的就是 handleTTS 分支）。

给热键一个命令行对应物（`ivox skip --page` / `--stack` / `--all`），供自检脚本、压测、远程排查使用；热键路径本身不经过这里。三个 mode 落到的是 `PlaybackQueue.skipCurrentPage` / `skipCurrentBucket` / `cancelAll`，与热键完全同一条代码路径。三档都**只碰播报、不碰背景音乐**（音乐只归语音输入）。

> `{type:stop}` 停止帧（旧的 `ivox quiet`）已删除，服务端收到只记日志忽略——那一支保留作护栏，防止旧脚本发来的停止帧落进正文分支被念出来。

翻页的靶心是**资料室自编的页号**（`PlaybackPage.localID`），不依赖块上有没有 `pageID`
（Claude 的 `message_id`）。2026-10-18 改：早先这里写着「非 Claude 路径没有页号，
`mode:page` 会退化成只掐在播」——**这条已经作废**，页号一律由助理自编，
`ivox speak` 这类不带 `pageID` 的来源照样掀得掉整页，只是掀在同一摞内（它们通常一摞一页，
于是掀页与掀摞等价）。

### 6. 快速操作 — 五个快捷键的第二扇门

请求头，无 body，**无回复**：

```
{type:quick,action:terminal}    # 开终端（Opt+A）
{type:quick,action:claude}      # 开终端跑 claude（Opt+Z）
{type:quick,action:codex}       # 开终端跑 codex（Opt+X）
{type:quick,action:pi}          # 开终端跑 pi（Opt+Q）
{type:quick,action:copy-path}   # 复制 Finder 选中路径（Opt=C）
```

动作**由 daemon 执行**，不在客户端做——它们要摸主线程。CLI 侧 `ivox quick <action>`：
daemon 没在跑就**静默返回**（随手按的快捷键不该因为服务不在而报错）。
`copy-path` 会调 AppleScript，与合成并发时曾把 MLX 撞崩过（2026-10-18 实测两次
`mutex lock failed`）——有这条命令就能自动复现，不必手按热键。

> ⚠️ 这里的 `codex` 是**开终端跑 codex**（QuickActions 能力域），与播报链路无关；
> codex 的**播报**链路 2026-10-19 已整条删除。

### 7. 锁屏 / 解锁 — 走 HID 真键

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

### 8. CLI 工具

```bash
# TTS
ivox speak "你好"                          # 纯文本
ivox speak -s myapp -v mizai "hello"      # 指定来源和音色
ivox speak --now "打断先念这句"            # 插队：掐掉在播的、这句先念，念完接着播原来的（= {now:1}）

# ASR
ivox listen < 录音.wav                     # stdin
ivox listen -f 录音.wav                    # 文件
ivox listen -l en < english.wav           # 英文

# 打断三档（掐 + 掀；三个参数对应三个快捷键，缺省 --page）
ivox skip --page                           # 掀页（Ctrl+Esc）
ivox skip --stack                          # 掀摞（Ctrl+1）
ivox skip --all                            # 全掀（Ctrl+2）

# 快速操作（= {type:quick}，daemon 不在则静默返回）
ivox quick terminal                        # Opt+A
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
