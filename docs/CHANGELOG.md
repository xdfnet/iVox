# iVox 开发日志

## Unreleased（下一版）

- **`ivox status` 补全「自动播报」并按能力分组** — 原来漏了最核心的 TTS 自动播报，且能力与配套子系统混排（语音输入 / 微信桥接 / 媒体控制 / Web UI / 划词翻译 / 快速操作）。现先列六项面向用户的能力，**媒体控制也是能力**（播报前暂停音乐、播完恢复，故紧跟自动播报）：自动播报 / 媒体控制 / 语音输入 / 划词翻译 / 快速操作 / 微信桥接；空一行再列真正的配套子系统 Web UI。`DaemonStatus.Features` 加 `playback`（TTS 模型就绪 → `ok`，未就绪 → `loading`），`health()` 认这个新状态显示「… 加载中」。README 功能表同步加「媒体控制」一行
- **QuickActions 落地：Finder/终端快捷（Opt+Z / Opt+A / Opt+Q / Opt+W / Opt+C）** — `QuickActions/QuickActionsService.swift`（能力域由飞哥定名，取自 macOS 官方术语「快速操作」）：`Opt+Z` 在 Finder 当前目录开终端；`Opt+A`/`Opt+Q`/`Opt+W` 开终端并执行 `claude`/`qwen`/`codex`；`Opt+C` 把选中项路径写进剪贴板。**控 Terminal 刻意不用 AppleScript `do script`**（那要 Terminal 的 Automation 授权，且 iDict 时代有双窗问题），改用 `open -a Terminal <dir>`，要跑命令就先写一个临时 `.command` 再 `open` 它；取 Finder 路径仍走 AppleScript（唯一需要 Automation 的点，面积很小）。选中项是**文件**时，开终端取它的**所在目录**、复制路径取**文件本身**
- **划词翻译第三步：键盘事件层抽取 + Cmd+D 接通** — 把 CGEvent tap 从 `SpeechInputService` 里抽成独立一层 `HotKey/GlobalKeyTap.swift`：它独占 tap 与专用 run loop，只按事件类型 / keyCode **路由**，不含业务判断；`SpeechInputService` 退化为纯语音消费者（右⌘/右⌃ 由它回调进来），`Daemon` 成为 tap 的所有者并把热键接给 `TranslationCoordinator`。一个 tap 服务多个消费者，不再"一堆不相干热键挤在语音服务里"。热键只精确匹配六个组合键（`modifierMask` 取四个标准修饰位做全等，因 `CGEventFlags` 没有 `deviceIndependentFlagsMask` 的对应常量），所以 Cmd+Shift+D、单独按 D、打字一律透传；`keyUp` 一律透传（若按 keyCode 宽松匹配 keyUp，会吞掉「单独按 D」的抬起而干扰打字）。tap 回调只做整数比较 + 立刻 offload。**实机踩到一个坑**：辅助功能权限足够建 tap，但普通键（keyDown）还要「输入监控」——缺它时表现为"右⌘ 语音照常、Cmd+D 毫无反应"且 tap 明明创建成功，故启动自检 `CGPreflightListenEventAccess()` 并在缺权限时打印引导。`ivox status` 增加「划词翻译」健康度。实机验证：选中英文按 Cmd+D → 取到 19 字 → 浮窗出译文并朗读。另：Finder/终端快捷（Opt+Z/A/Q/W/C）**从 `Translation/` 分离**成独立能力域 **QuickActions**（`QuickActions/QuickActionsService.swift`，取自 macOS 官方术语"快速操作"）——它虽然同为热键入口，但属于系统快捷而非翻译，`Daemon` 只按能力归属分派，两边逻辑不揉在一起
- **划词翻译第二步：结果浮窗 + 剪贴板链路** — daemon 侧新增 `Sources/iVox/Translation/`：`ClipboardReader`（模拟 Cmd+C 取选中文本，**加了 `changeCount` 校验**——iDict 只盲等 50ms，慢应用常来不及写入会读到上一次剪贴板内容，表现为"译文跟选中文本对不上"）、`KeyboardSimulator`（搬 iDict 的 Cmd+C 序列，去掉其自带权限检查）、`TranslationPanel`（鼠标旁浮窗：`NSPanel` + `nonactivatingPanel` + `level = .floating` + 跨 Space，内容用 `NSTextField` 按文本量尺寸、到点自动隐藏；**刻意不做**拖拽 / 点击外部关闭 / 文本选择——这三样都要 key window，当前无 `NSApplication` 事件循环的 daemon 形态给不了，替代是"再按一次覆盖 + 超时消失"）、`TranslationCoordinator`（把复制→翻译→浮窗→朗读串起来，连按只认第一次）。`PlaybackQueue` 新增**原子**入口 `speakUserInitiated()`：Cmd+D 念译文属于「用户开口」必须抢麦，而 hook 汇报只排队——两者语义由此彻底分开；不做 `cancelAll()` + `enqueue()` 两步拼（actor 可重入，中间会插进别的消息）。`ivox translate --selection` 可单独验证剪贴板链路（CLI 不弹窗：它执行完就退出，没有 run loop 让 NSPanel 存活）
- **划词翻译（iDict 并入 iVox）第一步：翻译层 + `ivox translate` 命令行** — 迁 `iDict/translationservice.swift` 的能力到 `Sources/iVoxKit/Translation/`：`TranslationService`（Google 主/备双通道容灾 + OpenAI 兼容，`actor` + 可注入 `URLSession`，parse 函数保持 static 供单测）、`TranslationConfig`（config.json 新增 `translation` section；**每个字段都有默认值，旧配置没有这个 section 也照常解码**）、`SelectionText`（选中文本清洗：去竖线噪声、把连续空白含换行折叠成单空格——iDict 原版用 `.whitespaces` 会保留中间换行）、`WindowPlacement`（浮窗锚定几何抽成纯函数，顺带修正 iDict 把鼠标「屏幕内坐标」与 `visibleFrame` 宽高混算的**副屏定位错误**）。新增 `ivox translate <text> [--json]` 子命令——**不依赖 daemon**，是整条链路的可验证接缝。**直连失败自动走兜底代理**（`translation.proxyURL`，如 `http://192.168.100.6:10808`）：国内直连 Google 超时是常态，故做"直连短超时探测（3s，见 `directProbeTimeoutSeconds`）→ 代理重试 → 记住「该走代理」"三层，首次约 7s、之后约 1s（原先是干等两轮完整超时，实测 43s）。新增 25 个单测（响应两种格式解析、空白折叠、浮窗定位含副屏原点、旧配置解码、空白代理视为未配、代理会话构造）
- **普通播报改为排队，打断权只属于「用户开口」** — 日志实锤：一条 868 字长回复刚入队 199ms，就被另一个后台会话的 84 字短回复整条掐掉（`TTS 合成已取消`），而用户全程没开口——两个 Claude 会话同时收尾时互相抢麦。根因是「无 turn 的普通播报」（`hook.sh <source>` / `ivox speak`）与「用户开口」共用了同一套打断语义（`buryAllTurns() + bargeIn()`）。但「你开口就打断」已经由 `hook.sh interrupt` 哨兵（提交瞬间 `cancelAll()`）与右⌘ 负责，回复到达时的播报**没必要**再抢一次——它多抢的每一次，都是把别人（另一个会话、pi 正在流式念的轮）的内容凭空掐掉。现改为：无 turn 的普通播报只 `append` + `signalJobs`（复用现有管道顺序播完），不再 `buryAllTurns`/`bargeIn`。打断权收敛到三处「用户开口」：右⌘、`hook.sh interrupt` 哨兵、pi/dsh 用户发言的新轮。实测两条接连的 `ivox speak` 现在都念完（取消 0 / 完成 2），哨兵仍能立刻作废在跑的流式轮
- **`hook.sh stop` 参数改名 `interrupt`（与 Stop 事件同名、含义还相反）** — `hook.sh` 的两种模式里，`stop` 这个**参数名**与 **Stop 事件名**撞车：叫 `stop` 的参数挂在 **UserPromptSubmit**、干的是「提交即打断」；而真正处理 `Stop` 事件的，恰恰是**不带** stop 的 `hook.sh <source>`（回复完成念新回复）。名字、事件、挂载点三者全对不上，看到 `hook.sh stop` 几乎必然读成 Stop hook。现统一改叫 `interrupt`：`hook.sh` **保留 `stop` 分支做兼容**（漏改的环境若把 `stop` 当成**来源**，会走普通路径把用户打的 prompt 当回复念出来），`install-hooks.sh` 发现旧配置就地把 `hook.sh stop` 改写为 `hook.sh interrupt`（已挂 `interrupt` 则跳过，都没有才新增）。文档（architecture / hook-chain）同步
- **打断统一为一个语义：你开口 → 全场闭嘴（不再分两档）** — 此前「用户开口」有两条路、两档手劲：右⌘ 走 `cancelAll(dropsTurn: true)`（停当场 + 作废整轮），而 `hook.sh stop`（UserPromptSubmit）/ `ivox quiet` 发的 `__IVOX_STOP_PLAYBACK__` 哨兵走 `cancelAll(dropsTurn: false)`（**只停当场**）——于是你在 Claude/Codex 里提交 prompt 时，当场是静音了，但 pi/dsh 手里**正在生成的那一轮**还活着，下一句生成出来照样开口，「我说话电脑就不说了」并不成立。`false` 当初是替 pi 留的：pi 在 `message_start` 里自己发哨兵，且**紧接着就开自己的新轮**（独立短连 + 新流连接并行送达，作废轮次会把刚到的新轮也当「之前的」一起掐成哑巴，实测踩过）。但 pi 那个也是「用户开口」、本就是同一个场景，不该是特例。现统一：`cancelAll()` 去掉 `dropsTurn` 参数，**一律** `buryAllTurns()` + `bargeIn()`，右⌘ 与哨兵语义完全一致。pi 侧删掉自己那条并行哨兵——清场它并不缺（`cancelTurn` 里服务端已 `bargeIn` 一次，新轮首帧 `beginTurn` 又清一次），并行消失，也就不再需要「为 pi 减轻哨兵」。哨兵只剩两个来源（`hook.sh stop` / `ivox quiet`），都是独立短连、不带自己的新轮，无并发之虞。黑盒自检里 E6 的原有前提（「哨兵不该作废在跑的轮」）被本次语义推翻，已改为「并行 `{cancel}` 不拖垮在跑的轮」（不再发哨兵），并新增 **E7「停止哨兵作废在跑的轮」** 覆盖新语义（黑盒全量本轮未跑，待下次回归）
- **修复流式连接内操作乱序导致的播放管道永久挂起（黑盒 A-tail / E3「未收尾」）** — `ConnectionHandler` 里 `{type:stream}` 首帧、每个入队块、`{end}`/`{cancel}` **各自一个 `Task {}`** 投递到 `PlaybackQueue`，落地顺序全凭调度器。实测 `{end}` 的 Task 抢在**同一连接**后一个入队 Task 之前执行：`endTurn` 已把轮次关闭（`turnOpen=0`），迟到的**同轮** `enqueue` 走同轮分支又把它重新打开，而此时再无帧可关它——分块全部播完后管道永久停在 `waitForJobs()`：`/health` 恒 `playing=true`、`queued=0`、无「播放收尾完成」，且**两把兜底都够不着**（背压看门狗要求 `pendingCount>0`，此刻已是 0；drain 还没轮到）。现场探针抓到的原始顺序 `enqueue(open=1) → endTurn(open=0) → enqueue(open=1)`，6s 后进入永久挂起；修复前 15 轮 A-tail 命中 2 次。新增 `StreamOpChain` 把四处操作串成一链（各自 await 前一个完成），**帧序 = 执行序**。修复后 A-tail 连跑 14 轮 + 全量套件×2 全部正常收尾
- **修复打断后旧音频继续念、新回复干等（pi「收到新消息，没打断」）** — 根因在 `AudioPlayer.write` 的世代守卫是「**进入时**才取世代」：`bargeIn` → `cancelPendingPlayback` 递增世代并唤醒卡在背压上的 writer，但旧管道 consumer 下一块 PCM 进来时**重新读到的已是新世代**，世代校验直接放行——旧轮已缓冲的 PCM 于是一路 `scheduleBuffer` 排进播放器（旧音频照念 = 「没打断」），管道还要等这些缓冲灌完才退（实测多灌 8.7s，线上那次 27s），期间新轮卡在 `awaitCurrentPipelineFinished` 出不来（= 「新消息半天不出声」）。`processNext` 的 consumer 增加**逐块 `pipelineSeq` 比对**：作废即 break，一块都不再灌。实测「哨兵 → 新轮开播」从 8.7s 降到 0.5s
- **修复蓝牙/设备断流把播放管道永久卡死（此后所有播报哑掉）** — 背压等待**只能**由 `onConsumed` 唤醒、`ensureHealthy()` 又只在进入等待**之前**检查：蓝牙音箱断流或设备被系统挂起时 CoreAudio 不再回调 `dataConsumed`，writer 就永久挂起——`/health` 恒 `playing=true`、队列空、日志停在「前导静音已调度」之后毫无下文，此后所有播报一律无声，只能靠一次打断解救（蓝牙输出下实测必现；`drain()` 早有同类兜底，背压等待却漏了）。`AudioPlayer` 新增**设备活性看门狗**（serialQueue 上 1s 一跳）：`pendingCount>0` 且连续 10s 无任何消费回调即判设备断流，重建引擎重新激活设备、按「已丢」清掉排队 buffer 计数（`node.stop()` 本就已把它们丢出节点）、唤醒全部等待者，让管道继续灌后续 PCM 或收尾退出。故障注入（让 `onConsumed` 永不触发）验证：管道仍必然收尾，不再永久卡死
- **修复停止哨兵打断丢恢复（音乐永久卡在暂停）** — `pumpOrResume()` 旧写法 `guard currentTask == nil else { return }`：外部停止哨兵（`hook.sh stop` / `ivox quiet` / pi 用户发言）恰落在旧管道**尚未退净**的窗口时直接返回，而被取消的管道按设计不自己恢复音乐（收尾条件里的 `!Task.isCancelled`）——两边都不恢复，音乐就此卡在暂停（黑盒自检的收尾断言会一路等到超时）。改为：管道仍在退出中且**已取消、无待播**时先 `awaitCurrentPipelineFinished()` 等它退净再补恢复（正常收尾的管道自己会恢复，不抢）。播报中途连发 4 次哨兵实测 4/4 恢复
- **黑盒自检把「外部停止哨兵」也算作干扰** — 别的会话的 `hook.sh stop` / `ivox quiet`（或 pi 用户发言）会在用例播到一半掐掉本轮，尾音/收尾/恢复类断言必然失真。与既有的「外部播报」检测同等处理：窗口内出现「收到停止播放指令」即把失败降级为 skip 并打出证据来源，不当产品缺陷（跑测时已实际撞到：一次假红正是别的会话的哨兵所致）

