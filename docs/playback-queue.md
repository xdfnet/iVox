# PlaybackQueue 状态机与场景矩阵

> ⚠️ **部分内容已过时**：下文围绕 `skipCurrent()` 与「↓ 键跳段」的状态矩阵，在改为「真人对话」打断模型后**该方法与 ↓ 键已整体删除**（打断只保留 right⌘ 开口说话的 `cancelAll()` 与新轮次 `bargeIn`）。媒体命令源头唯一、连续播放管道等原则仍有效；凡出现 ↓ / skipCurrent 的小节请视为历史记录。

> PlaybackQueue 是 iVox 的 TTS 播放调度核心（actor）。本文档固化其媒体控制的状态转移规则，防止后续修改重新引入 race。

## 核心原则：媒体命令源头唯一

`media.pause()` / `media.resume()` 命令只能从**两处**发出，其他路径一律不允许：

| 命令 | 发出位置 | 触发条件 |
|------|---------|---------|
| `media.pause()` | `processNext` 入口 | 每次管道启动 |
| `media.resume()` | `processNext` 退出且队列空（`jobs.isEmpty && gen==generation && !turnOpen`）| 自然完成 / ↓ 队列空分支 / daemon 退出 |

`catch CancellationError` 分支**不发**任何 media 命令（只清本地状态）。`media` 状态由 PlaybackQueue 统一管理，避免多分支并发发出命令造成 resume↔pause 竞态。

## 连续播放管道（常驻 node + 背压 + turn 保活）

> v3.6 改造，修复流式短句「一个字一个字蹦」。旧实现每个 job 独立 `generateStream → write → await drain()`，句间播空后重置 `needsPrime`、下一 job 重补 50ms 静音并重排调度——等于把连续语音流每句掐断。对照 ai-stack（Python `sounddevice.OutputStream` 常驻 + `queue(maxsize=16)` + 阻塞 write），改为一条跨 job 的常驻管道。

**AudioPlayer（`AudioPlayer.swift`）**

- 整条播报复用同一个 `AVAudioPlayerNode`，分块连续 `scheduleBuffer` 排队，设备从不在句间重启。
- **高低水位背压**：`pendingFrames`（已排队未被 `dataConsumed` 回调核减的帧数）超过高水位（4s 音频）时，`write()` 挂起生产者；降到低水位（2s）才经 `backpressureContinuation` 放行。生产者始终提前排队（当前句在播、下一句已合成），等价 sounddevice 阻塞 write。
- **prime 静音只在「设备真正播空（`pendingCount==0`）/ `cancelPendingPlayback`」后做一次**（`needsPrime`），连续排队的句间不再触发。
- **`drain()` 只在整条管道末端调用一次**（等跨 job 尾音播完），句间不再 drain。
- 取消链：`write()` 挂在背压上时，`cancelPendingPlayback()`/`stop()` 一定会 resume 它，生产者随即靠 `Task.checkCancellation` 退出，不会永久挂住。

**PlaybackQueue.processNext（`PlaybackQueue.swift`）**

- 跨所有 job 的 `while !Task.isCancelled` 循环，逐个 `synthesizeStream → for await pcm { await player.write(pcm) }`，**句间不 drain**。
- 队列瞬时排空时：`turnOpen == true`（流式轮次还在生成）→ 挂起在 `waitForJobs()`（continuation 存入 `jobWaiters`），**不退出、不恢复音乐**；`turnOpen == false` → 退出循环 → 末端 drain → 恢复音乐。
- `signalJobs()` resume 并清空所有 `jobWaiters`，调用点只有：`enqueue`（新 job 到达）、`endTurn`（轮次结束）、`bargeIn`（打断/取消）。三者覆盖了挂起的全部唤醒路径，无 continuation 泄漏。
- 轮次语义：`beginTurn/new turn` 打断旧轮；同 `turnID` 的分块顺序 append；普通 `ivox speak`/hook.sh（turnID=nil）作为新一轮打断当前在播。

## 状态机

```
                 ┌──────────────────────────────────────┐
                 │                                      │
                 ▼                                      │
   ┌─────────────────────┐    enqueue     ┌────────────────┐
   │   idle              │ ──────────────▶│  processing    │
   │ (jobs=[])           │                │ (jobs 累积中)   │
   │ (currentTask=nil)   │                │ (currentTask)  │
   │ media: 用户原始状态  │ ◀─────────────  └────────────────┘
   └─────────────────────┘   while 退出      │
        ▲                      + yield         │
        │                      + jobs 空       │ ↓ (jobs 非空)
        │                                      │
        │ skipCurrent                          │
        │ (jobs 空)                            │
        │ shutdown                             │
        └──────────────────────────────────────┘
                      media.resume()
```

## 场景矩阵

### 用户主动操作

