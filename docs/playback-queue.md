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

## 维护约束

修改 PlaybackQueue 时请遵守：

1. **不要在 `catch` 分支发任何 media 命令**——所有 `media.pause/resume` 都通过两个固定出口
2. **新增退出条件时只改 `processNext` 末尾的 `if jobs.isEmpty`**——决策点集中在一处
3. **新增触发点（如新快捷键）只走 `skipCurrent` 或 `cancelAll`**——不要直接 `currentTask?.cancel()`
4. **保持 `await oldTask?.value`**——这是串行化的线性化点，去掉会重新引入竞态