- **修复 pi 整轮没声音（新轮开流与停止哨兵并行）** — pi 一个用户消息会开两条流、其中一条刚开就被 `{cancel}`，紧接着再来 `__IVOX_STOP_PLAYBACK__`；而真正承载正文的是**先开的那条**。旧实现用「见过 = 被顶掉」的登记表判迟到帧，于是这条在跑的轮被判成过期旧轮，其后续正文（含 `{end}`）**全部静默丢弃**——日志里只有「流式入队」没有「队列状态」，整条回复一句不念。改为**轮次栈**：栈顶为当前属主，`{cancel}` 的轮出栈（它没有内容要保护，属主交还给被它顶掉的那一轮），被顶掉的轮留在栈里继续被判为过期；另设墓碑表记录已作废轮次（`{cancel}` / 语音打断 / 普通 speak 之后不再开口，含 EOF 兜底残尾）。`cancelAll` 只停播放、不动作废（当时由 `dropsTurn` 参数分档：语音打断作废整轮、哨兵只停播放）——**该分档已在上面「打断统一为一个语义」条目中取消**
- **新增播报黑盒自检 `make check-tts`** — 此前 79 条单测只覆盖 iVoxKit 纯逻辑，播报真正的故障面（PlaybackQueue/AudioPlayer/TTSEngine + socket 协议）只能靠手敲命令 + 人肉 grep 日志，无法回归。新增零依赖 Node 套件 `scripts/tts-check.mjs`（仅 `node:net/http/fs/child_process`，无 npm 依赖）：压真实 daemon，经 Unix socket 发流式帧、`GET /health` 探运行态、增量 tail `daemon.log`，11 个用例覆盖协议正确性（长度帧注入/旧裸文本兼容）、合成时长（`{type:tts}` 直接回 PCM，可精确算秒数，完全不碰音频设备）、轮次隔离、取消丢弃迟到帧、EOF 残尾 flush、**哨兵与新轮并行（E6，pi 复现）+ 带取消的并行空流**、密集打断压测、打断后活性、尾音不被掐（`needsAudio`，无设备自动 skip 并显式列出）。类 TAP 输出、失败附窗口内日志、给退出码；`--managed`/`-f <regex>`/`--strict` 可调；用例窗口内出现**外部播报**（别的 agent 的 Stop hook / 手动 speak 普通播报会 bargeIn 掉用例自己的轮次）时，失败降级为 skip 并列出来源，不当产品缺陷。**本轮由它抓到并在下面修掉了 5 个真 bug**。用法 `make check-tts`（发版前手动跑，不挂自动链）
- **修复打断窗口下的空数组崩溃（`removeFirst from empty`）** — 背压/预取门控挂起期间 `bargeIn` 会 `jobs.removeAll()`，producer 从门控返回后仍对空数组 `removeFirst()`，触发 `EXC_BREAKPOINT` 整个 daemon 崩溃。改为先 `guard let job = jobs.first`，弹出前再用 `jobs.first?.text == job.text` 校验队首仍是自己读到的那个 job（否则说明已被清空/顶替，跳过本轮）
- **修复流式轮次隔离：迟到帧不再被当成新轮念出来** — 根因是 `Task {}` 结构化外的子任务**不继承取消**：`beginTurn` 里 `cancel()` 根本停不住正在 MLX 里跑的 producer，它就带着旧 turn 的身份把新轮任务消费掉，旧轮残句照念。改为双闸门：①**轮次栈**（栈顶=当前属主）判定迟到帧——非栈顶的旧轮与已作废轮次的帧一律静默丢弃，绝不 `bargeIn`（否则旧轮反杀新轮）；②`pipelineSeq` 单调代号，bargeIn 递增即作废在途管道，producer/consumer 各自比对代号后立即退场。`currentTaskSeq` 保证只有代号仍指向自己时才允许清空/接管 `currentTask`，杜绝旧管道把新管道清掉
- **修复 drain 跨次误放行（尾音被提前掐）** — `drain()` 的超时兜底定时器闭包是裸的：上一次 drain 遗留的 `asyncAfter` 会在超时后落到**下一次** drain 的 continuation 上，提前放行导致尾音被切（实测 `drain 超时强制返回（pendingCount=28 尾音=1.12s）` 之后跟着播放收尾完成）。改为 `drainSeq` 自增序号，定时器只对发起它的那一次 drain 生效
- **补「有活没人干」收敛兜底 `pumpOrResume()`** — 轮次顶替时序可能留下「队列有 job 但没有管道在跑」的孤儿态（打断后新起管道的时机被 await 拖走），表现为播报挂起不恢复。`endTurn`/`cancelAll` 收尾统一走 `pumpOrResume()`：无管道且有 job 就补起管道，否则才恢复音乐
- **修复长时间空闲后首句开头的字被吞** — 系统音频电源管理会把空闲了一段（实测十几分钟）的 player node 挂起，原 50ms 前导静音太短、首个音频 chunk 仍被跳过。改为 200ms 静音，并在排缓冲前显式 `node.play()`（幂等）确保节点真正进入渲染
- **修复流式播报尾部丢字（内容没念完就恢复音乐）** — 两级流水线重构后，producer（合成）一结束就无条件 `consumer.cancel()`，但此刻 `AsyncStream` 里可能还缓冲着最后一句的多块 PCM；consumer 在下一块的 `Task.isCancelled` 处 `break`，尾音整块丢弃，`drain()` 只等到已 schedule 的部分，于是提前恢复音乐。改为：producer 正常结束靠流 `finish()` 让 consumer **自然排空缓冲后退出**，正常路径不再 cancel；只有整条任务真被 bargeIn 取消时才 cancel consumer 弃残余。实测同一段五句播报，合成完到恢复音乐的间隔从 2.8s（掐尾）变为 13.1s（完整播完）
- **修复密集打断时 MLX 并发崩溃 + 废句合成雪崩** — 重构引入的回归：bargeIn 后立刻起新管道，新旧 `generateStream` 并发砸同一非线程安全模型，触发 `Fatal error: expected a non-empty mlx_array vector.cpp:51`、整个 daemon 崩溃。`TTSEngine` 新增**单调世代串行闸门**（第 N 代须等第 N−1 代完全离开模型才进 MLX）+ **epoch 显式作废**（bargeIn 递增纪元并唤醒所有排队者，旧纪元排队者放行后立即抛 `CancellationError`、绝不进模型；不依赖 Swift 任务取消能否传播到 MLX 内部 Task）。0.2s×15 极密连打：0 崩溃，只有「恰好撞在推理中」的一句跑完，其余秒退
- **修复密集打断时 AudioPlayer continuation 泄漏** — 背压/预取门控各只有单一 continuation 槽，新旧管道的 writer/producer 短暂同场时后到者覆盖先到者，被覆盖者永不 resume（`SWIFT TASK CONTINUATION MISUSE ... leaked`）。单槽改为**等待者数组**（各自独立槽、唤醒全 resume）；`write` 增加**世代守卫**，背压醒来发现已被打断就直接退出、绝不碰 player node/prime（根除打断瞬间两次 prime 的 writer 竞态）。两轮暴力连打压测 0 泄漏
- **合成/播放拆两级流水线，根除句间卡顿** — 旧链路合成与 `write` 串行，`write` 的 4s 背压会连带阻塞下一句合成。拆为 producer（逐句合成，经 `awaitPrefetchCapacity` 高水位门控保持厚垫）/ consumer（只负责写设备，背压只阻塞自己）两条 Task，中间 `AsyncStream` 接 PCM；设备连续排队、句间零停顿
- **流式协议改自描述长度帧，杜绝控制帧注入** — 正文帧从「裸文本 + `\n` 定界」改为 `L<UTF-8 字节数>\n<N 字节原文>`，正文可含任意字节（换行、独立成行的 `{end}`、代码），不再可能把正文伪造成 `{end}`/`{cancel}` 控制帧；控制帧仍裸行。服务端三分流解析且**向后兼容**旧裸文本帧（行首非 `L<数字>` 走旧路径），pi/dsh 客户端同步升级
- **客户端优雅半关，修尾部丢字 + 中途静默掉线误判** — pi/dsh 发 `{end}`/`{cancel}` 从 `destroy()` 改为 `sock.end(...)`（等内核发完尾帧再 FIN，强杀随 RST 丢最后一两个字）；pi 扩展区分主动半关（`graceful`）与异常 close（守护进程重启/FIN），后者标记失活让 `agent_settled` 兜底整段重念，并用连接身份校验避免旧轮 close 污染新轮