| # | 场景 | 行为 | media 命令 | OK |
|---|------|------|-----------|----|
| 1 | 空闲 → enqueue | spawn processNext → pause → 播 | pause×1 | ✅ |
| 2 | 播放中 → enqueue | jobs 累积，while 自动取下一个 | 不发 | ✅ |
| 3 | 播放中 → ↓，队列非空 | 取消旧 task → spawn 新 → 播下一个 | pause×1（no-op） | ✅ |
| 4 | 播放中 → ↓，队列空 | 取消旧 task → resume music | resume×1 | ✅ |
| 5 | 空闲 → ↓ | `guard currentTask != nil` 拦截 | 不发 | ✅ |
| 6 | 播放中 → ⌘ 录音 | pause music + cancelAll TTS | pause×1（外部） | ✅ |
| 7 | 录音中 → ↓ | guard 拦截 | 不发 | ✅ |
| 8 | 录音中 → ⌘ | state guard 拦截 | 不发 | ✅ |
| 9 | ⌘ 松开 | resume music | resume×1（外部） | ✅ |
| 10 | daemon 退出 | cancel task + resume | resume×1 | ✅ |

### 内部状态转换

| # | 场景 | 行为 | media 命令 | OK |
|---|------|------|-----------|----|
| 11 | processNext 自然完成 | while 退出 → yield → 检查 jobs → resume | resume×1 | ✅ |
| 12 | processNext 被 ↓ 取消 | catch 分支只清本地状态 | 不发 | ✅ |
| 13 | TTS 合成失败 | catch error → 继续 while（直到成功或队列空） | 不发 | ✅ |
| 14 | 连续 ↓ 多次 | 每次都触发 skipCurrent | resume×0~1 | ✅ |
| 15 | processNext 退出 + 立刻 enqueue | yield 让 enqueue 插入 → 若 jobs 非空不 resume，由新 processNext 接管 | resume×0 / pause×1 | ✅ |

## 关键时序

### ↓ 按下（队列非空）

```
T0   processNext 播 job1，music 已暂停
T1   按 ↓
T2   skipCurrent: oldTask.cancel() + player.cancelPendingPlayback()
T3   _ = await oldTask?.value  ← 串行化点：旧 task 全部退出
T4   旧 task catch 分支：清本地状态、return（**不发 resume**）
T5   skipCurrent: jobs 不空 → 启动新 processNext
T6   新 processNext 入口 await media.pause()（no-op）
T7   新 processNext 播 job2
```

### ↓ 按下（队列空）

```
T0-T4  同上
T5   skipCurrent: jobs 空 → Task { await media.resume() }
T6   media 收到 play 命令 → music 恢复
```

### 自然完成 + 立刻 enqueue（场景 15）

```
T0   processNext while 退出（jobs 空）
T1   currentTask = nil
T2   await Task.yield()  ← 让 enqueue 有机会插入
T2.5 (可能的) enqueue 加新 job + spawn 新 processNext
T3   processNext 重新获得 actor：检查 jobs.isEmpty
       - false → 不 resume，新 processNext 入口 pause（接管）
       - true  → resume music
```

`Task.yield()` 是修复 race 的关键。它让 `enqueue` 在 `currentTask = nil` 之后、`media.resume` 之前有机会进入 actor，避免两个独立 Task 同时发 resume 和 pause。

## 修复历史

v2.7.0 期间发现并修复的 4 个问题：

| 问题 | 触发条件 | 修复 |
|------|---------|------|
| 媒体命令多源头竞态 | 旧 task catch 与新 processNext 入口同时发命令 | catch 分支不再发 resume，统一交给 skipCurrent / processNext 退出点 |
| 空闲按 ↓ 误发 resume | currentTask=nil 时仍走 resume 分支 | `skipCurrent` 加 `guard currentTask != nil` |
| daemon 退出 music 卡暂停 | shutdown 不发 resume | shutdown 末尾补 `Task { await media.resume() }` |
| 自然完成 + 立即 enqueue race | 老 resume 与新 pause 时序不可控 | processNext 退出前 `await Task.yield()`，yield 后再决策 |
| AudioPlayer.drain 永久挂起 | buffer 播放回调丢失（AudioEngine 被系统事件停止）→ `pendingCount` 永不归零 | `drain()` 加超时兜底：按本段已写帧数估算播放时长 + 2s 余量，超时强制返回并打 warn |
| cancel 后旧 buffer 回调污染计数 | skip/换段后旧世代回调触发 → `pendingCount` 减成负数（曾见 -772），drain 必走超时、账目失真 | `cancelPendingPlayback` 递增 `generation`，write 回调经 `guard generation == gen` 丢弃旧世代回调（v2.8.7） |
| 播放末尾 buffer 回调丢失（drain 超时） | `scheduleBuffer` 旧 API（无 `completionCallbackType`，`.dataPlayedBack` 语义）在引擎停止/auto-shutdown 时回调永不触发 → `pendingCount` 残留大值 | 改用 `completionCallbackType: .dataConsumed`，数据被读出即回调、不依赖引擎存活；drain 会提前最后一块 buffer 的播放时长返回，但 node 串行播放保证无缝衔接（v2.8.7） |

## 修复记录：AudioPlayer.drain 永久挂起（2026-08-01 修复）

