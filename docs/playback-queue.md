# PlaybackQueue 状态机与场景矩阵

> PlaybackQueue 是 iVox 的 TTS 播放调度核心（actor）。本文档固化其媒体控制的状态转移规则，防止后续修改重新引入 race。

## 核心原则：媒体命令源头唯一

`media.pause()` / `media.resume()` 命令只能从**两处**发出，其他路径一律不允许：

| 命令 | 发出位置 | 触发条件 |
|------|---------|---------|
| `media.pause()` | `processNext` 入口（line 69） | 每次播放开始 |
| `media.resume()` | `processNext` 退出且队列空（line 109）| 自然完成 / DEL 队列空分支 / daemon 退出 |

`catch CancellationError` 分支**不发**任何 media 命令（只清本地状态）。`media` 状态由 PlaybackQueue 统一管理，避免多分支并发发出命令造成 resume↔pause 竞态。

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
        │                      + jobs 空       │ DEL (jobs 非空)
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
| 3 | 播放中 → DEL，队列非空 | 取消旧 task → spawn 新 → 播下一个 | pause×1（no-op） | ✅ |
| 4 | 播放中 → DEL，队列空 | 取消旧 task → resume music | resume×1 | ✅ |
| 5 | 空闲 → DEL | `guard currentTask != nil` 拦截 | 不发 | ✅ |
| 6 | 播放中 → ⌘ 录音 | pause music + cancelAll TTS | pause×1（外部） | ✅ |
| 7 | 录音中 → DEL | guard 拦截 | 不发 | ✅ |
| 8 | 录音中 → ⌘ | state guard 拦截 | 不发 | ✅ |
| 9 | ⌘ 松开 | resume music | resume×1（外部） | ✅ |
| 10 | daemon 退出 | cancel task + resume | resume×1 | ✅ |

### 内部状态转换

| # | 场景 | 行为 | media 命令 | OK |
|---|------|------|-----------|----|
| 11 | processNext 自然完成 | while 退出 → yield → 检查 jobs → resume | resume×1 | ✅ |
| 12 | processNext 被 DEL 取消 | catch 分支只清本地状态 | 不发 | ✅ |
| 13 | TTS 合成失败 | catch error → 继续 while（直到成功或队列空） | 不发 | ✅ |
| 14 | 连续 DEL 多次 | 每次都触发 skipCurrent | resume×0~1 | ✅ |
| 15 | processNext 退出 + 立刻 enqueue | yield 让 enqueue 插入 → 若 jobs 非空不 resume，由新 processNext 接管 | resume×0 / pause×1 | ✅ |

## 关键时序

### DEL 按下（队列非空）

```
T0   processNext 播 job1，music 已暂停
T1   按 DEL
T2   skipCurrent: oldTask.cancel() + player.cancelPendingPlayback()
T3   _ = await oldTask?.value  ← 串行化点：旧 task 全部退出
T4   旧 task catch 分支：清本地状态、return（**不发 resume**）
T5   skipCurrent: jobs 不空 → 启动新 processNext
T6   新 processNext 入口 await media.pause()（no-op）
T7   新 processNext 播 job2
```

### DEL 按下（队列空）

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
| 空闲按 DEL 误发 resume | currentTask=nil 时仍走 resume 分支 | `skipCurrent` 加 `guard currentTask != nil` |
| daemon 退出 music 卡暂停 | shutdown 不发 resume | shutdown 末尾补 `Task { await media.resume() }` |
| 自然完成 + 立即 enqueue race | 老 resume 与新 pause 时序不可控 | processNext 退出前 `await Task.yield()`，yield 后再决策 |
| AudioPlayer.drain 永久挂起 | buffer 播放回调丢失（AudioEngine 被系统事件停止）→ `pendingCount` 永不归零 | `drain()` 加超时兜底：按本段已写帧数估算播放时长 + 2s 余量，超时强制返回并打 warn |

## 修复记录：AudioPlayer.drain 永久挂起（2026-08-01 修复）

> 已修复并移入上文「修复历史」表。保留分析过程备查。

### 现象

`processNext` 中 `await player.drain()` 永久不返回 → 播放队列被单个 job 卡死，后续请求全部排队，**只有按 ⌦（跳到下一个）能解锁**。

### 日志证据（2026-08-01，daemon.log）

正常 vs 挂起（同为 22 字 test 文本）：

| 阶段 | 正常（14:11） | 挂起（16:07） |
|------|--------------|--------------|
| TTS 播放开始 | 14:11:17.248 | 16:07:16.111 |
| TTS 流式完成 | 14:11:18.883（42 chunk） | 16:07:17.797（43 chunk） |
| TTS 播放完成 | 14:11:20.815（+2s ✅） | 20:01:53.978（+4h，由 ⌦ 触发） |

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