- **排版 en-dash 归一为半角连字符** — swift-markdown 会把 `--` 智能替换成排版 en-dash（`–`，U+2013），TTS 听感无收益还引入非 ASCII 符号（`--verbose → –verbose`，听成「长划 verbose」）。`TextCleaner.removingEmoji` 非 ASCII 分支把 U+2013 归一为单个半角 `-`（与单词内单个连字符行为一致，`--verbose → -verbose`、`a--b → a-b`）；行内代码反引号内本就原样保留不受影响
- **全角波浪号 `～` 与半角 `~` 统一转空格** — 此前半角 `~`（非路径时）转空格、全角 `～` 却原样保留交给 TTS，两者行为不一致；现语气波浪号一律转空格（不发声、不粘连前后词，尾随随空白折叠 trim），`~/path` 仍按家目录路径替换成文件名。`嘿～在吗 → 嘿 在吗`
- **TTS 参考音频缓存** — 此前每次合成都重新读盘解码参考音频（4~10 秒 wav：`AVAudioFile` 读盘 → PCM 解码 → 重采样 → 建 MLXArray），流式逐句播报下同音色每句都白做一遍。`TTSEngine` 内新增按「路径#采样率 + 文件 mtime」为键的缓存，一次播报内复用同一份解析结果，切换音色各存一份（4 个音色内存占用可忽略）；`ivox voice add` 覆盖参考音频后 mtime 变化自动失效，模型重载采样率变化也不会错配。实测连续三句：首句「已缓存」、后两句「命中缓存」，首包稳定 ~200ms

## v3.6.1 — 2026-10-12

- **发布包自包含集成资产，install/upgrade 自动同步 hook/pi/dsh** — 此前 release tarball 里只有一个 `ivox` 二进制，`ivox upgrade` 与 `install-binary.sh`（curl|bash）只解包二进制，刷不到 `hook.sh`/pi 扩展/dsh 插件；老用户走这两条路径升级后集成仍是旧版（v3.6.0 的 UserPromptSubmit 对他们不生效），且首次 curl|bash 安装压根不装任何集成。现 tarball 在根保留 `ivox` 外整包带上 `integrations/`（含分发器），安装/升级定向解包到权威源 **`~/.config/ivox/integrations/`**，再由幂等分发器铺到各 agent 实际位置（hook.sh → `~/.config/ivox/hook.sh`、pi/dsh 插件、Claude/Codex/Qwen 的 Stop+UserPromptSubmit 挂载）；未安装的 agent 安全跳过。同步只在 `make update` / `ivox upgrade` / `install-binary.sh` 三个显式时机发生，守护进程不自动同步。新增 `make package` 目标固化「二进制 + integrations」打包；`install-hooks.sh` 按自身位置探测素材源（部署态在 `integrations/` 内用同级目录，源码态在 `scripts/` 用 `../integrations`）

## v3.6.0 — 2026-10-12

第二层逐句流式成熟与「真人对话」打断模型：pi/dsh 边生成边播报、打断只在你开口/新轮到达时发生。

借鉴 `~/iCode/ai-stack` 本地推理栈的体验与运维实践，五项改进：

### 新增

- **emoji 口语化** — `TextCleaner` 新增 `replacingEmojiSpeech`（清洗链 URL → 噪音 → emoji 口语化 → emoji 剔除）：高频 emoji 先替换成中文口语词（`👌`好的、`👍`赞、`✅`没问题、`🎉`太棒了、`🙏`谢谢、`🚀`起飞、`💡`提示 等约 35 个），未命中的仍照旧剔除。以 grapheme cluster 为粒度并先剥离肤色修饰（U+1F3FB–F3FF）/ VS16 / ZWJ，`👌🏽` 等任意肤色变体也能命中；替换不引入 ASCII 空格
- **`GET /health` 健康端点** — 媒体 HTTP 服务（默认 8888）新增只读探针，返回 `{"status","version","model","engine","queued","playing"}`。`MediaHTTPServer` 通过 `healthProvider` 闭包（`[weak self]`，对齐既有 `statusProvider` 模式）由 `Daemon` 注入运行态；`PlaybackQueue` 新增 `pendingCount`/`isProcessing` 只读访问器；新增 `HealthSnapshot` Sendable 快照类型。无需设备控制权限
- **`ivox upgrade` 自动升级命令** — 检查 GitHub 最新 release → 比对版本号（x.y.z 数值段比较）→ 选适配 macos-arm64 的 `.tar.gz` → 停守护进程 → 旧版备份为 `~/.local/bin/ivox.bak-<旧版本>` → 解包替换 → `chmod 755` + ad-hoc 重签 → 原本在运行则自动重启。已是最新直接退出；无适配包给明确报错；全程可从备份回滚
- **`ivox status` 配置体检** — 新增「配置」段（守护进程未运行也显示）：校验 TTS 模型目录（含 config.json + safetensors）、启用语音输入时校验 ASR 模型目录、逐个音色检查 `refAudio` 文件是否存在。只读、不改变启动期校验

- **pi 扩展逐句流式（第二层流式）** — 此前 pi 挂 `agent_settled`，要等模型把整轮写完才一次性投递，长回复首句延迟≈整轮生成时间。改为：扩展监听 `message_update`，只把 `text_delta` **原文**按帧（`\n` 分隔）经一条长连接转发（跳过 thinking/toolcall，文本块切换补换行）；服务端新增 `StreamBuffer`（iVoxKit，纯逻辑、带单测），在**安全边界**（句末/段落，且吐出前缀自身代码围栏配平）抽出完整前缀，复用既有 `cleanText → splitSentences` 切句入队，模型写下一句时上一句已在念。切句/清洗真源仍只在 Swift 一份，TS 侧绝不切句（否则破坏 Markdown AST 块末补句号与跨行规则）。协议新增 `{type:stream,turn:<id>}` 首帧 + `{end}`/`{cancel}`；`PlaybackJob` 加 `turnID`，`PlaybackQueue` 支持轮次打断（新 turn/普通 speak 打断旧轮，同 turn 顺序追加，turn 未结束句间不恢复音乐）。`agent_settled` 保留为整段兜底（老版本无增量事件 / socket 连不上），并用 `streamed` 标志去重；用户 Escape（`aborted`）发 `{cancel}` 丢弃未播内容。传统 `ivox speak`/hook.sh 无 turn，行为不变（作为新一轮可打断）。扩展另借鉴 ai-stack：`ctx.hasUI === false`（print/json/后台脚本）不播报；`message_start` 收到 **user** 消息时立即发 `{cancel}` + `__IVOX_STOP_PLAYBACK__` 打断旧轮再开新轮（不依赖 assistant `turn_start` 是否触发，用户中断后再发言不会冒出旧轮残句）。再修两处边界（对照 ai-stack 复查）：①收尾从 `message_end` 改到 **`turn_end`**——一次 turn 里工具调用会产生多条 assistant 消息和多个 `message_end`，原先每个都发 `{end}` 关流、后续 delta 又重开轮次，会打断/重复；现长连接贯穿整轮；②`message_update` 增加 `message.role === "assistant"` 守卫；③新增 `muted` 锁，用户 Escape（`aborted`）后本 turn 残余 delta 不再续念，下一轮 `turn_start`/用户发言解除。**分号升级为句末边界**（借鉴 ai-stack 的 `SENT_END`）：`；;` 从 `splitSentences` 的软断点提升为句末终止符、并加入 `StreamBuffer` 的 flush 边界——分号隔开的是相对完整的并列小分句，提前切可让罗列型长回复（「修了 X；优化了 Y；补了 Z」）在第一个分号即开播，不必攒到句号；两层同步修改保持流式/整段停顿一致，短并列未超 80 字仍合并不碎念。英文句号 `.` 维持不切（避免切碎小数/缩写）。**修复流式「一个字一个字蹦」（根因：播放机制，非合成开销）**：对照 ai-stack（Python `sounddevice.OutputStream` 常驻、生产者往 `queue(maxsize=16)` 灌、阻塞 write 背压，设备从不在句间重启），发现 iVox 旧链路每个分块 job 都「独立 `generateStream` → 写设备 → `await drain()` 等播空 → 下一 job」，且每次播空都重置 `needsPrime`、下一 job 重补 50ms 唤醒静音并重排调度——等于把一条连续语音流每句掐断，短句密集时听感就是逐字蹦。重构为**常驻连续播放管道**：`AudioPlayer` 整条播报（跨所有分块）复用同一个 `AVAudioPlayerNode`，分块 `scheduleBuffer` 连续排队、句间不再 `drain()`、prime 静音只在「设备真正播空 / 取消」后做一次；新增**高低水位背压**（已排队未播放音频 >4s 暂停合成、降到 2s 放行，`pendingFrames` 随 `dataConsumed` 回调实时核减），生产者始终提前排队（等价 sounddevice 阻塞 write + maxsize 队列），当前句在播时下一句合成已在进行，设备零停顿；`drain()` 只在整条管道末端调用一次等尾音播完。`PlaybackQueue.processNext` 改为跨 job 循环：`turnOpen` 下队列瞬时排空就挂起等下一批 job（`jobWaiters` 续体，入队/`endTurn`/打断时 `signalJobs` 恢复）而非退出，轮次结束排空后才收尾恢复音乐；取消/打断统一走 `cancelPendingPlayback`（generation 作废旧缓冲并恢复背压挂起点），↓ 跳过粒度、turn 打断语义不变。`StreamBuffer` 另加**最小 flush 颗粒** `minFlushChars`（默认 24 字）作为缓冲层补充：边界只标记、攒够长度才在最近边界一次吐出（常含多句），残尾由 `{end}`/`finish()` 兜底全播。顺带修 `cleanText` 既有的**冒号引导段伪句号**（「主要改动如下：」后接列表时块末补出「如下：。」）：`sentenceEnds` 纳入中英文冒号，冒号是「引出下文」不应当句末补句号（带回归测试）

