# 播报队列历史修复清单（v2.7.0 ~ 2026-08）

> 从 `docs/playback/queue.md` 迁出（2026-10-17 分层整理）。本文是**历史台账**：
> 每条都是当时真踩过的坑，留着是为了别再犯；**当前代码怎么写见
> [`docs/playback/queue.md`](../playback/queue.md)**。
> 其中 drain 回调丢失那一类另有更完整的复盘：[incident-audio-drain-callback.md](incident-audio-drain-callback.md)。

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
