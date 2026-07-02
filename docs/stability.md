# 架构稳定性评估

> 2026-07-01 评估，基于当前代码快照

## 整体评级

**中等偏上，生产可用。** 个人 macOS 守护进程的标准水平，核心链路（Socket → TTS → 播放）稳定。

## 结构总览

```
Daemon (actor)
├── PlaybackQueue (actor)    ← 播放调度，线程安全
│   ├── TTSEngine (actor)    ← MLX GPU 推理
│   └── AudioPlayer          ← @unchecked Sendable，手动串行队列
├── WeChatPlatform (actor)   ← ilink 长轮询
├── SocketServer             ← Unix socket IPC
├── SpeechInputService       ← CGEvent 监听 + ASR
└── MediaHTTPServer          ← Web UI (port 8888)
```

## 稳固点

| 方面 | 说明 |
|------|------|
| **Actor 边界** | 各子系统独立 actor，无共享可变状态 |
| **daemon 生命周期** | init → run → cleanup 三段式，SIGINT/SIGTERM 优雅关闭 |
| **Unix socket IPC** | 行协议简单可靠，无网络依赖 |
| **WeChat 长轮询退避** | 指数退避 1s→30s，成功复位，超时链路完整 |
| **TTS 合成重试** | 失败自动重试（默认 3 次），有延迟间隔 |

## 已知薄弱点

### ASR 模型加载失败被静吞
```
try? await asrEngine.load()     ← 错误被吞
```
加载失败后录音会触发不可恢复错误。应改为 `try` 让外层 catch 捕获。

### WeChatClient URL 强制解包
```
URL(string: url)!               ← 配置填错直接闪退
```
`Config.validate()` 未校验 `wechat.baseURL` 合法性。

### handleASR 文件描述符竞态
Unix fd 传给异步 Task，Task 内部的 `defer { close(fd) }` 在 `handle(fd:)` 返回后执行——若 fd 已被新连接复用，会关闭错误的文件描述符。

### 退出不刷日志
`cleanup()` 末尾 `exit(0)` 直接终止进程，`Log.flush()` 未被调用，最后一波日志可能丢失。

### AudioPlayer 引擎恢复冻结
`reviveEngine()` 用 `Thread.sleep`（最多 3 秒）阻塞串行队列，期间无法处理新音频写入。

### WeChat 停止延迟
HTTP 长轮询 35s 超时，收到停止信号后需等当前请求完成才能真正退出。

## 记录

- 评估范围：v2.4.1 代码快照
- 上述薄弱点均为已知可接受风险，不影响日常使用