- **dsh 插件升级为逐句流式（对齐 pi）** — 此前 dsh 只在 `agent/turn-stopping` 取整轮最终文本直投 hook.sh，「说完了才开始念」。逆向 app.asar 确认真增量只在 `agent/assistant-stream` 的 chunk frame（`assistant/message`/`attempt` 上的 `data.stream` 是该 step 的**累计**紧凑流，不能逐帧转发）。插件改为：订阅 `agent/assistant-stream`，只转发 `chunk.chunk.type === "text-delta"` 的增量（跳过 reasoning/tool-call），一 turn 一条长连接、按 `\n` 分帧发 `{type:stream,source:dsh}`，同 turn 内多 attempt（工具调用前后多段文本）复用连接、段间补换行，`frame.turn` 变化才开新流；`agent/turn-stopping` 发 `{end}` 收尾，子代理会话不转发。socket 连不上（守护进程未运行/旧版无流式协议）时退回原整段 hook.sh，已成功流式则不重复播报。首句延迟从「整轮生成时间」降到第一句边界。**修复 dsh 流式句间卡顿/碎块**：初版给每个 text-delta 都补了 `\n`，而服务端 `StreamBuffer` 把 `\n` 当段落 flush 边界，导致模型每吐一小片就被切成 18–25 字超短块；模型前 10 秒只出第一句时，播放器第一段播完、第二段尚未切出，产生约 2.3s 静音空档。改为与 pi 一致：同一 text block 内增量裸转发、不补任何字符，仅在 content index 切换/工具调用后新段开始时补一个 `\n`
- **打断模型改为「真人对话」：删掉任意键取消与 ↓ 跳段** — dsh 等 GUI 客户端里正常打字会被旧的全局「任意 keyDown 即取消 TTS」误杀播报（排查 dsh「没播报」时定位到的真凶，非流式问题）。收敛打断途径为两条符合直觉的路径：**按住 right⌘/right⌃ 开口说话**（「你一开口对方就停」，触发 `cancelAll`）与**新轮次入队自动 `bargeIn`**（新 turn / 无 turn 普通 speak）。`SpeechInputService` 事件 tap 从 `flagsChanged | keyDown` 收窄为只监听 `flagsChanged`，打字 / Esc / 方向键全部原样透传（Esc 仍只归 agent 取消生成，不再牵连朗读）；删除 `handleSkip()`、`handleSkipNext()` 及已成孤儿的 `PlaybackQueue.skipCurrent()`。`playback-queue.md` 围绕 ↓ 的状态矩阵标注为历史记录
- **提交即打断（UserPromptSubmit）+ `ivox quiet`** — 此前 hook 类工具（Claude/Codex/Qwen）只在 **Stop（AI 回复完成）** 时才触发 `speak`，于是打断发生在新回复到达时；你提交 prompt 后 AI 思考的几秒里，上一轮回复仍在念，不符合「你一开口对方就停」。现新增第二个钩子 **UserPromptSubmit → `hook.sh stop`**：你一提交、AI 还没开口就发 `__IVOX_STOP_PLAYBACK__` 打断旧播报，Stop 照常念新回复。新增 CLI 子命令 **`ivox quiet`**（停止当前及排队播报、不退出守护进程，daemon 未运行时静默成功，专供 hook 调用）；`hook.sh` 加 `stop` 模式（丢弃 payload、只打断不出声）；`install-hooks.sh` 的写配置函数参数化支持事件，给 Claude/Codex/Qwen 三处挂 UserPromptSubmit，与 ulanzi 等已有 hook 共存。pi/dsh 不重复挂（已在 `message_start` / 新 turn start 帧打断）。至此打断时机统一：**hook 类靠 UserPromptSubmit、pi/dsh 靠用户消息/新轮次、语音靠 right⌘**
  - **修复 UserPromptSubmit 实际不生效**：根因是升级链路缺陷——`make update`/`deploy-bin` 只换二进制，不刷新 `~/.config/ivox/hook.sh`；老环境配置已挂 `hook.sh stop`，但脚本本体是旧版（无 `stop` 分支），落到普通 speak 路径读不到文本静默退出。现 `deploy_bin` 每次覆盖 `integrations/hook.sh` 到配置目录（脚本挂载配置幂等、不动），升级即同步脚本本体
  - **修复旧轮残音反杀新轮（流式打断 race）**：dsh 开新轮时旧连接直接 `destroy()`（不发 `{cancel}`/`{end}`），旧连接读到 EOF 走兜底把 `StreamBuffer` 残尾按**旧 turnID** 再 enqueue 一次；旧实现 `enqueue` 发现 turnID 与当前轮不同就再 `bargeIn()`，会把刚开的新轮内容也清掉、并冒出旧轮半句。改为真人对话规则「你一开口对方就别说了」：`currentTurn` 一旦切到新轮，旧轮的迟到入队/`endTurn`/`cancelTurn`（含 EOF 残尾）全部静默 no-op，**不再 bargeIn**；新轮开口的唯一权威是 `beginTurn`/新 turnID 首次入队。客户端零改动
- **离线环境变量** — `serve`（守护进程）启动最早期设置 `HF_HUB_OFFLINE=1`、`TRANSFORMERS_OFFLINE=1`。模型本就走「本地目录含 config.json」分支不联网，此为防御性设置（惠及子进程与未来组件）
- **仓库布局：harness 适配层归拢到 `integrations/`** — 同类资产原先散在两处（pi 扩展混在 `scripts/ivox.ts` 工具脚本里，dsh 插件混在 Swift target 的 `Sources/iVox/Resources/dsh-plugin/`）。现统一到顶层 `integrations/`：`hook.sh`（claude/codex/qwen/dsh 共用 Stop hook）、`pi/ivox.ts`、`dsh/{ivox-tts.mjs,package.json}`。这些文件安装时由脚本 cp、运行时读 `~/.config/ivox/`，本就不进二进制 bundle，移出 `Resources/` 不影响打包（bundle 现只剩 assets/voices/Info.plist/配置模板）；`scripts/` 只留构建安装工具。同步更新 `runtime.sh`/`install-hooks.sh` 源路径与文档（git rename 保留历史）

## v3.5.0 — 2026-10-05

### 修复

- **代码块被整段朗读** — `visitCodeBlock` 从「保留内容」改为「跳过」。播报场景下把源码逐 token 念出来（`func loadRefAudio  path  String  throws -  MLXArray…`）既没有信息量、一段代码又能占掉几分钟，且与 README「跳过代码」的承诺相悖。`testCodeBlock` 原先锁的正是「保留代码」，同步反转为断言不朗读
- **文档承诺的噪音过滤只落地了 1 类** — `hook-chain.md` / `architecture.md` 列的路径、UUID、commit hash、ANSI、速度、ETA、箭头规则在 f1929a2「TextCleaner 只做 Markdown→纯文本」重构时被整体删掉，只剩 URL。本次补齐 `removingNoise`：ANSI、UUID、≥12 位 hex hash（要求含字母，纯数字长串保留）、JSON 对象（须同时含冒号+引号，支持嵌套）、传输速度、ETA；路径改为只保留文件名（`/Users/…/TextCleaner.swift` → `TextCleaner.swift`）；`→` 替换为「到」
- **噪音清洗顺序会导致规则失效** — 明确为 URL → 噪音 → emoji：路径规则若排在 URL 之前，链接会被砍成 `https:b` 残片；`removingEmoji` 若先执行，会把 `:` `/` `[` 换成空格导致正则失配
- **嵌套块补出重复句号** — `endBlock` 原先看 `output.last`，而它自己刚补过空格，于是 `ListItem` / `TableRow` 内含 `Paragraph` 时会补出「。 。」。改为取最后一个非空白字符判断
- **行内代码后缺分词空格** — `visitInlineCode` append 后未复位 `lastWasSpace`，尾部的 `appendSpace()` 变成空操作，`loadRefAudio之后` 被连读
- **中文相邻节点被硬插空格** — 文本节点边界原先无条件补空格，`**加粗**普通` 变 `加粗 普通`。改为只在**一侧是拉丁字母/数字**时补；表格单元格另加强制分隔（否则中文连读成「名称版本」）
- **英文句号被补出中文句号** — `sentenceEnds` 补入 `.` `;` `；` `…`，`finished.` 不再变 `finished.。`
- **连续半角空格未折叠** — `removingEmoji` 中 `v == 32` 走白名单分支被原样追加，连续空格漏了出去；改为空白统一折叠
- **短文本路径丢引号** — 半角 `"` `'` 加入白名单，短文本快捷路径不再把引号删成空格

### 新增

- **播报分块** — `splitSentences` 兑现了一直没被使用的 `maxChars`（默认 `PlaybackChunking.maxChars = 80`）：按句末标点切分、合并相邻短句到 ≤80 字、超长句在软标点处断开、纯标点并回上一句。`ConnectionHandler` 据此分块入队，「任意键 = 取消整条」与「↓ = 跳过当前这一段」终于有区别；`PlaybackQueue` 新增批量入口 `enqueue([PlaybackJob])`，避免分块之间音乐反复跳动

### 文档

- `hook-chain.md` 5.1/5.2、`architecture.md` 文本过滤章节按实现重写（此前描述的是 f1929a2 之前的旧实现）；`playback-queue.md` 补批量入队维护约束、修正 media 命令行号
- 修正「跳过」按键的文档错误：`README.md` / `architecture.md` / `playback-queue.md` 写的是 ⌦（Forward Delete）/ DEL，而实现自 637f551 起就是 `↓`（`0x7D`）。按 ⌦ 实际会落进「任意键 = 取消整条」分支，与文档描述的「跳到下一个」正好相反

## v3.4.0 — 2026-10-03

### 变更

- **微信 Agent 去 Node，Swift 原生直连 claude（占用 278 MB → 0）** — v3.3.0 的常驻 Agent 依赖 node sidecar + Agent SDK，`~/.config/ivox/bridge/` 占 278 MB（几乎全是 node_modules，桥逻辑仅 8 KB），并要求用户额外装 Node.js。实测确认 SDK 本质只是 spawn 原生 `claude` + stdio NDJSON 后，[ClaudeAskService.swift](../Sources/iVox/Network/ClaudeAskService.swift) 重写为 Swift 直接 spawn `claude`（`--input-format stream-json --output-format stream-json --verbose --dangerously-skip-permissions`，stdin 包层 `{type:"user",message}`，result 取文本 + session_id，FIFO 匹配）。删除 node sidecar、`bridge.messenger.mjs`、`install-bridge-sdk.sh`、Node.js 依赖；对外行为（常驻多轮、resume、`/new`、后台任务跨消息存活）保持不变。协议三大机制均经裸进程实测。

### 文档

- architecture.md「ClaudeAskService」章节改写为原生直连；README 删 Node 依赖、架构图更新；调研文档 [`research-native-bridge.md`](research-native-bridge.md) 状态改为已实施。

## v3.3.0 — 2026-10-03

### 新增

