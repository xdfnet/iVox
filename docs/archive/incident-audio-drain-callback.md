# AudioPlayer.drain 回调丢失问题修复记录

> 独立固化 2026-08-01 至 08-02 对 `AudioPlayer.drain` 回调丢失问题的完整解决方案。
> 对应代码：`Sources/iVox/Audio/AudioPlayer.swift`。播放队列状态机见 `docs/playback-queue.md`。

## 问题链路

一个根因 → 三个表现：

```
根因：AVAudioPlayerNode 的 buffer 完成回调在播放末尾偶发丢失
      （旧 API 是 .dataPlayedBack 语义，引擎 auto-shutdown 时回调永不触发）
          │
          ├─ 表现1：drain 永久挂起 → 播放队列卡死（最长 4 小时，8-01 实测）
          ├─ 表现2：cancel 后旧回调把计数减成负数（-772）→ 账目失真
          └─ 表现3：回调丢失但未挂起 → drain 超时 WARN（8-02 一天 11 次）
```

## 根因

`drain()` 依赖 `pendingCount` 归零才返回（AudioPlayer.swift），而 `pendingCount`
只在 buffer 完成回调里 `-= 1`。回调的触发时机由 `scheduleBuffer` 的 API 决定：

- **旧 API** `scheduleBuffer(_:completionHandler:)` 是 `.dataPlayedBack` 语义——
  buffer **真正播放完毕**才回调。播放到末尾时引擎因无可播音频 auto-shutdown，
  最后一批已调度 buffer 的回调**永不触发** → `pendingCount` 不归零。
- Apple 文档明确：`.dataPlayedBack` / `.dataRendered` 在 player stop、
  engine 停止、或未连输出设备时**可能永不触发**。

流式 TTS 把整段音频切成几百个 40ms 小 buffer 一次性全部调度到 node，
把「末尾丢回调」这个小概率事件放大成**每次播报都可能发生**、残留值可达数百。

## 三层解决方案

| 层 | 修复 | 解决的表现 | 机制 |
|----|------|-----------|------|
| **L1 · 超时兜底**（8-01） | `drain()` 加超时：`pendingFrames / sampleRate + 2s` 余量，超时强制返回并打 warn | 表现1 挂起卡死 | 回调全丢也最多等「预计时长+2s」就放行，队列永不堵死 |
| **L2 · 世代计数**（8-02） | `cancelPendingPlayback` 递增 `generation`；write 回调 `guard generation == gen` 丢弃旧回调 | 表现2 负数污染 | 取消后旧 buffer 的回调失效，`pendingCount` 不再被减成负数 |
| **L3 · 回调类型**（8-02） | `scheduleBuffer(buffer, completionCallbackType: .dataConsumed)` | 表现3 根因 | 数据被播放器**读出**即回调，不依赖引擎存活，从源头绕开 auto-shutdown 丢回调 |

### 代码位置

- L1：`AudioPlayer.drain()` 的 `deadline` 计算 + `asyncAfter` 超时分支
- L2：`AudioPlayer.generation` 属性、`write` 回调 guard、`cancelPendingPlayback` 递增
- L3：`AudioPlayer.write()` 的 `scheduleBuffer` 调用

## 三者关系

```
L3 从根上让回调不再丢（绝大多数场景）
   └─ 万一仍丢 → L1 兜底挡住，最多 WARN 不卡死
        └─ 取消场景 → L2 保证账目干净（无负数）
```

L3 治本，L1/L2 是双保险。三层各司其职，均保留。

**L3 的已知影响**：`.dataConsumed` 在 buffer 数据被读出（开始播放）时即回调，
drain 会比 `.dataPlayedBack` 提前最后一块 buffer 的播放时长（~40ms）返回。
node 串行播放保证下一段 buffer 自然排队衔接，**无截尾、无重叠**。

## 日志特征与识别

| 特征 | 含义 | 对应修复 |
|------|------|---------|
| `drain 超时强制返回（pendingCount=xxx）` WARN | 回调未及时归零，超时兜底放行 | L1 |
| `pendingCount` 为负（曾见 -772、-188） | cancel 后旧回调污染计数 | L2 |
| 超时日志紧跟 `TTS 播放完成`（同一毫秒） | 回调丢失发生在播放末尾 | L3 消除 |

识别技巧：grep 精确匹配 `[WARN] drain 超时`（不要匹配播报文本里出现的字样）。

## 当前状态

- ✅ `make build` + `make test`（34/34）通过
- ✅ 已部署生效（`make update`）
- ⏳ 验证中：部署后正常播报应不再出现 `drain 超时`，`pendingCount` 不再为负
- 📌 修复历史已同步至 `docs/playback-queue.md`（含本次 L2/L3）

## 维护约束

1. `scheduleBuffer` **必须带** `completionCallbackType: .dataConsumed`——
   改回旧 API（`.dataPlayedBack` 语义）会重新引入播放末尾丢回调。
2. `cancelPendingPlayback()` 必须递增 `generation`——write 回调靠
   `guard generation == gen` 丢弃旧回调；不要移除该 guard。
3. 不要绕过 `cancelPendingPlayback` 直接清零 `pendingCount`。
4. `drain()` 的超时兜底不要移除——它是回调丢失时队列不卡死的最后防线。

## 参考资料

- [AVAudioPlayerNodeCompletionCallbackType | Apple 文档](https://developer.apple.com/documentation/avfaudio/avaudioplayernodecompletioncallbacktype)
- [scheduleBuffer(_:at:options:completionCallbackType:completionHandler:) | Apple 文档](https://developer.apple.com/documentation/avfaudio/avaudioplayernode/schedulebuffer(_:at:options:completioncallbacktype:completionhandler:))
- [连续调度时 completion 回调不调用 | Stack Overflow](https://stackoverflow.com/questions/65077023/avaudioplayernode-completion-callbacks-not-called-for-files-scheduled-consecutiv)
- [AVAudioPlayerNode 的 scheduleBuffer 问题 | Apple Developer Forums](https://developer.apple.com/forums/thread/72875)