> 已修复并移入上文「修复历史」表。保留分析过程备查。

### 现象

`processNext` 中 `await player.drain()` 永久不返回 → 播放队列被单个 job 卡死，后续请求全部排队，**只有按 ↓（跳到下一段）能解锁**。

### 日志证据（2026-08-01，daemon.log）

正常 vs 挂起（同为 22 字 test 文本）：

| 阶段 | 正常（14:11） | 挂起（16:07） |
|------|--------------|--------------|
| TTS 播放开始 | 14:11:17.248 | 16:07:16.111 |
| TTS 流式完成 | 14:11:18.883（42 chunk） | 16:07:17.797（43 chunk） |
| TTS 播放完成 | 14:11:20.815（+2s ✅） | 20:01:53.978（+4h，由 ↓ 触发） |

当天共 5 次挂起，均为 `source=test`：

```
test-52F1AC  14077.9s   ← 3.9 小时
test-60082B   5814.8s   ← 1.6 小时
test-7EB680   1099.8s   ← 18 分钟
test-65D2E4    129.2s
test-B53180     26.2s
```

挂起期间队列堆积到 `pending=14`，claude 播报最长延误约 4 小时（16:07:58 的播报 20:01:53 才播出）。

### 根因

`drain()` 依赖 `pendingCount` 归零（AudioPlayer.swift:60），而 `pendingCount` 只在 buffer 播放完成回调里 `-= 1`（AudioPlayer.swift:56-64）。一旦 node 中途处于非播放状态，**已排队的 buffer 完成回调全部丢失** → `pendingCount` 永不归零 → `drain()`（PlaybackQueue.swift:102）无超时地永久 await。

当天无 `AudioEngine 异常，尝试重建` 日志，排除 `ensureHealthy` 重建路径——属偶发回调丢失竞态。

### 影响

单个 job 卡死 → 整个播放队列阻塞。唯一解开路径是 `skipCurrent` → `cancelPendingPlayback()`（强制 `pendingCount = 0` 并 resume continuation）。

### 已实施修复

`drain()` 加超时兜底：按本段已写帧数 / 采样率 + 2s 余量计算超时，超时强制返回并打 warn（日志关键字 `drain 超时强制返回`）。回调丢失时队列仍能继续，不被单个 job 堵死。

### 维护约束

修复时注意：`cancelPendingPlayback()` 当前是唯一能解开挂起 drain 的路径（`node.stop` 会丢回调）；新增超时逻辑不要改变 `drain()` 在 `processNext` 中的调用语义（await 之后仍执行 `checkCancellation`）。

## 维护约束

修改 PlaybackQueue 时请遵守：

1. **不要在 `catch` 分支发任何 media 命令**——所有 `media.pause/resume` 都通过两个固定出口
2. **新增退出条件时只改 `processNext` 末尾的 `if jobs.isEmpty`**——决策点集中在一处
3. **新增触发点（如新快捷键）只走 `skipCurrent` 或 `cancelAll`**——不要直接 `currentTask?.cancel()`
4. **保持 `await oldTask?.value`**——这是串行化的线性化点，去掉会重新引入竞态
5. **`cancelPendingPlayback()` 会递增 `generation`**——write 回调经 `guard generation == gen` 丢弃旧世代回调；不要移除该 guard，也不要绕过 `cancelPendingPlayback` 直接清零 `pendingCount`，否则旧回调会把计数减成负数
6. **`scheduleBuffer` 必须带 `completionCallbackType: .dataConsumed`**——旧 API（不带 callbackType）是 `.dataPlayedBack` 语义，播放末尾引擎 auto-shutdown 时回调永不触发，会重新引入 drain 超时；`.dataConsumed` 在数据被读出即回调，不依赖引擎存活
7. **多条 job 一次性入队时走批量入口 `enqueue([PlaybackJob])`**——逐条 `await enqueue` 时，若两段之间队列瞬时为空，`processNext` 末尾的 `if jobs.isEmpty` 会提前 resume 音乐、下一段再 pause，表现为播报中音乐反复跳动（对应场景 15 的窗口）。批量入口先 append 完再启动处理，消除该窗口
8. **不要在 job 之间重新引入 `await player.drain()`**——句间接力靠 AudioPlayer 连续 `scheduleBuffer` 排队，逐句 drain 会播空设备、重补 prime、重启调度，重新引入逐字卡顿。drain 只允许出现在 `processNext` 末端一次
9. **新增 `waitForJobs()` 的唤醒出口时必须同步加到 `signalJobs()`**——turnOpen 下管道挂起在 `jobWaiters`，任何让它该醒来的事件（入队/结束/打断）都必须经过 `signalJobs`，否则 continuation 永久挂起
10. **背压水位（4s/2s）调整只改 `AudioPlayer` 的 `highWaterFrames/lowWaterFrames`**——高水位是内存上限也是合成预取上限（约 48kHz Int16 单声道 ≈ 384KB/4s），低水位须低于高水位以形成滞后区间，避免在阈值边缘反复挂起/放行