- **微信常驻 Claude Agent 桥（后台任务跨消息存活）** — 原方案每收到一条微信消息就拉起一次 `claude --print`，进程回复后立即退出：`--resume` 只能恢复对话历史，后台任务（dev server、测试 watch、长脚本）随进程结束被带走。改用官方 `@anthropic-ai/claude-agent-sdk` 起单进程常驻 node sidecar（`bridge.messenger.mjs`），底层 claude 全程不退出，agent 可随时读日志、继续操作。关键机制：`query()` 的 prompt 传入一个**永不关闭的异步消息队列**——传字符串会被 SDK 判为单轮、result 后主动关闭 stdin；各轮消息都 push 进同一队列。真机验证：第一条起后台 `sleep 300`，第二条在同一座 agent 查到「还在」，两轮 `session_id` 一致。
  - **桥与微信彻底解耦** — stdio NDJSON 协议无 `user` 字段（请求 `{id, text, cwd}`，事件 `{id, type, text?, session_id?}`），全局单个常驻 agent，谁都能调。工作目录固定为隔离目录 `~/.config/ivox/wechat/workspace`；桥与 SDK 部署在 `~/.config/ivox/bridge/`，由新增的 `scripts/install-bridge-sdk.sh` 安装（npmmirror 兜底）。闲置 30 分钟自动回收，下条消息用 `session_id` resume 恢复。
- **微信侧收敛为单用户** — 扫码只注册一个用户、重新扫码覆盖。`tokens` 字典改为单个 `userID` + `contextToken`，状态落盘由 `context_tokens.json`（复数）改为 `context_token.json`；白名单从「逗号多人 + `*` 通配」简化为精确匹配扫码注册的那一个；多用户 typing ticket 字典改为单张 ticket；`sendMessage` / `sendTyping` 去掉 userID 参数。
- **`/new` 开新会话** — 常驻会话的上下文会随轮次持续累积，微信发 `/new` 即关闭当前 agent、清掉桥记录的 `session_id` 指针（旧会话在 claude 侧仍保留，只是不再 resume），回「已开启新会话」；下条消息全新启动、上下文从零开始。该命令在桥层处理，与微信解耦，任何调用方都可用。

### 变更

- **常驻 Agent 权限改为最大** — `permissionMode` 从 `acceptEdits`（自动接受编辑、风险命令仍确认）改为 `bypassPermissions`（跳过所有权限检查，shell/联网/删除等全自动执行，无确认打断）。

### 文档

- architecture.md 新增「ClaudeAskService — 常驻 Claude Agent 桥」章节；微信章节同步单用户措辞。README 微信描述改为常驻 Claude Agent、架构图加桥、依赖加 Node.js 18+。

## v3.2.0 — 2026-10-02

### 修复
- **DSH 播报从未生效** — 旧实现「Stop 触发后回头读 `~/.dsh/sessions/**.zstd`」有两处硬伤：会话目录实际是 `session-<uuid>`，脚本按 `<uuid>` 拼路径必然 miss（文本恒空、静默退出）；且 dsh 内置桥接插件的 Stop payload 根本不含回复文本（claude-code 版无此字段、codex 版写死 `null`）。改为本地 cordis 插件在轮结束时直投文本，`hook.sh` 里整段 zstd/轮询逻辑删除
- **本地 dsh 插件会撞插件清单校验** — profile 根 `package.json` 有 `name` 无 `version`，插件清单校验向上命中它并抛错，导致每次请求（含 auto-review）在 prepare 阶段失败（`REQUEST_EXTENSION`）。修法：在 `plugins/package.json` 放匿名包（`{"private": true}`）
- **dsh 插件缺流式兜底** — 选取规则对齐 DSH 官方的 `AssistantOutputFold` / `finalAssistantOutput`：取最后一条**内容非空**的 `assistant/message`（判据是 `content.length > 0`，空消息不覆盖前一条），并补上原先缺失的第三档——若始终没有非空消息，退回 `assistant/attempt` / `assistant/message` 累积的流式文本。副作用：一轮以「只有 tool-call、无文本块」的消息收尾时不再回放上一段旁白，按官方语义就是「无文本输出」
- **长回复被静默截断** — `hook.sh` 的 `text[:5000]` 硬截断删除，长回答不再念一半就停。配套把 `daemon.log` 的两条 DEBUG 回显限制为前 2000 字（TTS 仍取全文），否则一条超长回复就会往日志里灌几十万字符并触发日志轮转
- **大 payload 可能被单次 `write` 丢弃** — `SocketClient.send` 原先只 `write` 一次并要求写满，一旦被截断就抛 `EIO`（而 `hook.sh` 把 stderr 吞了，表现为无声）。改为循环补齐；同时给客户端 fd 加 `SO_NOSIGPIPE`，daemon 中途退出时报 `EPIPE` 而不是被信号杀掉
- **PI 扩展同样有 5000 字截断，且只读第一个文本块** — `scripts/ivox.ts` 去掉 `slice(0, 5000)`；并把「取第一个 text 块」改为拼接该条消息的**全部** text 块（一条 assistant 消息可以在工具调用前后各带一段文本，原先后半段被静默丢掉）
- **PI 扩展升级后装不上去** — `install-hooks.sh` 的 PI 分支原先「已存在则跳过」，仓库里改了扩展也永远同步不到 `~/.pi/agent/extensions/`。改为无条件覆盖，与 dsh 插件分支一致
- **短文本无标点换行导致 TTS 连读** — 短回复（<80 字符、无 Markdown）走快捷路径时只 trim 首尾，内部换行行被 TTS 当空白吞掉，两句零停顿。新增换行归一化：换行处行末无停顿标点则补句号（中文「。」/ 英文 `.` 按行末字符区分），已有 `。！？!?：，；…—` 不重复补，换行换空格兼容英文单词
- **表格各行间平读** — 整张表只在末尾补一次句号，单元格间仅空格。改为每行结束补句号停顿
- **短文本 emoji / URL 漏过滤** — 快捷路径未过 emoji 和 URL（「😄」「https://…」原样进 TTS），补齐；同时修正处理顺序为**先删 URL 再清符号**，否则符号清理会删掉 URL 冒号导致链接漏删（旧顺序下 `https://` 残留成 `https//` 的老问题一并解决）

### 变更

- **`ivox on` 语义改为「确保按当前二进制运行」** — 已在运行时不再直接返回，而是先停旧进程、等其退出再重新拉起；未运行则直接启动。`ivox on` 改为直接复用 `restart`（先停后启的主逻辑收敛在 restart，此前 restart 是「先 off 再 on」，未运行时会因 off 报错而整体失败），两者行为完全等价、未运行也能正常拉起；命令说明文案同步更新

### 新增

