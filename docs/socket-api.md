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

**无响应**（fire-and-forget）

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
一条连接多帧，帧间以 `\n` 分隔，连接保持打开：

```
{type:stream,source:pi,turn:<唯一id>}\n     首帧：开流（声明来源/音色/轮次）
<增量原文片段>\n                              后续帧：一帧一段 text_delta 原文
<增量原文片段>\n                              （delta 内自带的换行也作为句末边界）
{end}\n                                       结束帧：flush 残尾并放开音乐保活
```

取消帧（用户中断）：`{cancel:<turn>}\n`（或 `{cancel}`）。客户端直接断开（EOF）等价于 `{end}`。

**关键约定**

- 客户端**只转发原文增量，不要自己切句/清洗**。切句（`splitSentences`）与降噪（`cleanText`）真源只在服务端：按句末/段落边界、且保证吐出前缀的代码围栏（```` ``` ````）自身配平后才抽出整段清洗，避免念出 Markdown/代码残片。
- `turn` 必填且一轮内不变。**新 turn 打断旧 turn**（取消旧轮在播+丢弃排队）；同一 turn 的帧顺序追加。
- turn 未收到 `{end}` 前，句间队列瞬时排空也不恢复音乐，避免反复 pause/resume。

**示例（Node，pi 扩展即此实现）**

```js
import { createConnection } from "node:net";
const sock = createConnection(`${process.env.HOME}/.config/ivox/ivox.sock`);
sock.write(`{type:stream,source:pi,turn:${turnId}}\n`);
sock.write(deltaText + "\n");   // 每个 text_delta 一帧
sock.write("{end}\n");          // turn 结束
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

回复为 `DaemonStatus` JSON（字段语义：功能健康值 `ok` / `off` / `error:<原因>`；麦克风 `authorized` / `denied` / `notDetermined` / `restricted`）：

```json
{
  "version": "3.2.0",
  "features": {
    "speechInput": "ok",
    "wechat": "ok",
    "mediaControl": "ok",
    "mediaHTTP": "ok"
  },
  "permissions": {
    "microphone": "authorized",
    "deviceControl": true
  }
}
```

权限状态由 daemon 进程自查，反映 daemon 自身授权（非调用方终端）。`ivox status` 即此接口的中文渲染。

### 5. CLI 工具

```bash
# TTS
ivox speak "你好"                          # 纯文本
ivox speak -s myapp -v mizai "hello"      # 指定来源和音色

# ASR
ivox listen < 录音.wav                     # stdin
ivox listen -f 录音.wav                    # 文件
ivox listen -l en < english.wav           # 英文
```

## 错误处理

- 守护进程未运行 → connect 失败，`ECONNREFUSED`
- ASR 识别失败 → 服务端日志记录，客户端 read 返回 0 字节（无响应）
- ASR 结果为空 → 返回空字符串 + `\n`
- TTS PCM 合成失败或文本为空 → 仍以 `end` 帧结束
- TTS PCM 中途客户端断开 → 服务端停止合成并关闭连接（`daemon.log` 记录 WARN）
- TTS 从不报错（fire-and-forget），有问题看 `~/.config/ivox/daemon.log`