- **支持 DeepSeek Harness 语音播报（插件直投）** — desktop profile 以 `- insert:` 挂载本地插件 `./plugins/ivox-tts.mjs`（`name` 以 `.` 开头时按 profile 目录解析，无需改 app.asar、无需 pnpm）；插件在 `session/event` 缓存候选消息（规则见 [`docs/dsh-tts.md`](dsh-tts.md#2-选取规则对齐-dsh-官方定义)），`agent/turn-stopping` 时 spawn `hook.sh dsh` 把原文写进 `last_assistant_message`。默认音色湾湾。详见 [`docs/dsh-tts.md`](dsh-tts.md)

### 文档

- **文档目录整理与命名规范** — 历史复盘/调研/过时文档（7 篇）挪入 `docs/archive/`，文件名加类型前缀（`incident-` 事故复盘、`guide-` 手册流程、`research-` 调研、`review-` 评估快照）；`api.md` 更名为 `socket-api.md`；新增 `docs/README.md` 索引
- **修正过时声明** — 文档中 Swift 6.3.2 统一更正为 6.4 开发快照（`2026-06-15-a`）；编译器崩溃措辞改为历史陈述；修正 architecture.md 中 Makefile 实际调用方式；安装脚本 URL 分支 `master` → `main`；修掉 README 配置说明的错误链接

## v3.1.0 — 2026-09-22

### 新增

- **语音输入屏幕状态浮窗** — 按住右 ⌘ 时屏幕底部居中显示药丸浮窗：22 根声波柱跟随真实音量跳动，状态依次为「聆听中… → 识别中… → 已粘贴」；空结果/失败显示橙色提示。基于 [OpenWritr](https://github.com/trsdn/OpenWritr) 的 NSPanel + SwiftUI TimelineView 实现（MIT 协议，已署名）

## v3.0.0 — 2026-09-17

### 修复

- **TTS 播放开头几个字听不见** — 空闲一段时间后首段播放出现此问题，根因是 macOS 电源管理让 audio engine 休眠，`node.play()` 返回成功但硬件未真正就绪，首个 buffer 被跳过。修复：每个播放段写入前调度 50ms 前导静音 buffer 唤醒 player node；`init()`、`cancelPendingPlayback()`、`ensureHealthy()` 三处 `node.play()` 后等待最多 50ms 确认 `isPlaying`

### 变更

- **支持 PI coding agent** — 新增 TypeScript 扩展 `ivox.ts`，订阅 `agent_settled` 事件播报最后一条 assistant message，默认音色 dayi（PI 音色）；通过 `install-hooks.sh` 自动安装到 `~/.pi/agent/extensions/`
- **彻底移除 launchd 自启** — 删除 LaunchAgent 机制（`com.user.ivox.plist`、`launchctl bootstrap/bootout`），服务改为手动控制：`ivox on`（nohup 拉起守护进程）/ `ivox off`（socket 停止信号）/ `ivox restart`
- **`ivox on` 重写** — nohup 脱离终端拉起 `ivox serve`，轮询 socket 就绪后返回；幂等（已在运行直接返回），启动前清理残留 socket
- **`ivox off` 重写** — 以 `__IVOX_STOP__` socket 信号为主路径（不再依赖 bootout），轮询确认进程退出
- **`AppPaths.launchdPlistPath` 移除** — iVoxKit 不再引用 launchd plist 路径
- **构建/安装脚本** — `runtime.sh` / `Makefile` / `install-binary.sh` 移除 launchd 注册；`make update` 改为 socket 存在时条件重启
- **本机清理** — 删除 `~/Library/LaunchAgents/com.user.ivox.plist`，`launchctl list` 已无 ivox 注册

### 验证

- `ivox on` → socket 就绪、进程运行（PID 63354）；`ivox off` → 进程退出；`ivox restart` → PID 轮换（63722）

### 依赖

- **mlx-audio-swift 更新** — 同步最新 main (`3f6b055` → `3e97855`，跨 32 commit / 3 个月)
  - **ASR 更准** — Qwen3-ASR mel frontend 改用 Slaney mel scale + periodic Hann 窗（[上游 PR #247](https://github.com/Blaizzy/mlx-audio-swift/pull/247)），对齐 HF 参考实现
  - **TTS 更快更省内存** — Qwen3 text attention 改走 `attentionWithCacheUpdate`，把 per-layer-invariant 输入 hoist 到循环外，长文本流式合成受益
  - **本地 patch 1 行** — 上游 main 引入的 BreezeTTS 2 调了不存在的 `GenerateParameters.seed`（[BreezeTTSModel.swift:186](.build/checkouts/mlx-audio-swift/Sources/MLXAudioTTS/Models/BreezeTTS/BreezeTTSModel.swift#L186)），删掉该参数不影响功能（我们不用 BreezeTTS）；下次 `swift package update` 会被上游修复覆盖
- 验证：`make test` 34/34 通过；`make update` release 编译 + 签名 + 部署 + 守护进程重启成功；`ivox speak "测试新引擎"` 烟测 TTS 流式 13 chunks / 1.3s 播完

### 新增

- **模型下载三级 fallback** — `scripts/download-models.sh` 优先 HuggingFace，失败后自动切换 `hf-mirror.com`（国内镜像），再次失败回退 ModelScope。HuggingFace 在国内经常 SSL 握手失败，新链路显著提升安装成功率
- **`scripts/fetch-mlx-submodules.sh`** — 新增 mlx-swift 子模块兜底脚本，使用 GitHub tarball API 把 `mlx` + `mlx-c` 预填到 `.build/checkouts/mlx-swift/Source/Cmlx/`，并 touch `.git` 占位文件让 git 跳过 submodule fetch。HTTP/2 截断场景下 `make build` 不再因子模块 clone 失败而中断
- **`make install` 网络层文档** — `docs/release.md` 增补：先 `xcodebuild -downloadComponent MetalToolchain`（首次需要 ~838MB），SwiftPM 走 `swift build --skip-update`，子模块走新脚本兜底

## v2.9.0 — 2026-08-04

### 新增

- **`ivox start` 命令** — 通过 `launchctl bootstrap` 启动守护进程；已在运行则提示"已运行"，plist 未安装则引导 `make launchd`；幂等（先清残留 job 再 bootstrap，job 已加载时 kickstart 兜底拉起）
- **`AppPaths.launchdPlistPath`** — 收敛 launchd plist 路径（`~/Library/LaunchAgents/com.user.ivox.plist`），供 start/stop 复用

### 修复

- **`ivox stop` 真正停止** — 原实现仅通过 socket 发 `__IVOX_STOP__` 让进程自退，因 launchd `KeepAlive: true` 秒拉新实例，等效于"重启"。现改为 `launchctl bootout` 移除 launchd job，进程退出后不再被拉起；bootout 失败（如 nohup 手动运行、job 未注册）时退回 socket 停止信号；bootout 后轮询等待 socket 消失（最多 5s），确认进程真正退出再返回
- **launchctl stderr 静默** — start/stop 内幂等的预清理 bootout 不再向终端泄漏 `Boot-out failed` 噪音

### 其他

- 子命令增至 11 个，`stop` / `start` / `restart` 语义对称（临时关闭 / 恢复启动 / 原地重启）

## v2.8.9 — 2026-08-03

### 修复

- **hook 静音 reflexio 后台学习文本泄漏** — reflexio（claude-smart）后台学习进程用 `claude -p` 子进程生成规则整合/学习决策文本，退出时触发同一 Stop hook，其未渲染的 assistant 文本被当成"最后一条回复"播报（用户听到屏幕外的英文 JSON 噪音）。reflexio 官方为内部调用设置 `CLAUDE_SMART_INTERNAL=1` 标记，hook.sh 现认领该标记，检测到即提前 `exit 0` 跳过播报（与 `IVOX_SKIP` 并列为两个静音开关）
- 新增 `docs/hook-tts-leak.md` 固化根因、四条 TTS 路径核查表与排查方法论

## v2.8.8 — 2026-08-02

### 修复

- **AudioPlayer.drain 回调丢失根治** — `scheduleBuffer` 原用旧 API（`.dataPlayedBack` 语义），播放末尾引擎 auto-shutdown 时完成回调永不触发，`pendingCount` 不归零，`drain()` 只能靠超时兜底强制返回（每段末尾丢尾/超时 WARN）。现改用 `completionCallbackType: .dataConsumed`（数据被播放器读出即回调，不依赖引擎存活），从根上消除回调丢失
- **取消后计数污染** — `cancelPendingPlayback()` 归零后旧 buffer 回调再 `-= 1` 把 `pendingCount` 减成负数（曾见 -772），drain 必走超时、账目失真。现递增 `generation` 使旧世代回调经 guard 丢弃，计数保持干净
- 新增 `docs/audio-player-drain.md` 固化问题与三层解决方案（超时兜底 / 世代计数 / `.dataConsumed`），`docs/playback-queue.md` 同步维护约束

## v2.8.7 — 2026-08-02

### 修复

- **语音输入事件线程生命周期** — `stop()` 原先用 `CFRunLoopGetCurrent()` 在调用线程的 runloop 上移除事件线程的 source，`CFRunLoopRun` 永不退出导致线程泄漏；权限轮询无退出条件，stop 后还会自动拉起新线程。现改为记录事件线程自己的 runloop、用 `CFRunLoopStop` 唤醒退出，轮询检查停止标志，事件 tap / runloop / 线程引用统一用队列保护（消除 TOCTOU），事件回调与 `eventTap!`/`refcon!` 强制解包一并清理
- **强制解包清理** — `WeChatClient` 4 处 `URL(string:)!` 与 `group.next()!` 改为 guard + 抛错；`TextCleaner` 的 `try! NSDataDetector` 改 `try?`，失败时降级返回原文
- **静默吞错** — `MediaController` 暂停/恢复失败、应用启动失败不再静默，记录日志并返回失败；`ClipboardInjector` Enter 事件创建失败改为抛错
- **socket 阻塞超时** — `SocketClient` 连接设置 10s 读写超时；`SocketServer` 对客户端连接设置 10s 读超时，坏客户端不关闭连接时读取不再无限挂起
- **命令退出码** — `ivox say`（守护进程未运行）、`ivox restart`（重启失败/未注册）、`ivox voice list`（配置加载失败）不再静默返回 0
- **硬编码路径集中** — 新增 `AppPaths`（HOME 未设时退回 `NSHomeDirectory`），7 处重复的 `~/.config/ivox/ivox.sock` 统一收敛，微信配置引导的二进制路径一并修正
- **输入校验** — `ivox listen` 语言参数只允许纯字母（防协议注入），stdin 改分块读取并限 100MB（防内存耗尽）；微信扫码 `qrKey` 补 URL 编码；ASR 语言码校验
- **StreamFrame 超大帧防护** — 声明帧超过 100MB 直接清空缓冲终止解析，防恶意流缓冲膨胀（新增 2 个单测）
- **socket 文件清理** — bind/listen 失败时 unlink 残留 socket 文件；`chmod` 提前到 listen 前执行
- **脚本健壮性** — `install-binary.sh` 按 CPU 架构（arm64/x86_64）精确选择 release 资产，避免下到不兼容二进制；`runtime.sh` bundle 缺失时输出明确警告

### 其他

- 清理编译 warning：`MediaHTTPServer` 多余 `await`、`WeChatClient` 非可选 `??`

## v2.8.6 — 2026-08-01

### 修复

- **hook 过滤过短纯西文确认** — Claude 会话工具间隙输出的 `true`/`ok`/`done` 等 ≤5 字符纯西文确认不再播报（hook.sh 提取时置空，跳过微信与 TTS）
- **AudioPlayer.drain 超时兜底** — `drain()` 依赖 buffer 播放回调归零 `pendingCount`，一旦 AudioEngine 被系统事件（设备切换/休眠等）停止，已排队 buffer 回调集体丢失导致 `pendingCount` 永不归零、播放队列被单个 job 永久阻塞（实测最长卡 3.9 小时，堆积 14 个请求）。现按本段已写帧数估算播放时长 + 2s 余量强制返回，日志关键字 `drain 超时强制返回`

## v2.8.5 — 2026-07-31

### 新功能

- **`type:tts` 合成返回 PCM 协议** — 发送 `{type:tts,source:…,voice:…}\n<文本>`,iVox 合成但不播放、不入队,流式分块返回 48kHz Int16 mono PCM(`[4B 小端长度][数据]` 帧,4 个 0 的 `end` 结尾),供调用方自己播放(如 iAgent AEC 回声消除的参考信号)。客户端断开时立即停止合成,释放 GPU

### 修复

- **麦克风权限描述缺失** — launchd plist 未声明 `NSMicrophoneUsageDescription`,通过 `-sectcreate` 嵌入 `__TEXT,__info_plist` 让 TCC 能找到用途描述,避免麦克风权限被拒

## v2.8.4 — 2026-07-31

### 新功能

- **`__IVOX_STOP_PLAYBACK__` 停止播放协议** — 通过 socket 发送该文本，立即取消当前及排队播放（不退出服务），供 iAgent 播报打断（Barge-In）使用

## v2.8.3 — 2026-07-26

### 修复

- **并发安全** — TTSEngine 多 waiter 共享数组替代单 continuation、失败时也 resume；AudioPlayer deinit 恢复 drainContinuation；MediaHTTPServer generation 防 stop/start 竞态；ClipboardInjector 串行队列防多线程竞态；SpeechInputService deinit 防悬空指针
- **注入防护** — hook.sh `--` 防参数注入、后台进程关 fd3；install-hooks.sh `jq --arg` 消除命令注入
- **脚本健壮性** — install-binary.sh heredoc 展开 `$HOME`、darwin asset 过滤；download-models.sh clone 前后 `rm -rf`；runtime.sh bootstrap 失败给明确提示、去无差别 `pkill`；Makefile sed/grep 兼容 Linux
- **WeChatPlatform** — session 过期时 `verifyToken()` 刷新替代死循环
- **SocketServer** — client socket 加 `SO_NOSIGPIPE`，防 SIGPIPE 杀 daemon
- **ASRClient** — `defer` 移到 `write` 之前，写失败也能清 temp file

## v2.8.2 — 2026-07-24

### 修复

- **语音输入后音乐恢复时序** — ⌘ 松开后立即 `media.resume()` 可能抢在 TTS 入队前恢复音乐，导致播报和音乐重叠。改为延迟 2 秒调用 `resumeIfIdle()`，仅在队列真正空闲时才恢复
- **processNext 竞态恢复音乐** — 旧一代的 `processNext` 在 yield 后判断 `jobs.isEmpty` 可能误恢复音乐，而此时新一代 task 已入队。引入 `generation` 计数，只有最新一代的 task 能执行 `media.resume()`

### 改进

- **`resumeIfIdle()`** — PlaybackQueue 新增安全恢复接口，外部（如语音输入）可在不确定队列状态时安全请求恢复音乐，仅在 `jobs.isEmpty && currentTask == nil` 时执行
- **切换到 Swift 6.4 工具链** — 之前因 `performSILProcessing` 栈溢出 bug 锁定在 6.3.2，该 bug 已在 `swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-06-15-a` 中修复。改用 `xcrun --toolchain swift-latest swift` 构建

## v2.8.1 — 2026-07-20

### 修复

- **PlaybackQueue peek + claim** — v2.8.0 的"catch 还回 job"修复在队列空时会重听当前段（DEL 被解读为"重听 A"）。改用 peek + claim 模式：队首 job 直到 `synthesizeStream` 拿到 stream 才 `removeFirst`，cancel 撞不上这条同步路径，catch 块不再动 `jobs`

## v2.8.0 — 2026-07-20

### 修复

- **AudioPlayer 自愈** — 写入前自检引擎状态，异常时自动 `reset() + start() + play()` 重建；之前会静默丢弃 PCM
- **TextCleaner 过滤统一** — 千分位逗号、ASCII hyphen 纳入白名单保留；Tab / NBSP / 全角空格等 Unicode 空白统一当空格合并；emoji 修饰符（含肤色）一并砍掉
- **PlaybackQueue race 修复** — DEL/取消时若 job 已被 `removeFirst` 取出但未开始播放，还回队首避免静默丢段

## v2.7.0 — 2026-07-15

### 新增

- **⌦ 快捷键** — 按 Forward Delete 跳过当前播报，直接播队列里下一个；队列空才停
- **`skipCurrent()`** — 新增 PlaybackQueue 异步方法：取消旧 task → await 退出 → 启动新 processNext 接队列，避免并发写 player

### 改进

- **FIFO 排队** — `enqueue()` 不再 `removeAll`，队列可累积多条任务按顺序播完
- **不打断正在播** — 去掉 `config.interruptCurrent` 强制切换逻辑，新任务入队不打断当前
- **processNext 改 while 循环** — 一次性消费队列里所有 jobs，播完再统一 `media.resume()`

## v2.6.0 — 2026-07-13

### 改进

- **AudioPipeline 精简** — 去掉 AudioPlayer 自动复活、TTSEngine 重试循环、PlaybackQueue 的 while/async let/defer，线性流程：暂停→播→恢复
- **打断逻辑修复** — `enqueue()` 打断时先 `cancelPendingPlayback()` 静音再启动新 Task，消除新旧音频重叠
- **取消不丢任务** — `try?` 改为 `try`，取消信号不会丢失导致任务漏播
- **Config 简化** — 去掉 `maxRetries`、`retryDelayMs`

### 工具

- **Makefile 精简** — 只保留 `make install` 和 `make update`，去掉 deploy/launchd/restart 中间目标

## v2.5.0 — 2026-07-09

### 改进

- **过滤逻辑重构** — TextCleaner 第二层改为白名单模式，只保留字母/数字/中文 + 语气标点（`。！？%`），其余符号全部过滤
- **断句逻辑移除** — 内容直接一段发给 TTS，不做句末标点切分
- **日志精简** — 核心业务 INFO，调试信息 DEBUG，移除重复/装饰性日志
- **媒体控制简化** — 移除远程控制分支，只保留本地 MPRemoteCommandCenter

## v2.4.3 — 2026-07-08

### 修复

- **drain 超时估算修正** — 分句播报时偶尔出现约 30 秒停顿。问题原因：drain 用 `chunks * streamingInterval(0.08)` 估算播放时长，但 streamingInterval 是模型输出 chunk 的间隔，不等于 chunk 对应的实际音频时长。实测每 chunk 平均 0.33 秒，远大于 0.08 秒，导致 105 chunks 实际需要 34.7 秒播完，但估算只有 8.4 秒，触发误判重启。修复：系数从 0.08 改为 0.4

## v2.4.2 — 2026-07-02

### 改进

- **ASR 时自动取消 TTS** — 按 Cmd 录音前先停掉正在播和待播的语音，避免音响声音被麦克风采集干扰 ASR
- **媒体控制界面重新布局** — 顺序调整为锁屏→App→音量→播放控制
- **播放键改为模拟空格键** — playpause 从 `MRMediaRemote` 切换改为 `CGEvent` 空格键，需要设备控制与数据访问权限
- **锁屏改回按钮** — 滑块方案取消，保持顶部位置用红色按钮

### 修复

- **ASR 取消 TTS 后无声音** — `cancelAll()` 误调 `player.stop()` 导致引擎关闭且 `started=false`，后续 `write()` 静默丢弃所有音频数据
- **bundle 部署命中旧包** — `runtime.sh` 用 `find` 扫全部 `.build` 目录，`head -1` 可能选中 debug 旧包，锁定 release 路径

### 文档

- **`docs/stability.md`** — 新增架构稳定性评估文档

## v2.4.1 — 2026-07-01

### 重构

- **hook 脚本改名** — `hook-speak.sh` → `hook.sh`，所有文档、脚本、配置同步更新

### 文档

- **`docs/stability.md`** — 新增架构稳定性评估文档

## v2.4.0 — 2026-07-01

### 新增

- **微信 iW 集成** — 接入 WeChat ilink 协议，长轮询接收消息 → 注入 Claude Code
- **微信配置** — `config.json` 新增 `wechat` 段：`token`、`base_url`、`allow_from`、`long_poll_timeout_ms`
- **微信命令** — `ivox wechat setup`、`ivox wechat status`、`ivox wechat text`

### 修复

- **URLSession 超时兼容长轮询** — `withThrowingTaskGroup` 手动超时，绕过长轮询 TCP 保活导致 URLSession 空闲超时不触发的问题
- **`GetUpdatesResp.ret` 改为可选** — 长轮询空响应不返回 `ret` 字段，`DecodingError.keyNotFound` 导致轮询卡死
- **轮询日志增强** — 所有错误都打日志，不再静默吞掉非网络类错误
- **Swift 6.4 编译器崩溃** — MLXAudioTTS 在 `-O` 下 `performSILProcessing()` 栈溢出，固定使用 Swift 6.3.2 工具链编译

### 构建

- **`.swift-version` 移除** — 改用 `TOOLCHAINS=swift-6.3.2-RELEASE` 环境变量
- **Makefile 新增 `SWIFT` 变量** — `$(SWIFT) build` 自动使用 6.3.2 工具链
- **`docs/compiler-bugs.md`** — 记录 Swift 编译器已知问题

## v2.3.1 — 2026-06-22

### 新增

- **ASR 对外开放** — `ivox listen` CLI + Unix Socket 协议，`{type:asr,lang:zh}` + WAV，任何本地程序可用
- **TTS 长文本分段播放** — 按句切分到 ≤80 字，逐段 TTS 合成，批次编号 + 段编号日志
- **Socket API 文档** — `docs/api.md`，供其他 App 接入 TTS/ASR

### 优化

- **块级节点自动补句号** — 段落/标题/列表/代码块末尾无标点时自动补 `。`，TTS 语气有边界
- **按钮朴素化** — 移除 busy 锁，所有按钮无阻塞点击

## v2.3.0 — 2026-06-22

### 架构

- **媒体控制从 iDict 迁移到 iVox 内建** — 通过 `MediaRemote` 私有框架直接控制系统媒体，不再依赖外部 iDict HTTP 服务
- **双模调度** — `baseURL` 为空时走本地原生引擎，非空时保留远程模式，向后兼容
- **嵌入式 HTTP 服务器** — 移植 iDict 的 `MediaHTTPServer`，提供 Web UI 和 REST API（可选启用）

### 新增

- **原生媒体引擎** — `MediaRemoteBridge` 动态加载 `MRMediaRemoteSendCommand`，支持 play/pause/toggle/next/prev
- **`AudioAppRegistry`** — 从 MediaController 中提取应用注册表，职责单一
- **Web UI** — `http://127.0.0.1:8888` 移动端远程控制界面（需配置 `httpServerEnabled: true`）
- **`make deploy` 自动复制资源包** — `iVox_iVox.bundle` 含 index.html 和图标

### 优化

- **音频播报暂停不再走 HTTP** — PlaybackQueue 和 SpeechInputService 直接调原生引擎，消除 iDict 依赖
- **锁屏交互简化** — 滑块改为按钮，直接触发
- **MediaHTTPServer 线程安全** — `OSAllocatedUnfairLock` 保护共享状态
- **应用启动等待延长** — 从 2.3s 增加到 8s，适配 Electron 应用（抖音/汽水音乐）
- **页面移除状态指示器** — 干净简洁，播放按钮改为固定图标走 `MRMediaRemoteSendCommand(.toggle)`
- **`MediaControlConfig` 默认改为本地模式** — `baseURL: ""`，新用户开箱即用

### 修复

- **`AudioAppRegistry` 短名匹配 bug** — `bundleID.split(".").last` 取到 `"desktop"` 而非 `"douyin"`，导致 `toggle_douyin` 失败

## v2.2.1 — 2026-06-21

### 修复

- **Emoji 过滤误杀数字** — `isEmojiPresentation` 漏掉对象 emoji（📟📊🔄 等），改 `isEmoji` 但误杀 ASCII 数字，最终加 ASCII 白名单
- **mlx-audio-swift 更新** — 同步最新 main (3f6b055)，含 CustomVoice 语音解析修复

## v2.2.0 — 2026-06-20

### 架构

- **Task 取消架构** — PlaybackQueue 从 generation-counter 迁移到 Swift 结构化 Task 取消：`currentTask?.cancel()` + `defer` 清理 AudioPlayer，消除打断时的竞态条件
- **AudioPlayer 职责收敛** — 移除 `activeGeneration` 和 generation 参数传递，AudioPlayer 只负责音频写入，不再参与取消逻辑
- **TextCleaner 精简** — 102 行 → 53 行，去掉 block 拆分和硬编码 `。` 拼接，纯文本收集 + 块间空格分隔

### 修复

- **打断播放静音 bug** — `cancelPendingPlayback()` 在 enqueue 和 processNext 各调一次，第二次误清新 job 的音频缓冲区

### 编译

- **ICE 已修复** — Swift 6.4-dev (2026-06-15) 快照包含 LICM 修复，全局 `-Osize` 编译通过，Makefile 去掉 `-Onone`，Package.swift 去掉 per-target `unsafeFlags(["-O"])`
- **二进制体积** — 68MB → 55MB（-19%）

## v2.1.1 — 2026-06-19

### 优化

- **编译优化** — iVox/iVoxKit 单独开 `-O`，MLX 依赖继续用 `-Onone` 绕 ICE，推理编排代码显著提速
- **进程优先级** — launchd `ProcessType` 从 `Background` 改为 `Standard`，避免调度优先级过低导致推理卡顿
- **流式间隔调整** — `streamingInterval` 从 0.08s 增加到 0.15s，累积 2 帧再回调，减少音频片段开销
- **二进制安装简化** — 二进制和 Metal shader 合并为 `tar.gz` 单包，安装脚本只下载一个文件

### 修复

- **二进制安装签名** — `install-binary.sh` 新增 ad-hoc 签名步骤，避免从 GitHub Release 下载的二进制在部分系统上无法运行

## v2.1.0 — 2026-06-18

### 改进

- **AudioEngine 崩溃自动恢复** — 引擎崩溃不会永久静默，30s 冷却期后自动重试
- **媒体控制冷却** — 服务不可用时 5s 冷却期，不再连续重试轰炸
- **TTS 文本管道重写** — 从"去噪音"改为"文本自然化"：
  - 保留句号/问号/感叹号，让 LLM TTS 获得完整节奏信号
  - 短代码块（≤3行且≤80字）转为 inline 保留，不丢弃关键信息
  - commit hash 只删 16 位以上完整 SHA，保留短引用
  - 块间用空格分隔，不再所有段落用顿号拼接

### 修复

- **编译 ICE 绕过** — `-Onone` 替代 `-Osize`，mlx-swift 在 Swift 6 下优化阶段会崩溃
- **launchd 目录缺失** — 补了 `~/.local/share/ivox/runtime/`，修复守护进程启动失败

### 文档

- README、CHANGELOG 更新到 v2.1.0

## v2.0.1 — 2026-06-15

### 移除
- Pi 集成支持：删除 ivox.ts 扩展、install-hooks.py 中 Pi 安装逻辑、runtime.sh 中 Pi 部署
- dayi 音色保留，配置中 `sourceVoices` 去掉 `"pi": "dayi"`
- `--source` 选项帮助文本更新为 `claude/codex`
- 文档同步清理：README、architecture.md、hook-chain.md

## v2.0.0 — 2026-06-14

### 架构变更：iLLM API → 本地 MLX 推理

- 新增 `mlx-audio-swift`，TTS / ASR 改为进程内本地模型推理
- 配置 `api.baseURL` / `api.ttsModel` → `models.ttsPath` / `models.asrPath`
- 音色重新支持本地 `refAudio` + `refText` 参考音频配置
- ASR 模型仅在语音输入启用时加载，减少禁用场景的启动成本
- TTS PCM 转换改为按模型采样率重采样到播放器采样率，避免固定 24k 假设导致变速
- 新请求会立即取消正在合成/播放的旧播报，避免长文本占住队列导致后续消息卡住
- 新增 `tts` / `playback` / `mediaControl` 配置块，可调语言、流式间隔、重试、输出采样率、打断策略和 iDict 地址
- Daemon 启动顺序优化：先监听 socket，再后台加载/预热 TTS 与 ASR，冷启动时 hook 不再误判服务未启动
- Makefile 清理：删除旧 `model` phony、修正 `run`/`sign` 职责、增加 `restart`，并让 `launchd` 重启更幂等
- 新增 `make models`：通过 ModelScope 从 `mlx-community` 下载默认 TTS / ASR MLX 模型，安装流程自动执行，已有模型会跳过
- Makefile 重构为流程编排层，部署细节下沉到 `scripts/runtime.sh`；新增 `make update` 作为日常更新入口
- 部署流程新增参考音频初始化：内置默认 `ref_*.wav`，`make deploy` 自动补齐 `~/.config/ivox/voices/` 中缺失的默认音色
- Release 构建切换为 `-Osize`，规避 `MLXAudioTTS` 在 Swift `-O` 下触发的编译器崩溃
- 测试更新到新的 `models` 配置结构

### 移除
- iLLM TTS / ASR TCP/HTTP 客户端链路
- `api.baseURL` / `api.ttsModel` 配置

### 文档
- README：更新徽章、模型目录、配置示例、依赖说明
- 架构文档：数据流图改为本地 MLX 推理链路

## v1.3.1 — 2026-06-12

### 稳定性加固
- AudioPlayer 自愈策略优化：空闲复活前移到播报前，避免首段 PCM 写入时重启引擎导致短播报静默或残缺
- AudioPlayerNode 自动恢复播放：补充 `node.isPlaying` 检查，处理引擎运行但播放节点停止的边缘状态
- 音频配置变更延迟处理：设备/采样率变化时先标记，下次播报前统一重启引擎，减少播放中断
- 版本号更新为 `1.3.1`

## v1.3.0 — 2026-06-09

### 正式版
- 发布 TextCleaner 新过滤架构：Markdown AST 结构过滤 + 轻量行内噪音过滤
- 文档同步到当前实现：README、架构文档、Hook 链路和 CHANGELOG 全部更新
- 版本号更新为 `1.3.0`

## v1.2.2 — 2026-06-09

### 文本过滤
- TextCleaner 改为基于 `swift-markdown` AST 做结构过滤，跳过代码块、行内代码、HTML、图片、表格和分隔线
- 移除 artifact 行级预处理，输入统一按完整 Markdown 解析
- 新增轻量行内噪音过滤：清理 URL、常见路径、UUID、commit hash、ANSI 转义、速度/ETA 噪音和状态符号
- 保留版本号、API 名、函数名、百分比和普通语义文本，减少误删关键信息

### 工程
- `iVoxKit` 新增 `swift-markdown` 依赖
- 更新 TextCleaner 测试，覆盖 Markdown 结构过滤和行内噪音过滤
- 版本号更新为 `1.2.2`

## v1.2.1 — 2026-06-06

### 稳定性加固
- 代码噪音过滤放宽：保留文件扩展名、环境变量名、版本号、时间戳和函数调用，避免朗读丢失关键上下文
- AudioPlayer 引擎自动复活：监听休眠唤醒/耳机插拔/音频配置变更，空闲 10 分钟主动重启
- drain() 超时检测：根据 chunk 数动态计算等待时间，超时自动重启引擎
- 日志精简：TTS 流式只打印第一块，不再每块输出

### 架构安全
- MediaController 异步化：URLSession + semaphore → async/await，消除死锁风险
- 优雅退出：signal() → DispatchSource，SIGINT/SIGTERM 时停 AudioPlayer、关 Socket、删文件
- ConnectionHandler 非阻塞分发：nonisolated + DispatchQueue，不占用 Swift 并发线程池
- make deploy 自动签名，sign 目标使用固定证书 Hash，不再按名称 grep

### 清理
- AudioPipeline.swift：删除未使用的 modelSampleRate/outputSampleRate/streamChunkMs/chunkBytes/iterPCMChunks
- Package.swift：iVoxKit 移除未使用的 MLXAudioTTS 依赖
- Resources/com.user.ivox.plist：删除（Makefile 内联生成，此文件无人使用）
- AudioPlayer.swift：删除 isStarted 属性，initError 改为局部变量
- ServeCommand/RestartCommand：过期提示 "ivox setup" → "make" / "make launchd"
- Config.swift：var → let
- Makefile：简化 cp -n + 死回退模式

### 文档
- 新增 docs/hook-chain.md：从 AI 工具触发到扬声器出声的完整链路文档
- README：修复不存在的命令引用（make debug/restart, ivox model pull）
- install.sh：移除对已删除 setup/model 子命令的调用，改用 make 目标

## v1.2.0 — 2026-05-31

### 版本号统一管理
- 新增 `Sources/iVox/Utilities/Version.swift` 作为单一版本源
- `VersionCommand` 引用 `iVoxVersion` 常量，不再硬编码
- Makefile 新增 `version` 目标：`make version V=v1.2.0` 自动改文件、commit、打 tag
- 架构文档移除 `make sign`，替换为 `make version`

### 文档
- README、架构文档、Makefile help 同步更新

## v1.1.1 — 2026-05-31

### 播放队列优化
- 新播报请求入队时自动丢弃队列中所有未开始的待播任务
- 正在合成/播放的不打断，播完自动切到最新一条
- 避免连续对话中旧回复堆积，始终优先播最新内容

### 媒体控制重构
- 从 `CGEvent` 系统媒体键改为调用 [iDict](https://github.com/xdfnet/iDict) HTTP API
- 移除 `entitlements.plist`，不再需要设备控制与数据访问权限
- 不再需要 Apple Development 证书签名
- `install.sh` 简化：跳过代码签名步骤

### 文档
- 更新 README、架构文档、CHANGELOG
- `install.sh` 移除过时的设备控制与数据访问权限提示

## v1.1.0 — 2026-05-29

### 安装简化
- Codex hook 不再修改 `~/.codex/config.toml`，首次触发时由 Codex 自动引导授权
- 移除旧版 Swift HookInstaller（逻辑迁入 Python 脚本）
- 清理 Installer 中的 `hashlib`/`re` 等已不需要的导入

### 文档
- 重构 README：从用户视角按命令分组，特性卡片 + shields.io 徽章
- 架构文档随代码同步更新
- 移除冗余的 release-notes 文件，内容已合并到 CHANGELOG
- 移除 Homebrew 安装方式说明

## v1.0.0 — 2026-05-29

### 正式发布
- 首个正式版本 v1.0.0
- GitHub Release + Git tag
- 发布说明：`docs/release-notes-v1.0.0.md`

### 媒体控制
- `MediaController`: CGEvent 系统媒体键，播报时自动暂停/恢复音乐
- 用 Apple Development 证书签名，设备控制与数据访问权限持久绑定
- Makefile 集成 `codesign` 步骤

### 播放队列
- `PlaybackQueue`: 竞态修复，尾递归重检查，防止处理期间新任务丢失
- 批量处理：while 循环替代递归 processNext
- 媒体控制集成：pause → 播放 → resume

### 安装脚本
- `install.sh`: 一键编译+签名+部署+初始化

### 文档
- README: shields.io 徽章 + 特性卡片 + 用户视角介绍
- `docs/release-notes-v1.0.0.md` 发布说明
- `docs/architecture.md` 更新：媒体控制、尾递归、部署结构
- `docs/CHANGELOG.md` 本日志

---

## 2026-05-29（开发期）

### 基础建设
- 修复 `setup` 时 `JSONSerialization` 写入 `\/` 的问题
- 模板 `config.example.json` 与运行配置对齐
- `hook-speak.sh` 从 90 行 Node.js 精简到 31 行 bash + python3
- `ivox.ts` Pi 扩展改为走 `ivox speak --source pi`，不再直连 socket
- Claude Code / Codex / Pi 三个工具统一走 `ivox speak --source`

### 参数链路
- `SpeakCommand`: `--voice` 参数修复，拼入 `{source:xxx,voice:yyy}` payload
- `ConnectionHandler.extractVoicePrefix`: 键值对解析，优先级 显式 voice > sourceVoices > defaultVoice

### 音频引擎
- `AudioPlayer` 重写：串行队列解决 AVAudioEngine 多 actor SIGSEGV
- `drain()` 改用 `scheduleBuffer` 完成回调 + 轮询等待，消除播放切尾
- 初始化保护：`initError` 状态 + `isStarted` 检查

### 流式合成
- `TTSEngine.synthesizeStream()`: `AsyncThrowingStream<Data>` 替换批量返回
- 重试机制：TTS 合成失败自动重试 2 次，每次间隔 500ms

### 模型预热
- `TTSEngine.warmup()`: daemon 启动后预热 GPU pipeline
- `Daemon.run()`: `loadModel()` 后立即 `await engine.warmup(voiceID:)`

### 新命令
- `ivox status` — socket 连接检查
- `ivox version` — v1.0.0
- `ivox restart` — launchd kickstart
- `ivox voice list` — 读 config 列出音色
- `ivox voice add` — 添加自定义音色
- `ivox voice remove` — 删除音色
- `ivox model pull` — 从 ModelScope 克隆 Qwen3-TTS 模型

### 运维
- 日志轮转：`daemon.log` 超过 5MB 自动归档 `.old`
- `saveConfig()` 公共 API，`\/` 自动清理
- `VoiceInfo` memberwise init

### 工程
- Git 初始化（main 分支），`.gitignore`
- Makefile: `build` / `debug` / `install` / `restart` / `clean`
- launchd plist 模板补完日志路径 + HOME 环境变量
- `installRuntimeArtifacts` 路径改为 `.build/release`
- 部署结构全部在 `~` 下，删项目无影响
