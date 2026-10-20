# iVox 开发日志

## 未发布 — 2026-10-21

- **外部配置换成 TOML：能写注释了** — 飞哥「json 做配置很烦，不能做注释，很不容易阅读」。
  `~/.config/ivox/config.json` → **`~/.config/ivox/config.toml`**，格式换成 TOML：
  `#` 注释、方括号分段，写起来像 INI，每一项是干嘛的直接写在旁边。配套：
  - `iVoxKit/TOML.swift`：**自研**解析/序列化（无外部依赖，发布二进制不变），支持段、数组表
    （`[[voices]]`）、多行字符串、整数/浮点/布尔/数组/内联表、`#` 注释；
    不支持的写法**明确报错**并给行号，不静默吞。
  - `iVoxKit/TOMLDocument.swift`：**就地改**配置——程序写回时只动那几行，**用户自己写的注释留着**
    （`ivox voice add/remove`、`ivox wechat setup` 都走它；整体重排会把注释冲掉）。
  - 默认模板挪进 `iVoxKit/ConfigTemplate.swift`（唯一真源，带逐项说明的注释）；
    `Resources/config.example.json` 删除，`ivox init-config` 写的就是这份模板。
  - 老 `config.json` **自动迁移**成 `config.toml`（顺带把老写法 `defaultVoice` 并进
    `sourceVoices.default`）；**旧文件保留不删**（删除交给人）。
  - 写回时的键顺序由各类型的 `CodingKeys` 派生（`ConfigAudit.sectionOrder`），不另抄清单。

- **清理死配置** — 飞哥「清理死配置」。删掉三处「写了没用的」：
  - `mediaControl.enabled`：`MediaController` 存了配置从来没人读，Web 服务的真开关是
    `httpServerEnabled`，这个字段写 true/false 都一样——骗人的死字段，删。
  - `MediaController.config`：存着不读的属性连同 init 参数一起去掉。
  - `Config.configBaseDir`：赋值了从没被读过。

- **配置整体审计：模板与代码默认值钉在一起** — 飞哥「关于配置整体审计一下」。
  盘点结果：**外部配置没有死字段**（每个键都有真读点，用脚本逐字段核过），
  代码内配置也都在用。真正的风险是另一头——**同一件事写了两遍**：
  默认值在代码里一份、在模板里又抄一份，改了一边忘了另一边，新装用户就跟老用户不一样。
  现在加 `ConfigTemplateTests` 把两者钉住：段的顺序、每段的键、每个默认值，
  任何一边漂了测试就红。顺带修了几处「抄错」的默认值：
  `PlaybackConfig.default` 的 `captions` 由 nil 改成明确的 false；
  `WeChatConfig.claudePath` 的默认由 nil 改成 `~/.local/bin/claude`
  （原来靠 `resolvedClaudePath` 兜底，编码时却是 nil）；模板里 `proxyURL` 改成注释形式
  （默认就是「不走代理」，写成空串会被读成「配了个空代理」）。

- **家当说明随装机一起走** — 飞哥「初始化的时候把 runtime-files.md 拷贝到
  `~/.config/ivox/` 目录下，明白了吗」。`ivox init-config` 现在除生成配置外，
  还把 `runtime-files.md`（家当说明）拷到 `~/.config/ivox/`——
  **每次都刷新**（它是随版本的说明，不含用户数据），所以升级后说明也跟着更新；
  配置本身仍然「已存在就不动」，不覆盖用户改过的内容。

- **运行时家当说明入库** — 飞哥「换个名字，入库」。`~/.config/ivox/README.md`
  → 仓库里的 [docs/runtime-files.md](runtime-files.md)（说清每个文件谁写、能不能删、
  删了会怎样）；机器上那个文件只留一行入口，不再抄内容——抄了就会和代码漂。
  `docs/README.md` 索引与 `CLAUDE.md` 的指针同步。

- **语音键默认只要右⌘** — 飞哥「`voice = "rightcmd"`，只要这个」。默认语音键从
  「右⌘ 或右⌃」改成**只要右⌘**（`VoiceKeySpec.default`），模板与用户配置同步；
  配置里仍可写 `rightctrl` / `rightcmd+rightctrl` / `none`。

- **`mediaControl` 挪进代码内配置** — 飞哥裁决。Web 控制台的开关与端口是**产品的一部分**
  （一直在 8888），不是「你常改的」——外部配置里不再有 `mediaControl` 段，
  写了会被忽略并被配置审计点名。`MediaControlConfig.default` 是唯一真源。

- **默认音色并进 `sourceVoices`** — 飞哥「`defaultVoice` 和 `sourceVoices` 能在一个里吗」。
  现在只有 `sourceVoices` 一段，其中 **`default` 键就是默认音色**（没有来源时用它），
  顶层不再单设 `defaultVoice` 字段——一处说清，别两处各写一遍。

- **配置重新分层：代码内配置用 Swift 常量，外部只留一个 json** — 飞哥裁决。三层各管各的：
  ① **代码内配置**（全在 `Sources/iVoxKit/Config.swift` 里，不另开文件）——`ModelPaths`（模型路径）、
  `TTSConfig.default`（合成参数）、`VoiceCatalog.builtin`（内置音色）：都是**产品内容**，不该让用户
  在配置里改，也不该把四段几十字的参考文本塞进他的 config.toml；外部配置里再写这些段会被忽略，
  并被配置审计点名（写了不生效）；
  ② **外部配置**（`~/.config/ivox/config.toml`，就这一个文件）——凭据（微信 token、翻译 apiKey）
  与用户会主动改的（开关、键位、端口、模型路径）；
  ③ **用户数据**（recordings/、wechat/context_token.json）——程序写的运行产物。
  配套：`Config.voices` 变成可选（现在只表示「用户自建/覆盖的」，首装配置里没有这段），
  `Config.resolvedVoices` = 内置 + 用户合并（同 id 用户覆盖内置）；`ivox voice list` 标出
  `[内置]`/`[自建]`；`voice add` 遇内置同名 id 提示「将覆盖它」；`voice remove` 删不掉内置的。

- **键名统一成驼峰 + 未知字段告警** — 同一个配置文件里曾有两套命名风格：`wechat` 段
  显式映射成蛇形（`base_url` / `allow_from`），其余段是驼峰。现已统一（`WeChatConfig` 去掉
  显式蛇形映射），并加**配置审计**：解码后对照各段已知键，把「写了但没人认领」的键打进
  `daemon.log`，还会猜「你是不是想写 allowFrom？」。已知键从各类型 `CodingKeys` 派生
  （`knownKeys`），不另抄一份清单——两份清单迟早漂移，漂了就成了「告警说某键无效、它其实有效」。

- **默认配置只留一份真源** — 新增 `ivox init-config`：从模板生成默认配置（已存在则不动）。
  `install-binary.sh` 改为调它，删掉了内嵌的那份 JSON（此前模板与脚本各一份，迟早漂移）。

- **发布包补上两个资源 bundle** — 此前包里只有 `ivox` + `integrations`，**没有**
  `iVox_iVox.bundle`（Web UI 的 index.html、配置模板、voices）与 `mlx-swift_Cmlx.bundle`
  （Metal shader，**TTS 合成必需**）→ `curl | bash` 装完 Web 控制台打不开、合成起不来。
  现在两个 bundle 与 4 个音色参考音频（1.7MB）都随包（12MB → 17MB）。

- **发布包带上音色参考音频** — 飞哥问「首次安装都要干什么」，顺带查出一个真缺口：发布包里只有
  `ivox` + `integrations`，**没有 4 个参考音频 wav**（1.7MB）。于是走 `curl | bash` 装的人，
  配置里四个音色的 `refAudio` 指向的 `~/.config/ivox/voices/ref_*.wav` **是空的**——参考音频读不到，
  合成直接抛错，**装完播报根本用不了**（走 `make install` 的没事，runtime.sh 有 voices 步骤）。
  补法：`make package` 把 `voices/` 打进包（12MB → 15MB），`install-binary.sh` 解到 `$CONFIG_DIR`
  （落点即 `$VOICE_DIR`，与配置里的 `refAudio` 路径对齐）；旧包不含 voices 时解不出来不算错，
  只提示用户从源码装。解包路径特意验过：解到 `$VOICE_DIR` 会多一层 `voices/voices/`。

- **热键改到配置里：改配置文件的 `hotkeys` 段，`ivox restart` 生效** — 飞哥「经常换快捷键」，
  而九个组合键原先是 `GlobalKeyTap` 里的一张硬编码表，换一个键要改代码重编译。现状：
  - 键位**只写一处**：`iVoxKit/HotKeySpec.swift` 里 `defaultChord`（默认值）与 `parseChord`（解析器），
    纯逻辑无 UI 依赖，配套 14 条用例；`GlobalKeyTap` 只消费它，不再自带一份表。动作名也从
    `GlobalKeyTap.HotKey` 挪到 `iVoxKit.HotKeyAction`——配置与键盘层共用同一个名字来源。
  - 配置 `hotkeys` 段按**动作名**给键位（`translate` / `openTerminal` / `openTerminalClaude` /
    `openTerminalCodex` / `openTerminalPi` / `copyPath` / `escInterrupt` / `skipBucket` /
    `skipPage`），**只写要改的**，没写的走默认；语音键（右⌘/右⌃ 长按说话）也归它管
    （`rightcmd` / `rightctrl` / `rightcmd+rightctrl` / `none`）。
  - 写法：`cmd+shift+d`、`ctrl+esc` 这种人话，修饰键认 `command`/`control`/`option`/`alt` 别名，
    主键可用 `a-z`、`0-9`、`esc`、`space`、`tab`、`return`、`backspace`、`delete`、`f1`-`f12`、方向键。
  - **配错不静默**：解析失败、动作名不存在、两个动作抢同一个键位，都在启动日志里写明
    （哪个动作、错在哪、退回了哪个默认）；生效的键位逐行打「热键: 动作 = 键位」，**日志即真相**。
  - 新增 `ivox restart`：只重启守护进程（`launchctl kickstart -k`），**不动登录自启开关**——
    `on` 会 enable 自启、`off` 会 disable 自启，都不是「重启」该干的事；job 没在跑时明确报错让人
    `ivox on`，不顺手把它拉起来（那会顺带打开自启）。
  - 配置模板（`iVoxKit/ConfigTemplate.swift`）里**写全量默认键位**——飞哥要「装好就看得见、
    改哪行改哪行」，首次安装即初始化好这一套（存量配置不自动改，安装脚本只做加法）。
    ⚠️ 于是默认键位有**两份副本**：代码兜底（`HotKeySpec.defaultChord`，配置缺失时用）与模板——
    **改默认键位要同步这两处**，否则新装与老用户行为不一致。

- **模型加载失败不再静默卡死：子进程加载失败就退出，主进程按退避换一个重试** — 这是 v6.0.0
  三进程拆分带来的新故障模式，而**不是理论风险**：2026-10-19 23:32 真实卡过一次
  （`誊清员: 模型未就绪 — 誊清员无响应` → `TTS 合成失败`，直到人工重启 daemon 才恢复）。
  根因是**「socket 在」被当成了「引擎能用」**：子进程先绑 socket 再后台加载模型，
  加载失败却不退出，于是 socket 一直通着 —— 主进程永远认为它活着，既不重试也不降级，
  而每合成一块刷一条同款错误。三处一起改，缺一处还是凑合：
  ① **子进程加载失败即退出**（`TTSCommand`）——让它别占着 socket 装健康；
  ② **主进程按指数退避换一个**（2s→4s→…→60s 封顶，**永不放弃**，飞哥 2026-10-20 定：
  模型加载失败常是瞬时的（显存被占、磁盘忙），一直等才有机会自愈；封顶是为了文件真坏时
  也不烧 CPU）；③ **失败只说一次**，不再逐块刷屏。
  顺带收敛了「拉起子进程」的入口（三个触发点原先各自拉一次，退避计数无从对齐）。

  **这个过程本身就是两份教训**（都已写进全局 CLAUDE.md）：
  - **别死磕细节**：第一版把退避挂在「socket 连不上」上，而真实路径是「socket 连上了、
    加载失败、子进程才退出」——那条路根本不会触发，逻辑一次都没跑过。真信号是**状态 failed**。
  - **占位要在动手之前**：`replaceChild` 里那个最长 90 秒的 `await` 会让出 actor，
    期间合成、/health、启动握手都涌进来，各自都读到「还没到退避点」，于是每秒拉一个。
    修法是先推进「下次允许的时间」，后来的调用只能看着。

- **补齐播报的首尾锚点，并统一措辞** — 此前**播报结束有日志、播报开始没有**：能 grep 到
  `播放收尾完成`，却没有对应的开始行（最接近的 `TTS 合成开始` 领先真实发声 2~4 秒，拿它当
  开始会把整段时间算错）。现在补上 `播放开始`，打点在**设备真正读出第一块 PCM 的那一刻**
  （不是 write 入队那一刻），与末尾成对；prime 静音不带 seq，天然只认真正的第一块。
  每轮播空时重置标记，于是**每轮播报各有一个开始、一个结束**。
  同时把两个含义不同的结束分清：`播放结束` 讲声音停了，`播报结束` 讲界面收工
  （原先都叫「收尾」，grep 时容易混）。自检 7 处正则与 4 处文档同步。


## 未发布 — 2026-10-20

- **给「誊清员崩了能自愈」补上自动化用例**（`R1-scribe-crash-voids-block-queue-continues`）—
  这是 v6.0.0 存在的**全部理由**，此前只有一次手工验收撑着，而手工验收会腐烂：哪天重构动了
  `TSPRemote` 的泵逻辑，或者上游修好 MLX 让同步路径回来了，这块能力悄悄没了都不会有人知道。
  判据三件套缺一不可：**作废**（不留半句）、**继续**（后面的内容照播）、**自愈**（监督者重拉，
  否则这次过了、下次崩了就永久哑掉）。用例刻意不调 `noBad()`——崩溃导致的「这一块作废」正是
  预期现象，而 `CASE_BAD` 里的 `/TTS 合成失败/` 会把它当成产品缺陷。
  **反向验证过**：造一个「不杀誊清员」的变体跑，`pass=0 fail=1`，证明断言真在盯那行日志而非假绿。

- **自检在非 debug 级 daemon 上不再假红** — `E3` / `A-tail` 靠 DEBUG 行（「队列状态:」）数入队块数，
  而脚本切日志级别走 `launchctl kickstart`，对**手动起的** daemon 无效；原先只打一行警告就往下跑，
  那两条直接假红，报「入队块数(0)」这种看着像产品坏了的数（2026-10-20 亲身踩了一次）。
  现在预检顺带探一次 DEBUG 可见性，看不见就把这两条降级 skip 并写明原因——**假红比 skip 坏得多**：
  skip 会被人看见，假红会被当成产品缺陷去查半天。
  判据取 DEBUG-only 的**正文**而非「[DEBUG]」级别字样：级别标记在行首，解析出来就没了，
  `msg` 字段里根本没有它，拿它当判据会永远判成 invisible（第一版就栽在这，debug 级下也全 skip）。

- **`hook.log` 补上轮转上限** — 它原先只增不减，而 `daemon.log` 有 5M 阈值，用久了会涨到几百 M。
  现在按同一阈值把主文件改名成 `.old`（用 `mv` 覆盖而非先 `rm`，省一步也不在 hook 里做删除）。
  两侧都验过：造 7.2M 的日志触发轮转，219 字节的小文件不误动。


## v6.0.0 — 2026-10-20

**破坏性变更**：播报合成从「主进程内 MLX」改为「独立誊清员子进程」——`ivox serve` 不再自己
加载模型，多出一个由它 spawn 的 `ivox tts --serve` 进程；日志从 1 份变 3 份；codex 播报链路删除。
升级若靠 `install-binary.sh` / `ivox upgrade`，新版本会带起子进程，无需手工操作。


- **删掉 codex 的播报链路，只留 Claude 与 pi** — codex 自身不能分页，一次输入只能整段搬一次
  （`Stop` 时从 rollout jsonl 按 `turn_id` + `phase == FinalAnswer` 挑一条），听着像念日志而不
  是听回复；它有 12 个 hook 事件但**没有一个带 assistant 正文增量**，hook 拿不到流。更重要的是
  **留着它会污染概念**——它那套「按 turn 分组、Stop 整段播」的描述与另两家完全不同，看文档的人
  会以为「打断粒度由身份决定」，而代码里身份早已改由助理自编。删掉 `hook.sh` 的 speak 分支
  （209 → 137 行）、`install-hooks.sh` 的 Codex 段、`sourceVoices` 的 `"codex": "wanwan"` 映射，
  以及文档里的「两家分叉」「三方对齐表」。
  **边界**：`Opt+X` 开终端跑 codex 属 QuickActions 能力域，与播报无关，保留。
  `wanwan` 音色本身留着（它只是可用音色，不再绑死某个来源）。

- **播报拆成三进程：MLX 隔离进誊清员** — MLX 的 Metal 命令编码器析构时重复释放 GPU 命令队列
  → SIGTRAP。同一根因此前已露过两次脸（取消时 commit 未收口、copy_gpu SIGSEGV），每次都只给
  **特定路径**打补丁，第三次照旧炸；上游（mlx-audio-swift 244458d / mlx-swift 0.32.3）本地即
  最新、encoder 由 `generateStream` 内部创建、Swift 侧拿不到引用，**无从拦截**。所以把会炸的
  那一层整个圈出去：主进程经 Unix socket + `StreamFrame` 长度帧驱动子进程 `ivox tts --serve`
  （誊清员），`TSPRemote` 兼**监督者**（先问 socket 再问 child，断了自动重拉）。新契约
  `TTSProviding` 成员一律声明 `async`，队列与 `ConnectionHandler` 只认契约、不知道背后跨不跨进程；
  `IVOX_TTS=local` 可退回进程内 `TTSEngine` 供调试对照。三条纪律写进 `docs/playback/queue.md`：
  **进度只存主进程**（发声点永不过 IPC）、**不重发已送出 PCM**（重发得到「前半截 + 从头再来」
  的接缝，比直接作废更糟）、**半句必须能认出来**（`StreamFrame.parseChunks` 增 `sawEnd`，
  没读到结束标记就报 `truncated` 并作废这一块）。
  **崩溃验收**：合成中途 `kill -9` 誊清员 → `誊中断，这一块作废：truncated seq=N` → 块作废、
  队列继续、播报员全程没被打断，下一条正常播，自动重拉。顺带把日志分家（daemon / tts / tts-crash），
  「哪个文件里有现场就是哪个角色的错」。已知代价：跨进程后预取余量变薄，
  `B-synthesis-leads-playback` 报 advisory（3.7s ≈ 4s 高水位），**不是回归**。

- **修三档键位在 help 文本与两份文档里全是反的** — `Ctrl+Esc` 掀页 / `Ctrl+1` 掀摞 / `Ctrl+2`
  全掀，这三处在 `GlobalKeyTap.bindings` 与 `Daemon.setUpHotKeys` 里**是对的**，
  `PlaybackQueue.swift` 的枚举注释是反的，文档抄了错的那份两遍。改代码 + `--help` + 两份文档；
  并在注释里加警示：**键位对照以 `GlobalKeyTap.bindings` 与 `setUpHotKeys` 为准**。
  另配 CLI `ivox skip --page|--stack|--all`，与热键同一条代码路径，供自检与远程排查。

- **文档全面按现状对齐** — 删净 codex 残留概念；`playback/` 五层补 2026-10-19 隔离裁决；
  术语表身份列由外部 `turn_id`/`message_id` 改为助理自编的 `localID`/`seq`；`architecture.md`
  合成引擎小节改写为「契约 + 两种实现」、能力域表补 5 个漏掉的文件；`socket-api.md` 补整节缺失的
  `{type:quick}`；`native-bridge.md` 加「实施后纠偏表」（`--model` 已被推翻、闲置回收未实现、
  assistant 帧才是主力）；`~/.config/ivox/README.md` 新建（家当说明书，不进版本库）。

- **右⌘/⌃：副作用挪到「真的在录」之后** — 原先一按下就 `cancelAll`（打断播报）+ `pause`（暂停
  音乐），然后才去建 recorder。于是没插麦克风时按一下的代价是**白打断一次播报、白暂停一次
  音乐，然后静默失败**。现在顺序反过来：**先试录，试活了才去让路**。
  特意**不做设备预检**——耳机类麦克风按需唤醒，预检「设备在不在」会误判，把本来能用的设备
  焊死；**按下就试这一下，试活了算数**，这恰好是对按需唤醒最友好的做法。副作用只在
  「确实在录」时发生，是它的本意：打断与让路是为录音服务的，没在录就没什么好让的。

- **录音启动失败时把「为什么」写清楚** — 此前只写「录音启动失败」，两天后再看只能重新猜一遍。
  现在同时报**授权层**（TCC）与**设备层**（CoreAudio 的默认输入设备名）：
  - 「授权已给，设备层没有默认输入设备（没插？或耳机类设备尚未被唤醒）」
  - 「授权已给，设备层默认输入=「xxx」」

  这两层分开是实测逼出来的：17:32 日志「麦克风已授权」、17:38 两次「录音启动失败」挨着出现，
  只看「失败」会误以为授权也有问题（那就会跑去系统设置里白找——那里本来就勾上了）。
  设备层用 CoreAudio 查（`AVAudioSession` 是 iOS 独有的，macOS 上没有这回事），实测能取到
  设备名。**只写日志、不据此拒绝**：耳机与某些 USB 麦克风按需唤醒，没唤醒时查就是空的，
  拿它当前置门禁会把本来能用的设备焊死。

## v5.3.0 — 2026-10-19

本版一句话：**按键不再重复干活，重复的内容也不重复花钱。**

起因是一天的日志：崩溃查了两轮、修了两条线，顺手把「后面干活的」全捋了一遍。

### 热键防误触（都在 tap 层，一处判完）

- **同键冷却，按键分档** — `Cmd+D` 0.2s、三个打断键 0.3s、其余 1s。冷却中**仍然吃掉
  事件**、只是不执行：漏给目标 app 更糟。走 `systemUptime` 单调时钟，只在 tap 线程读写。
- **右⌘/⌃ 加 150ms 长按阈值** — 按下不足这么久就松开判为误触（很多 App 用右⌘，碰一下
  就打断播报 + 暂停音乐 + 开麦，代价太大）。阈值内松开的按下沿直接丢弃。**没套冷却**：
  按住说话是「按下起录、松开结束」，套冷却会把「说一句、再说一句」的第二句吃掉。

### 重的动作押后，便宜的先上屏

- **Cmd+D 改「后写胜出 + 乐观占位」** — 原来连按是 `guard !inFlight else { return }`，
  第二次直接丢（你换了个选区想再译一次，白按）。现在：先弹「读取选区…」占位 → 读
  剪贴板校验 → 弹「翻译中…」→ **等 200ms 提交点才发请求**。期间世代被推进（又按了
  一次）就到此为止，请求压根不发。误触的代价从「一次请求 + 一次朗读」降到「一个闪一下
  的空窗」。
- **Opt+Z 复用已开的 Ghostty** — 已经在跑就聚焦，不再开新窗口（连按五下开五个终端）。
  带命令的 Opt+A/X/Q **仍开新实例**：命令要在新实例里跑，`createsNewApplicationInstance`
  不能破。取舍：复用时不保证落在 Finder 当前目录（取已在跑的窗口目录要向 Ghostty 要
  Automation 授权，不值当），要指定目录新开一个。

### 同一段内容不译两次

- **最近一次译文缓存 + 在途去重** — `TranslationService` 此前只记住「该走代理」这个连接
  结论，**译文零缓存**：同一段文字译 N 次 = N 次请求 + N 次推理。两层各省不同的钱：
  **在途去重**省掉「同一段文字被重复按下时并发的第二次请求」（后到的等同一次的结果），
  **最近一次缓存**省掉「译完又按一次」的重来。缓存键带 `provider|model`，切了翻译后端
  不拿旧译文顶账；**只留最后一次**。命中缓存照样朗读——用户想听的是译文，缓存省的
  是生成，不是他的耳朵。
- **新增单测 2 条**（`TranslationCacheTests`）：同文两次只发一次请求、换文重发、同文并发
  只发一次。单测 132/132。

### 缓存复审：去掉冗余，补上淘汰

- **翻译缓存从「1 条」改成「16 条」且合并数据结构** — 复审发现两处不合理：
  ① 「只留最近一次」挡不住真实用法（反复对比几段，来回切就 miss）；② 已完成的 `lastSuccess`
  和在途的 `inFlight` 是两个 `(key, payload)` 槽位，管的都是「最近一次翻译」这一件事。
  现在历史是**先进先出的 16 条**（每条存原文+译文，原文被 `validateSelectionText` 卡在
  5000 字内，极端情况几百 KB，相对 10G 模型可忽略），在途仍单独一个槽位（生命周期不同）。
  单测补一条：**超过容量后最老的被挤掉要重发**，容量内的仍命中。133/133。
- **`lastturn/` 加 7 天淘汰** — 这张 `session → 最后一摞` 的对照表只存着给 Stop 反查用，
  回复结束就没用了，此前**只涨不清**（实测堆到 30 个文件）。现在每轮 Stop 顺手扫一遍、
  删掉七天前的：一轮一次，一天几十次，代价可忽略；七天内可能还会被反查，更早的会话
  不可能还在对话里。
- **`refAudioCache` 不动** — 两层盒子看着冗余，实则是被 `mlx-swift` 的 `sending` 语义逼的：
  库要靠 `ObjectIdentifier(refAudio)` 复用输入准备上下文，必须交同一个实例，造新的每块
  多花 1~2 秒（实测 4~5s 涨到 5~7s）。是必要的难看，不是冗余。

### 录音启动失败不再野指针崩溃

- **`record()` 失败不再直接析构 recorder** — 2026-10-19 16:17 实测的新崩溃线，与 MLX 那条
  **同病同源**：`recorder.record(forDuration:)` 返回 false 的那一瞬，audio queue 的输入回调
  线程**已经起来了**，而代码直接 `return nil` 让 recorder 失去最后一个强引用；回调线程下一拍
  进来访问已释放对象 → `objc_loadWeak` 野指针 → SIGSEGV（栈底 AVFAudio
  `AudioRecorderAQInputCallback`）。现场日志 `Weak reference ... not in the weak references
  table` 就是「弱引用指向的对象已死」。现在失败时先 `stop()` 让队列停下，再进**隔离区**
  延迟 1 秒释放——和 TTS 那侧「取消后排空 MLX 流再放行」是同一个思路：**底层线程已经在跑，
  就不能把对象扔了**。这条线此前一直存在，只是今天才第一次留下「录音启动失败」的日志、被抓到。

## v5.2.1 — 2026-10-19

本版一句话：**止住一天 5 次的 MLX/Metal 崩溃，顺带把一直写不下来的崩溃栈修好。**

### 崩溃本身（两个根因，都在 C++/Metal 层）

- **打断后不再半途丢弃 MLX 流（治一天 5 次的崩溃）** — 2026-10-19 一天崩 5 次，两张脸：
  `SIGABRT` 报 `IOGPUMetalCommandBuffer validate: failed assertion 'commit command buffer
  with uncommitted encoder'`，`SIGSEGV` 崩在 AGXMetal `computeCommandEncoder` →
  mlx `copy_gpu_inplace`，stderr 侧还有 `std::system_error: mutex lock failed`。
  根因不是模型并发（世代闸门早就在），而是**取消时直接把 MLX 生成器扔掉**：encoder 里还压着
  未 commit 的命令，析构即触发 GPU 断言。现在取消后停止 yield 但**继续把流读完**，等 GPU 自然
  收口再抛 `CancellationError`，闸门时序不变。
- **退出时不再撞 GPU 析构** — 另有一类崩在**进程退出**路上：栈底 `__cxa_finalize_ranges` →
  mlx 全局 `CommandEncoder` 哈希表析构 → `end_encoding`，撞上未收口的 encoder 即 SIGSEGV。
  现场是 `ivox restart` 恰好在合成进行中，整进程被这一下带崩（自检里连着几个用例 ECONNREFUSED）。
  收尾完成后刷盘 `_exit(0)`，跳过静态析构。
- **`crash.log` 从此不再恒为 0 字节** — 处理器用 `String.write(toFile:)` 清空记录，那是
  「写临时文件 + rename」，换掉了 inode；而 fd 在此之前就已打开，指向的是一个已经没人看见的
  孤儿 inode，于是**每次崩溃的完整调用栈都写进了虚空**（日志里那句「完整栈见 crash.log」
  指了个空文件）。现在顺序倒过来：先报走上次记录、用 `ftruncate` 原地截断，再打开 fd。
- **崩溃编号跨重启累计** — 计数记在 `~/.config/ivox/crash.count`，不再每次重启都从 `#1` 开始。

### 已实测

- 单测 130/130
- 黑盒自检 `make check-tts` **19/19**（修复前同一套压测跑到一半崩、E1~E6 连红），
  366 秒密集打断全程零崩溃

## v5.2.0 — 2026-10-19

本版一句话：**自升级这条路自己走通**——名字对齐 `make update`、GitHub 认证自带、
输出照 `claude update` 的节奏，让人一眼看出升级前后差在哪。

- **`ivox upgrade` 改名 `ivox update`**，与 `make update` 说法一致（少一个记法）
- **输出照 `claude update` 的四段式**：当前版本 → 检查 → 目标版本 → 结果。
  关键是**开头就报当前版本、已是最新时也照报**——原先「已是最新版本 v5.1.0」是唯一
  一行输出，看不出它查了什么
- **支持 GitHub 认证，报错不再误导** — 未认证的 GitHub API 只有
  **60 次/小时、按出口 IP 算**（路由器透明代理下全机共用一个 IP，别人用完你就遭殃）。
  配额耗尽时 GitHub 返回 `{"message":"API rate limit exceeded…"}`——**合法 JSON，但没有
  `tag_name`**，于是解 JSON 崩掉、报成「解析 release 信息失败」，把人引向「代码坏了」
  （2026-10-19 实测踩中）。现在：
  ① token 按 `GITHUB_TOKEN` → `GH_TOKEN` → **`gh auth token`**（gh 登录过就有，
  多数情况**无需任何配置**）三段取，只进 `Authorization` 头，不打印不写日志；
  ② 先看 HTTP 状态码再解 JSON，403/429 直接说「限流」并给出配置指引，401 说凭据失效。
- **codex 只播结论，一摞一页** — `Stop` 时从 transcript 按 `turn_id` + `phase == FinalAnswer`
  挑出本轮最终答案，`Commentary`（中途解说）与 `PartialAnswer`（半截答案）一律不搬；
  挑不到才退回 payload 自带的 `last_assistant_message`。搬来的东西**不带 `--page`**，
  与 `ivox speak` 同形（助理自编页号，一摞就一页）。前两版曾先后试过「只播 `last_assistant_message`」
  （丢掉过程）→「搬本轮全部消息当多页」（听着像念日志、又迟到一步），最终定在「只搬结论」。
  codex 增量不落盘（`AgentMessageContentDelta` → None）且无流式钩子，**拿不到边生成边听**，
  这是协议上限；`Interrupt` 仍只作收尾信号、不出声。

### 修订

- **`Stop` 盖印顺带立墓碑** — 此前 `sealTurn` 只盖印不立墓碑（怕「同一摞的页还在路上」），但
  Stop 是 Claude 回复完毕的终点，**之后不会有该摞的增量了**，墓碑拦的「迟到增量」其实不会来。
  旧设计在 Claude Code 端跑出了「旧摞块没播完，新摞已入队」的串音现场：旧摞没立墓碑意味着新摞进来时
  旧摞还在播，新摞直接顶到队首，用户按 Ctrl+1 跳过的就是新摞（旧摞的墓碑要等下一轮才立，永远迟一步）。
  `sealTurn` 现在内部调 `bury(id)`，墓碑只拦入队口 `appendToStack`/`appendPlain` 的同 turn_id
  增量，对在播/已合成的块没影响——放心。`finishTurn` 路径不变，只是它现在能更早立碑。

## v5.1.0 — 2026-10-18

本版一句话：**播报站自己发号，各端只管把材料递进来。** 起因是「Ctrl+1 掀摞之后后面的内容没播」，
查下去发现身份设计反了 —— 谁定义摞、谁就该发号，却一直指望外部递编号。

### 已实测

- 单测 130/130
- 黑盒自检（`make check-tts`）19/19，含新增 `S3-skip-stack-plain-stacks-are-separate`
- 真机确认日志：两次 `ivox speak` 落在第 42/43 两个独立摞，掀掉 42（块=1）、43 立刻接着播完
  —— 这正是修复前「34 块一起丢」的场景

### 待实测（本版发在实测之前，飞哥自用观察）

- pi 的 Ctrl+1 掀摞（新扩展需**重开 pi 会话**才生效）
- codex 按 Esc 的中断收尾

- **摞号页号块号改由助理自编（推翻了「名牌决定身份」）** — 起因是 codex 那边按 Ctrl+1
  掀摞后后面内容全没了：现场是 34 块一起丢、其中只有 6 块是新回复。根因在身份设计——
  摞/页的身份原先**靠外部 `turn_id` / `message_id`**（codex 的 `Stop` 那时还只取
  `last_assistant_message`，不带分组），没编号的来源被 `appendPlain` 焊进同一段，
  「掀这一摞」于是等于「掀掉这期间的一切」。飞哥的裁决：**跑腿的只提供材料和线索，
  编号一律助理自己发**（主次不能反——不能为迁就某一端而在助理里长出它的特例）。
  改法：`PlaybackBlock.seq` / `PlaybackPage.localID` / `PlaybackSegment.localID` 全部自增
  永不复用；外部编号降为**备注**（只用于对日志、给墓碑分范围）；衔接表「外部 group ↔
  助理自编摞号」搬到跑腿侧（`ConnectionHandler.stackOfExternalGroup`），块里不再带外部页号。
  顺手修掉本次改造自己引入的一个真 bug：`appendToStack` 原返回 `Bool`，把「墓碑已立」
  与「摞号失效」混成一种，掀摞后的增量会被当新摞重开、墓碑白立——改三态
  `appended / dead / gone`。结果：codex、翻译、`ivox speak` 全都自成摞，Ctrl+1 能整摞掀。

- **codex 侧接上 `turn_id` + 装 Interrupt 收尾（端侧第一步）** — 查 codex 源码发现
  `StopRequest` 与 `InterruptRequest` **都自带 `turn_id`**（`codex-rs/hooks/src/events/`），
  此前 hook 白扔了它（只取正文不带分组），这是「无编号入队」的端侧根因。现
  `hook.sh speak codex` 拿它当分组号，每次回复自成摞。顺带装上 `Interrupt` → `hook.sh end codex`：
  按 Esc 中断时那条路**不走 Stop**，那一摞本来永远等不到收尾信号，只能干等 2 秒空闲宽限；
  `InterruptRequest` 也带 `turn_id`，直接复用 end 分支（只送「说完了」暗号、不出声、不打断）。
  同时订正两处过时文档：`UserPromptSubmit` interrupt 是 2026-10-14（57179ae）**已明确废除**的
  机制（打断权只归快捷键），`write_prompt_hook` 是故意留的 no-op 壳，**不接回**；
  「Claude 的 Stop 没有 `turn_id`」经官方 hooks reference 核实**属实**（通用字段是
  `prompt_id`），错的只是原注释笼统断言没区分两家——现按 Claude/Codex 两路分叉写清。

- **pi 流的边界从 turn 改成 run（Ctrl+1 从「掀不到」变「掀得干净」）** — 查 pi 源码
  （`packages/agent/src/agent-loop.ts`）确认结构是 `agent_start` → N 个 turn 循环 →
  `agent_end`，每个 turn 恰好一条 assistant 消息、工具调用就再来一轮。按 iVox 的词：
  **摞 = 一次输入引发的全部回复 = 一个 run；页 = 一条 assistant 消息 = 一个 turn**。
  而扩展原先在 `turn_end` 关流，等于把「一次输入」切成 N 摞——Ctrl+1 掀一次只掀掉其中
  一页，后面几页照播。这与 codex 那边的「多摞被焊成一摞」是同一问题的两面：**那边掀过头、
  这边掀不到**。现改为 `agent_start` 开流 / `agent_end` 关流，页的边界仍由每条 assistant
  `message_start` 的 `{page}` 帧给出（每个 turn 一页，天然对）。`agent_settled(aborted)`
  的中断路径不变，它本来就是 run 级的。
  顺带核实过、**故意没改**的：扩展仍用 `Math.random()` 造摞号。**外部有没有像样的 id 不重要，
  只要到播报站时能分清是哪一批就行，真号一律由助理自编**——pi 那个随机号在「一轮内稳定」
  这件事上已经够用。反过来，pi 真正的 turn 号 `turnIndex` 每次 `agent_start` 清零、
  跨会话会重复，拿它当摞号反而会坐实「一 turn 一摞」的错切分；真正的页号 `messageEntryId`
  只在 `turn_end` 才有、流式期间拿不到，而页号本来就该由助理自己数。

- **崩溃捕获（`CrashTrap`）** — MLX 后端崩在 C++ 层时系统日志里只有一行
  `mutex lock failed: Invalid argument`，没有调用栈，事后无从判断是哪个路径撞上去的
  （两次「整摞没念完」都查到这里就断了）。现接住 `SIGABRT/SIGSEGV/SIGBUS/SIGILL/SIGFPE`，
  往 `~/.config/ivox/crash.log` 写**带调用栈**的记录，下次启动时把上次崩溃的摘要与栈
  打进 `daemon.log` 再腾空该文件。信号处理函数里只碰异步信号安全的调用
  （`write`/`fsync`/`backtrace`），fd 在启动时就打开好——崩溃时再去 open 或调 Logger
  都可能正好撞上别人持有的锁，死得更难看。

- **日志可观测性补强（一轮全项目审计，25 处，先补了最要命的 5 处）** — 查日志是为了排障，
  「出问题但查不到」比没日志更糟。五处里两处**正好是那场「整摞没了」事故本该留下、
  却没留下的线索**：
  ①`AudioPlayer.write` 开头 `guard started` 会把播放器未就绪时的**每一个音频块无声吃掉**，
  而队列照常打「TTS 合成完成」——听感是「念了却没声」，日志里一切正常。且 `started` 不只在
  启动失败时为假，**音频设备断流后的引擎重建**也会把它置回 false，这是「不崩溃、没日志、
  就是没声音」的一条现实成因。现补 error 级日志（首次 + 每 50 块一条，不刷屏）。
  ②`TTS 合成失败` 那行原本只有一句错误描述，而同一循环里成功/取消/作废三条路径**都带
  `[来源-批次号]`**，偏偏最需要回溯的失败这条不带身份——现补上来源、页号、音色、字数。
  ③媒体控制的七个动作把 `Result` 用 `_ =` 丢掉后无条件回 `success`，没权限时手机上按了
  没反应、日志只有一行动作名；现统一收口，失败如实回传并落日志。
  ④微信链路的请求编码失败与 claude 输出帧解析失败都是静默 `continue`，前者还会照常起
  超时表让「正在输入」转满 300 秒；子进程 stderr 从 DEBUG 提到 WARN（鉴权/额度/参数错都在里面）。
  ⑤长轮询每轮结果改为 INFO（轮次/耗时/消息数），并把「消息处理器没装配」（装配 bug，
  比空轮询严重得多）与「本轮无消息」分开记——此前「微信到底还活着吗」在默认级别下无法回答。

- **推理引擎升到最新（mlx-swift 0.31.6 → 0.32.3）** — `swift package update` 一把升齐：
  `mlx-swift` 跨 7 个版本、`mlx-audio-swift` 跟 main 前进了 4 个提交、`mlx-swift-lm` 3.31.4 → 3.32.3。
  升级撞上一处新的 Swift 6 并发约束：`generateStream(refAudio:)` 加了 `sending`（转移所有权），
  而我们的参考音频缓存把同一个 `MLXArray` 存着又交出去，编译直接报
  `sending 'refAudio' risks causing data races`。用 `@unchecked Sendable` 的盒子包一层解决——
  盒子让 `sending` 检查通过，而**盒内的 `MLXArray` 始终是同一个实例**，这一点不能丢：
  `mlx-audio-swift` 内部靠 `ObjectIdentifier` 认参考音频来复用整份输入准备上下文，
  对象地址每次都变会让那层缓存永不命中。旧版打的那个本地 patch（BreezeTTS 调了不存在的
  `GenerateParameters.seed`）上游已自行修复，随升级消失，无需再维护。

- **`A-tail` 尾音用例的判据修正** — 原判据假设「最后一块合成完时它还没开始播」，拿
  「单独再合成一遍测出的完整时长」的一半当阈值。管道本来就预取领先播放（`B-synthesis-leads-playback`
  验的就是这个），合成完时那块早播了一部分，`gap` 天然只剩剩下的，于是在升级后稳定假红
  （实测三次 `gap` 1.62 / 1.70 / 1.63 秒，而日志里的真实尾音 1.60 / 1.70 / 1.63 秒——两者几乎相等，
  说明音频确实播完才收尾，一个字节没丢）。判据改用日志里的**真实尾音**（收尾那一刻还排在
  播放器里的秒数）：真实尾音 > 0、且 `gap` 覆盖它才算「没被掐」。已做反向验证：
  临时把 `drain` 短路掉（不等尾音），用例立刻红成两条断言。

- **`ivox quick`（快速操作的命令行入口）** — 键盘上的 Opt+Z/A/Q/C 五个都有了对应的命令行，
  动作由 daemon 执行（它们要摸主线程）。自测不必手按热键。

- **Ctrl+Esc 跨会话误杀** — `Ctrl+Esc` 是**全局热键**，拿不到「当前会话」是谁，
  原实现一刀切给所有摞立墓碑：于是你在 Claude 里喊闭嘴，会把 **Codex 正在生成的那摞**
  一起埋掉，它随后送来的字全被丢弃、从此不再开口。现改为**清容器仍是全体**（不管谁在念，
  声音都得停），但**墓碑只埋「播报员此刻在念的那份」**。「已声明、字还在路上」的轮同样按属主挑——
  它们此刻容器里还没有对应的段，只按段立碑会漏掉。新增单测 3 条。

- **播报故事 `docs/playback/paper.md`（新建，播报四层之首）** — 用「一摞纸 / 一张纸 /
  一个字条」把播报讲成一个实物场景：谁在递纸、助理怎么裁、播报员怎么念、你能做哪三件事。
  它不是科普而是**验收基线**——故事里每条主张都能在代码里指出一行，指不出的就是编的。
  文档索引里排在四层第一位，「有分歧先翻它」。

- **打断语义按故事定稿，并连带更正三处文档与实现不符** — ①麦克风（右⌘ 说话）**不递纸**：
  它的唯一动作是让播报员闭嘴，识别出的文字落到光标所在的输入框，是**给 AI 的**，
  全项目没有任何以 `speech` 入队的调用点；此前文档把「麦克风插队」写成特权，实现里根本没有这条路。
  ②`ivox speak` 默认**排队**，是陌生人递的纸，不是特权；要插队须显式 `--now`。
  ③微信链路**不发声**：`WeChatPlatform` 只有 `sendMessage` / `sendTyping` / 长轮询，
  不进播报队列——「聊天窗口里已经有文字了，再念一遍是打扰」这条目的层早已裁定，
  而架构文档与故事文档此前都写着它递纸；不存在的 `ClaudeAskService` 一并清除。
  ④翻译插队**不经过插入队列**（`preemptCurrent` → `appendFirst` → `startPipeline` 抄近路），
  理由是用户亲手递的纸条没有排队这一说。

- **单测按故事重写** — `PlaybackSessionHeadTests` → `PlaybackSessionStoryTests`：
  22 条 → 26 条，**按验收清单 10 条分 MARK**，每条用例的注释第一行就是那句问句本身。
  补上原先没人钉的一条：**只有翻译能插队**（后到的纸一律排队，哪怕更短）。
  文件末尾一张对照表说明另外几条钉在 `make check-tts` 的理由。
  全量 128 条通过；反向验证成立（把插队改成排到队尾 → 4 条变红）。

- **Ctrl+1 掀错摞（场景 15）** — 2026-10-17 18:52 实测：用户按 Ctrl+1 想跳过正在听的「烧完了」那一摞，
  结果把**队列里下一个还没播的摞**整摞掀掉了，正是他刚说过不要的那一摞，全程毫无察觉。
  根因是「用户正在听哪一摞」取自**合成进度**（`commit` 记的是「PCM 已 yield」不是「播完」），
  那东西领先真实发声 2~4 秒，18:52 那一刻两者分属不同的摞。
  改法：引入**发声点**——`AudioPlayer` 在已有的 `dataConsumed` 回调里带上块身份上报，
  消费层只报「哪一块正在被渲染」这个**事实**、不推导起点，身份层据此记录，
  三档打断的起点一律取自它。这条同时把段级和页级统一了（原先只有段级能用队首蒙对，页级会掀错一页）。
  顺带修掉一个同源缺陷：容器原先只增不减，听完的摞一直占着位置，于是播完后随手按 Ctrl+1
  会给一个早已播完、但 Claude **还在继续送页**的摞立墓碑，后续页全被静默丢弃；现在每次泵
  顺手回收「已听完且已收尾」的段。`/health` 新增 `audibleTurn`/`audiblePage` 供观测与断言。
  用词同步定稿：三档打断不再说「当前」，改「我不想听这页了，听下一页 / 我不想听这摞了，听下一摞 /
  当前盖上的摞都不听了」。新增单测 14 条（不碰音频设备），反向验证短掉发声点即变红。

- **两份默认配置统一** — `config.example.json`（`make install` 走它）与 `install-binary.sh`
  （`curl | bash` 内联的那份）此前**键集合与取值都不同**：前者多 `playback`/`translation` 整段、
  `streamingInterval` 是 0.15，后者是 0.08（与 `TTSConfig.default` 一致）。同一个人用两种方式安装
  会拿到不同的默认行为。现已对齐（键、值、音色顺序全一致），并删掉两边都不生效的死键。

- **文档重新分层：按「回答什么问题」分类** —
  起因是三处结构性问题：① 播报四份文档标着「第 N 层」，而**目的层（裁决依据）排在第四**，
  新人顺着编号读要啃完细节才看到「为什么会这么定」；② `playback-queue.md` 一份扛三件事——
  已落地的目标方案、当前实现、事故复盘，346 行且开篇写着「尚未实施」；③ 目录里没有
  「现状 vs 历史」的分类规则，同源内容在两处重复，各自漂移（架构文档整节停在重构前就是这么来的）。
  改法：播报四份移入 `docs/playback/`（按 purpose → sources → requirements → queue 的**阅读顺序**排列，
  去掉「第 N 层」编号，只用名字）；`docs/README.md` 重写为三类索引 + 三条规则；
  `queue.md` 346 → 129 行（目标方案节删除——代码是唯一事实源，其中两条非显然的设计决定留下；
  事故与历史修复清单移入 `archive/incident-playback-queue-fixes.md`）；
  架构文档那一节瘦回「只留地图 + 一句指针」，不再复述实现层细节。
  顺带修掉 CLAUDE.md 里仍在教人用「桶」这个已废止术语的段落，以及一条指向
  `processNext` 末尾 `if jobs.isEmpty` 的失效维护约束（重构后该判断已不存在）。

> 从这里开始，新条目按「一条变更一行、超过 ~120 字符在句读处折行并缩进两格」的规矩写。
> 早先的版本条目是每条一整段的长行（最长一行 4600 字符），diff 时整段变红、不便按行读；
> **历史条目不再重排**——改旧记录的排版会让真正的内容变更淹没在噪音里。

- **播报队列重构：身份层独立成 `PlaybackSession`，游标不再弹出容器** —
  起因是「陈旧靶心」缺陷：掀页后页号没清，第二次按压拿旧页号删掉了后到的内容。
  根因不是忘了清，而是「当前在播什么」住在容器之外（`playingPageID`），容器里没有「当前」。
  改法：把 `段/页/块` 容器与全部身份记账（摞栈、墓碑、页靶心）搬进新 actor `PlaybackSession`，
  游标只记「已播到哪一号」而不取走块——容器因此永远包含正在合成的那块，掀页时它在被删范围内，
  也就不必再靠 `pipelineSeq` 间接作废。
  重构中修掉四个真实缺陷：
  ① 空闲宽限被在跑的管道带死（`P3` 干等 47 秒）——宽限改由队列自己拥有，不等任何管道；
  ② `sweepPages` 用 `remove(at:)` 配 `indices` 遍历，越界崩溃（`iVox-2026-10-17-135311.ips`）；
  ③ 全掀只给已有内容的摞立墓碑，「已声明、块还没到」的摞漏网，打断后同一轮照样开口；
  ④ 领靶心与删除分两步，actor 在 `await` 处可重入，第二次按压会领走同一页（`P2` 曾崩）——
     改成 Session 内一次占位完成。
  全部路径收敛到单一收敛点 `pumpOrSettle()`：有活补起管道、没活收字幕、仍有未封的段就起空闲宽限。
  黑盒自检从 13 条扩到 19 条（新增 `P1/P2/P3` 掀页、`S1/S2` 掀摞与混排、`I1` 插队），全量两轮连绿。

- **修「跳页靶心用完即焚」** — 掀页后页号没清，第二次按压拿旧页号删掉后到的内容。已随上面的重构根治。

- **加日志级别门限，补齐四条日志盲区** — `IVOX_LOG_LEVEL=debug` 才放 DEBUG 行；默认门限使自检里靠 DEBUG 行的断言直接假红。

- **`{now:1}` 字段 + `ivox speak --now`：给「插队」补上第二个入口** —
  Cmd+D 划词译文本来只能由快捷键触发，socket 与 CLI 都没有入口，机器里**唯一被允许插队的那条路没有任何自动化回归保护**。
  现在两个入口落到同一条 `speakUserInitiated`，并新增自检 `I1-insert-front-keeps-queue`
  （译文先播 / 原文照播不丢 / 后续增量不被墓碑拦；摘掉 `isNow` 分支即验证该用例会红）。

- **匿名页（无页号来源）的掀页改为清掉游标所在那一段的块、且不立墓碑** —
  `ivox speak` 这类没有摞可掀的来源此前退化成「只掐在播」，现在掀得干净，又不牵连它的后续增量。

- **文档：播报拆成四层** — 目的层（取舍原则与裁决记录）、接入方层、需求层（场景清单 + 验证手段）、
  技术方案层。术语只留**摞 / 页 / 块**三个并统一成「掐 + 掀」两动词，废止「桶」「assistant」「一句」等旧说法。
  同步修正了 `architecture.md` 停留在重构前的那一节（`anyTurnInFlight` / `sealIdleTurns` / `bargeIn` / `buckets`
  在代码里早已不存在），以及 socket-api 与 hook-chain 里残留的「桶」措辞。

## v4.0.0 — 2026-10-16

- **背景音乐从播报链路整条摘除，只留给语音输入** — 飞哥定调：「音乐只是背景音乐，只是影响麦克风采集」，于是把「播报让路」这整套设计与实现一并删掉。原机制是管道启动 `media.pause()` 借音乐、队列见底 `media.resume()` 还音乐，为此养了三条"何时该还"的判据（管道收尾 / `pumpOrResume` / `resumeIfIdle`）和一串"恢复归属"的边界处理。**而它带来的恰恰是"音乐反复借还"**：Claude 的回复经 MessageDisplay 分批送来，批与批之间的停顿（跑工具、写代码）一超过 2 秒空闲宽限就被误判成"这一摞说完了"→ 还音乐；下一批到达又揭封续播 → 再借。实测 17:30 之后「借了不到 10 秒就还」的有 **17 次**，最短 **0.0 秒**——体感就是"音乐刚回来几秒又被压下去"。修法是**不借就不会乱**：删掉 `processNext` 入口的 pause、管道末尾与 `pumpOrResume` 的 resume、`resumeIfIdle()` 整个方法（连同它的三个调用点），`pumpOrResume` 随之更名 `pumpOrSettle`（"Resume"那一步没了）。保留的只有 **`SpeechInputService` 那一对**（按下录音暂停、松手恢复——录音要干净，音乐会串进麦克风干扰识别）和 `shutdown()` 的退出安全网（与"谁借的"无关，只兜住任何原因留下的暂停）。**副产品**：`idleGraceSeconds = 2` 从此只管"盖章"（桶能否前移、字幕收不收），不再管音乐，抖动无从发生。**自检脚本同步换锚点**：13 个用例里有 12 个靠 `媒体控制: 恢复` 判断"收尾了"，该日志随本次改动消失——`waitSettled` / `probeAudio` / `D` 三处改用新显式打出的 `播报收尾: 队列已空，字幕收起`（在收尾点打，语义比借来的锚点更准）；`A` 的"恢复不得早于最后合成完成"改为同义的"收尾不得早于"。**边界守门人**：现有用例全走非 Claude 路径（脚本从不发 `group`/`page`），改动后 13 条应当一条不挂——挂了就说明边界画错了。

- **修「收尾信号其实一直是哑的」：安装脚本自造了 `End` 这个事件名** — 飞哥在 Claude Code 启动告警里看到一句 `Unknown hook event "End" was ignored`，顺藤摸到根子在 `install-hooks.sh`：它把收尾信号注册到自造的 `End` 事件上，而 Claude Code 只认 `Stop`——**不认识的名字会把整条 hook 静默丢弃**（只在启动告警里带一句，不报错、不提示），于是上一条「Stop 收尾主力」里的实测其实是**手工喂 payload**，真正自动触发一次都没跑起来过，收尾一直靠 2 秒空闲宽限兜着。**当初为什么会写成 `End`**：`write_hook` 拿同一个 `event` 参数既当 settings.json 的键名、又当命令选择开关，而 Claude 与 Codex **共用 `Stop` 这个键**却需要不同命令（Claude 要 `end` 收尾、Codex 要 `speak` 整段播报），一个参数塞不下两件事，就借了 `End` 这个假键当暗号——而它对外根本不是合法事件。修法是把两件事拆开：`write_hook` 新增第 5 个参数 `action`（缺省跟 `event` 走，故 Codex / MessageDisplay 两处调用点一字未改），Claude 收尾改为 `write_hook … 10 Stop end`。**只改键名是错的**：`Stop` 一旦被写进 `case`，Codex（省略后两参 → 默认 `Stop`）就会掉进新分支、被写成 `hook.sh end codex` → Codex 彻底哑掉；这正是脚本第 81 行那句「Codex 仍走 Stop 整段播报，别跟着一起改」在防的事。验证：从真脚本里抽出 `write_hook`、对三个调用点各跑一遍，jq 与 python3 两条写入路径共 6 例全过（`MessageDisplay`/`msgdisplay`、`Stop`/`end`、`Stop`/`speak`）。文档口径同步订正（本条目 + `architecture.md` 表格里"不再挂 Stop"的过时说法）；已有的 `settings.json` 手工改键即可——安装脚本对已有 hook 判「已存在」会跳过，不会再塞坏的键回去。

- **修自检脚本三处「沉默的假绿」（产品行为本就正确，是测试烂了）** — 今天跑全量 `make check-tts` 才发现红了 3 个，逐个查下来**全是测试侧问题**：① `E2`/`E5` grep 的 `流式入队: turn=` 与现在的日志格式对不上（日志中间早插了 `source=`/`page=` 字段，加字段时没同步测试）——一直以为在验、其实永远不匹配；② `E4` 经 `waitSettled` 硬要求"必须有 `媒体控制: 恢复` 日志"，而拆掉「新 turn 盖上」后管道不再每轮重启，"这一轮压根没借过音乐"成了常态，打的 `无需恢复` 被当成没收尾；③ `E7` 被我上次改的噪声检测**自己抓成外部干扰**、整条用例直接 skip（等于白挂）。修法：正则放宽成 `流式入队: .*turn=`、`settled` 判据改为 `(?:恢复|无需恢复)`、自检发的打断信号带 `tag=<runId>` 由服务端记进日志（`handleSkip` 解析）供检测排除。**修完全量 13/13 全绿**（含此前一直被 skip 的 `E7`/`E8`/尾音两组）。教训：check-tts 被定位成"排障工具、不必每次改动都跑"，代价就是测试悄悄腐烂——**改播报核心路径时必须跑它**。

- **拆掉全局 `openGroup`：每摞按自己的 `turn_id` 收尾，「多来源互相盖」这个老毛病一并消失** — 原来收尾靠「新的 turn 来了就把上一个盖上」，而 `openGroup` 是个**全局单值**：两个会话并行时，A 的新轮会关掉 B 正在念的那一摞（文档里一直记为"已知代价"）。现在趁 Stop 钩子复活，把这条判据整个删掉：Stop 的 payload **没有 `turn_id`**（从二进制里挖出的构造是 `{hook_event_name:"Stop", stop_hook_active, last_assistant_message, …session 字段}`），但它有 `session_id`，而 MessageDisplay **两者都有** → 让 msgdisplay 顺手把「这条会话最后一次是哪一摞」记进 `~/.config/ivox/lastturn/<session_id>`，Stop 时反查、**精确点名**收尾（`finishTurn`）。`openGroup`、`closeOpenGroup()`、"盖上上一摞"整块删除；`deadTurns` 从此只由**用户显式作废**的动作来立（跳整摞 / 掀桌 / 取消轮次），不再由"下一轮开始"代劳。**实测**：A 摞在播时 B 摞插入 → 日志里再无「盖上上一摞」，两个收尾信号各自命中自己那一摞。

- **修 daemon 卡死（紧循环）：`waitForJobs` 那句"有货就早返回"拆掉了挂起点** — 上一版给 `waitForJobs` 加空闲宽限时顺手加了 `if hasPendingBuckets { return true }`，以为是"有货就赶紧回去取"。它破坏的正是 `processNext` 里注释明写的约束（「队首空桶正等下一批块时必须挂起，不能 `continue` 重问」）：那个场景下 `hasPendingBuckets` 为真（后面还排着别的桶）而 `frontBucket` 取不到 job，早返回让调用方 `continue` 后**无挂起点地空转** —— 实测 daemon 整个卡死（`/health` 不响应、SIGTERM 被死循环吞掉、只能 `kill -9`），`sample` 抓到 3 秒内 871 个样本全在 `processNext` 的 `checkCancellation` + `waitForJobs` 之间。修法是**恢复无条件挂起**（真有货时入队末尾的 `signalJobs()` 会立刻唤醒，挂起只是一瞬）。复现姿势：发一摞（很短，很快播空 → 空桶但未结束）再紧接着发第二摞（排在它后面）。

- **把 `Stop` 钩子请回来当「收尾主力」** — 空闲宽限修完还剩一件事：**自然播完为何要等**。根子在收尾判据本身——我们当年把 Claude 的 `Stop` 钩子摘了（因为它连正文一起送、与 MessageDisplay 重复播两遍），此后"这一摞说完了"**没有任何信号**，只能靠「新的 turn 来了把它盖上」（可你发完一轮就不发下一条了，这条永远等不到）或等宽限数满。现在把 `Stop` **只当收尾信号**用：`hook.sh end` 丢弃 payload、不带一个字，只发 `ivox speak --final -- ""` → 服务端 `closeOpenGroup()` 立刻收尾（音乐与字幕马上归还）。**两个关键取舍**：① 它**只标 ended、不立墓碑**——Stop 说「我说完了」，但在途的页可能还在路上（钩子异步 + socket 短连并发），立墓碑会把正常内容一起丢掉；**墓碑只在「新 turn 来了」时立**（那一刻"旧轮作废"无可争议）。② 与历史区别：当年挂的是 `hook.sh speak`（送正文 → 重复播两遍），现在这条不出声、不送正文。三者主次因此定案：**① Stop = 主力**（及时）／**② 新 turn 盖上 = 清场 + 兜底**（唯一能立墓碑的）／**③ 2 秒宽限 = 最后兜底**。install-hooks 挂 Claude 的 `Stop` 事件（`hook.sh end`；**不可自造 `End`**——见本节首条），`closeOpenGroup()` 的日志从「手动信号」改成「收尾信号（这一摞说完了）」（它早就不止手动来）。**实测**：手动喂一次 Stop payload → `收尾信号（这一摞说完了）: turn=ee22145f…` 立刻生效；自动触发需**新开 Claude Code 会话**（钩子配置在会话启动时加载）。

- **修「播完音乐不恢复、字幕不收起」（上一版列为已知代价的那个，其实是每轮必中）** — 飞哥报"按快捷键跳页、后面没内容后音乐没恢复"，复现时发现**自然播完也一样卡**，不是边缘情况。根因在一行判断：队列判"这摞说完没有"用的是 `anyTurnInFlight = buckets.contains { turnID != nil && !ended }`，而块播完后**桶壳还留着且 `ended == false`**——弱分组（Claude 的 `turn_id`）的结束信号是「新的 turn 来了把它盖上」，可**用户说完一轮之后不会有下一条 turn**，于是这一摞永远挂着"未结束"，收尾条件（恢复音乐 + `onCaption(nil)` 收字幕）永不成立，音乐与字幕双双卡死。修法是给保活加一道**空闲宽限**（`idleGraceSeconds`；初版 8 秒，飞哥当场定成 **2 秒**，并把计时起点从「最后一块被取走去合成」挪到**「设备播空、声音真停下」**——否则那块还在响、宽限已经在走，音乐回来会盖住尾音；等播空的上限 `maxSilenceWaitSeconds`=10 秒，防设备卡死把起点也带死）：`waitForJobs()` 从"无限等新块"改为"最多等 8 秒"，超时唤醒返回 false → `sealIdleTurns()` 把未结束的桶一并盖上（**不立墓碑**——那只是猜"说完"不是判死），下一圈自然走进收尾。两处挂起点都接了：队列全空 + 队首桶播空。配一条「揭封」：`enqueue`/`enqueueGrouped` 往已有桶追加时把 `ended` 重置为 false（猜错了就继续播）。continuation 生命周期用引用类型 `JobWaiter` 保证「入队唤醒」与「宽限超时」互斥摘除，双 resume 会 fatal crash。**四种组合实测全过**（`ivox skip` 与热键同路径）：Ctrl+2/Ctrl+1 × 后面有内容 → 先接着播、播完 `空闲 8秒无新内容，判定说完了：盖上 C1` + `媒体控制: 恢复`；× 后面没内容 → 跳的同一毫秒就 `媒体控制: 恢复`。文档四处口径同步（原写着"不用定时器"，已不成立）。

- **播报字幕固定主屏（不再跟着键盘焦点跑）** — `CaptionPanel` 定位用的是 `NSScreen.main`，而那是**键盘焦点所在屏**、不是主屏（名字有误导性）：多屏下焦点一动，字幕就跟着跑到别的屏去，人在自己那块屏上反而看不见。实测坐实：改前日志 `播报字幕: 927×47 @ (496,-995)`（别块屏的负 y），改后同一次播报为 `521×47 @ (699,24)`——y 变正、贴主屏底边，x=699 正好是 1920 宽主屏上的居中位（(1920−521)/2）。改为固定 `NSScreen.screens.first`（含菜单栏那块），类文档里那句写死旧行为的说明同步更新。**同类问题只提醒未动**：语音输入浮窗 `OverlayPanel` 用的还是同一个 `NSScreen.main`。

- **`ivox quiet` 退场、`ivox skip` 收编三档；`{type:stop}` 停止帧随之删除** — 上一版顺带发现 `ivox quiet` 是空操作（它发的 `{type:stop}` 早被忽略），实测日志确认：`收到停止帧，忽略：…(source=probe)`。查下去还有两处连带：自检脚本 `quiet()` 助手与 **E7 用例**发的是同一个帧（该用例断言"全场打断后该轮不该再有合成开始"，哨兵失效则必红），文档里 5 处"`ivox quiet` 手动能力保留"也已是错话。定案**不复活旧帧**（那会把一个已明确废弃的协议重新请回来，且它无换行、走的是正文分支），改为**统一到 `{type:skip}` 一条通道**：三档参数 `--page` / `--stack` / `--all` 与三个快捷键一一对应（缺省 `--page`），新增 `mode:all`（= Ctrl+Esc 那档，两行 `cancelAll` + `resumeIfIdle`，少一行就与热键行为不一致），`ivox quiet` 命令删除（文件走 trash 入废纸篓），自检脚本 `quiet()` 改名 `skipAll()`、E7 注释与文案同步，**E7 实测回绿且一行断言没改**（`ok 1 E7-stop-sentinel-buries-live-turn`）。另修掉一条**沉默的假绿检测**：脚本里判"外部打断"的正则 `/收到停止播放指令/` 早在某版文案改动时就再无命中源——换成 `/跳过请求: mode=/`。`{type:stop}` 服务端那一支**保留作护栏**（不是死代码：它无换行、落进 `handleTTS` 正文分支，删掉会让旧脚本发来的停止帧被 cleanText 洗一遍**当内容念出来**）。**三档实测**：`--page`（一页 105 字切成 2 块）→ `本页剩余块已丢: page=… 块=1`，丢 1 块留 1 块、下一页那块接着念；`--stack` → `丢 turn=… 余 1 块，从下一桶接着播`；`--all` → `媒体控制: 恢复` + health `queued=0 playing=false`；两个开关同给 → `Error: --page / --stack / --all 只能给一个`；`ivox --help` 里 `quiet` 已消失。

- **`ivox skip` / `ivox skip --stack`：给两个打断热键配命令行对应物** — 新增 `{type:skip,mode:page|stack}` 请求与 `skip` 子命令，落到 `PlaybackQueue.skipCurrentPage` / `skipCurrentBucket`，**与 Ctrl+2 / Ctrl+1 是同一条代码路径**（热键只多一层按键识别）。用途是自检脚本、压测、远程排查——之前只有热键一条入口，没法不按按键地验证翻页。踩到的边界：`{type:stop}` 发的是无换行裸串，走 `handleTTS` 分支（首行切不出 header 就没有 header 可路由）；`skip` 头**必须带尾随 `\n`** 才进得去分发。同时给翻页补一行日志 `本页剩余块已丢: page=… 块=N`——翻页成功与"靶心没对上"在外部看起来一样（都是没声音），只有这行能区分。**实测**：一摞两页入队（`turn=SMOKE1 page=SMOKE1P0 分块=2` / `page=SMOKE1P1 分块=1`）后按下 skip → `读下一页（来源=skip-page）：丢掉当前页（SMOKE1P0）的剩余块` + `本页剩余块已丢: page=SMOKE1P0 块=1`，随后只有一次 `TTS 流式开始` = 第二页那 1 块接着念（账目对得上：丢 1 留 1）；`--stack` 变体 → `丢 turn=SMOKE2 余 1 块，从下一桶接着播`，后面另一摞照常轮到。**顺带发现（已在下一条处理）**：`ivox quiet` 发的是已被忽略的 `{type:stop}`，现在是个空操作——hook.sh 的 interrupt 分支摘掉后它就没了消费者。

- **pi 链路补上「页」，Ctrl+2 在 pi 上也成了「读下一页」** — Claude 那条通路已经有"页"（= 一个 MessageDisplay），pi 这边还没有：它的块只带轮次号，Ctrl+2 只能退化成跳块。补法与 Claude 同构——**一条 assistant message = 一页**：扩展在 `message_start`（role=assistant）时发一帧 `{page}`，服务端认它把页号 +1，此后 flush 出来的块都带上 `page=<turn>#<序>`。页号由**服务端自己数**（扩展只要说"翻页了"，不需要给 id）；**队列侧一行没改**——`playingPageID` 本来就是从 claim 的 job 上取的，两条通路通用。两个刻意的取舍：① 不在这里开流（`turnId` 为空就跳过，交给 `message_update` 的兜底）——两处都开流会各开一条、互相顶，文件注释里记着这个坑；② 没用"一次 flush = 一页"（服务端能白捡），因为 flush 本身就是 24～80 字的块群，那样一页往往只剩一个块、Ctrl+2 又变回跳块。实测：手工造一条含 `{page}` 的 pi 流 → `page=TESTTURN#0` / `#1` 正确翻页。

- **Ctrl+2 从「跳播放块」改成「读下一页」** — 原来它跳的是"正在播的那一个播放块"，而**块是内部切分的产物，用户听不出它的边界在哪**——跳一块没有意义。现在换成用户真正感知的两层单位：**一页 = 一个 MessageDisplay**、**一摞 = 一次回复**（块退回纯内部概念）。做法：`hook.sh` 除了 `--group <turn_id>`（摞）再多传 `--page <message_id>`（页），页号一路带进 `PlaybackJob.pageID`；队列在 claim（把块弹出桶去合成）时把它记进 `playingPageID`——**这一笔必须记**：正在念的那块早已不在桶里，光看桶认不出它属于哪页。Ctrl+2 按下 = 掐在播 + 丢掉桶里 `pageID == 当前页` 的剩余块 + 从下一页的第一块接着念（同桶里后面几页的块原样留着，这才是"翻页"而不是"跳桶"）。三档至此与比喻完全对齐：**页 / 摞 / 全场**。改名 `skipCurrentSentence` → `skipCurrentPage`、`InterruptSource.skipSentence` → `.skipPage`（含 GlobalKeyTap / Daemon / QuickActionsService 三处调用点）。

- **Claude 的桶从「页」改回「摞」：按 `turn_id` 装桶，新 turn 来了就把上一个盖上** — 上一版拿 `message_id` 当分组号，而那是**一条 assistant message（一页）**的身份；一次回复夹了工具调用就会有好几页（实测：一次回复 = 5 条 message、13 次 MessageDisplay、跨 13 秒）→「一桶」被拆成一页一桶，「跳整摞」只好一页一页跳。查 Claude Code 官方文档确认 `MessageDisplay` 的 payload 里**本来就有 `turn_id`**（同一回合的所有 message 共用同一个值），换成它当分组号，「一桶 = 一摞 = 一次回复」立刻成立。**收尾判据同时定案**：不挂 `Stop` 钩子、也不用定时器，就是**「新的 turn 来了就把上一个盖上」**；盖上时**同时立墓碑**，老桶里再来的页一律丢掉（定案三条：新 turn 盖上、新内容装新桶、老桶再来新的丢掉）。页级 `final` 不再参与收尾——它只说明"这一页说完"，认不得"整摞说完"。**实测抓到两个自己写出来的 bug**：① 多来源交错时"盖上一个"会互相盖；② 顺序写反——一个**已死** turn 的迟到页会先盖掉当前活跃的那一摞、再把自己丢掉，顺手把活的也打死（日志铁证：`丢弃 PP` 的前一行正是 `盖上 QQ`）。②已修（墓碑检查提到"盖上一个"之前），修后四个断言全过。**已知代价（未处理）**：多个来源交错时仍会互相盖 → 那一摞可能被拆成几个桶；单个来源（日常）不触发。**播放侧影响先搁置**：没有 Stop，最后一摞播完后管道会挂起等下一批，音乐不会自己恢复。

- **`make update` 失败/被中断会回滚（备份范围 = 部署范围）** — update 的链路长（备份 → off → 编译 → 部署二进制+资源包 → 重签 → 同步集成资产 → on），任何一步没过、或跑到一半被 Ctrl-C/中断，都会留下「服务已经停了、部署物可能还是半截的」状态；而 `stop` 现在就是 `ivox off`（会 disable），连下次登录都不会自己回来。**今天实测撞上一次**：`make update` 跑到第 71 秒被打断，服务就此停摆、要手动 `ivox on` 才回来。处置：`make update` 改为 `snapshot → stop → build → deploy-bin → start`，用 shell `trap … EXIT` 兜底——**任何非成功退出（含 SIGINT）都走 `runtime.sh rollback`**：还原上一版二进制/资源包/集成资产并重新拉起服务，全部成功才 `discard-snapshot` 丢掉备份。备份范围＝部署范围的镜像（`deploy-bin` 覆盖什么就备什么），刻意不碰 settings.json——那是各 agent 自己的配置，install-hooks 对它只写不删，回滚去改就越界了。**配套修正**：`ivox on` 30 秒内没起来，以前只打印一句警告、**退出码仍是 0**——新二进制一崩就会被误判成「更新成功」，回滚根本没有触发点；现改为返回非 0（`install-binary.sh` 本来就在等这个非 0，此前那句 `if ! ivox on` 从未真正生效过）。

- **Claude 的播报改成「一轮一桶」+ 打断跳得干净（`hook.sh` 传 `message_id` / `final`）** — 此前 Claude 走「无 turnID 的普通播报」，服务端靠「队尾还是不是同种桶」把连续几批 delta **凑**成一桶。凑出来的桶边界不是语义边界，于是 Ctrl+1「跳整轮」跳不干净——跳掉的是**此刻已到的部分**，同一条回复的后续批次几百毫秒后又开一桶接着念；Ctrl+Esc 掀桌同理掀不干净。根因是那批字没有身份：Claude 的 payload 里其实**有** `message_id`（哪条回复）和 `final`（这条说完没），`hook.sh` 只拿它们写了行审计日志、没往下传。现按实测规律传下去（`ivox speak --group/--final`，协议见 socket-api.md）：**`message_id` 当分组号**（同一条回复的多批并进同一桶）、**`final` 当收尾信号**（桶开着直到这批，中途播空也不弹——否则 Claude 一停顿去调工具，一轮就被拆成几个桶）。三处刻意隔离：① 分组号**绝不进 `turnStack`**——那是 pi 双流「属主交还」的认证栈，混入别的 id 会让 pi 的正文流被判成过期旧轮、**整轮没声音**；② `skipCurrentBucket` 改为丢**该轮全部桶**（弱分组下一轮可能散在几个桶里，只弹队首会留残部继续念）；③ `buryAllTurns` 补捞桶里的分组号（它们不在 `turnStack` 里，不捞就掀不干净）。**兜底不加定时器**：换新分组即收尾上一组——`final` 丢包（日志实测 1357 条**0 丢**，但「会话被杀」那种没有样本）只要之后还有播报就能自动解开。另：`final` 批即使 delta 为空也必须发，漏了它桶就一直开着、堵住后面所有播报。实测三条边界（正常分组 / 空尾批 / 故意丢 final 靠兜底）均正常收尾，`playing:false`、`queued:0`。

- **启停命令简化回 `ivox on` / `ivox off`，`off` 语义定为「卸 job + disable + 停服务」** — 上一条把启停收进 `ivox autostart on|off` 两层名字，日常难敲。恢复 `ivox on`（配置 launchd + 启动）与 `ivox off`（卸下 launchd job + 停止服务）这对短命令，`autostart` 一层整个拿掉：`AutostartCommand.swift` → `LaunchAgent.swift`（`LaunchAgent` 底座 + `OnCommand` / `OffCommand`），`EntryPoint`、`ServeCommand` / `UpgradeCommand` / `WeChatSetupCommand` 的调用与文案、`runtime.sh` / `install-binary.sh` / `tts-check.mjs` / `Makefile`、README / CLAUDE.md 全部同步。**关键：没有退回旧版的两套实现**——`on/off` 底下仍只有 launchd 一条路径，上一条删掉 nohup 手动模式的两个理由（KeepAlive 把停止信号拉回、`cp` 覆盖活进程二进制致签名失配）依然成立。**`off` 关自启的手法同时换掉**：旧 `ivox autostart off` 靠 `removeItem` **删 plist** 来关自启——plist 一没，`on` 必须整个重写；现改为 `launchctl disable`，plist 留着、launchd 登录时不再加载，`on` 里配一句 `enable` 即原样恢复（**先 enable 再 bootstrap，顺序不可调换**——被 disable 的 job 是 bootstrap 不进去的）。`runtime.sh` 的 `stop`/`start` 索性改成**直接调 `ivox off` / `ivox on`**，删掉自拼的 launchctl（约 35 行）与 `daemon_alive` 探针——两处各写一套正是「同样叫停、语义却不同」的老毛病，这轮就栽在它上面。于是 `make update` 成为字面的 **off → 编译 → 部署 → on**，跑完服务在跑、自启开着。**实测补记**：被 disable 的服务 `bootstrap` 报的是 `Bootstrap failed: 5: Input/output error`，与「job 已加载 → EEXIST」**同一个错**，没法从报错区分原因，所以 `on` 里 enable 只能放在 bootstrap 之前靠顺序兜住。**顺带修掉一个孤儿**：`runtime.sh uninstall` 调的 `ivox stop` 子命令早已不存在（被 `|| true` 吞掉，卸载时守护进程压根没停），改为直接 `launchctl bootout` 并补删 plist——否则 launchd 下次登录会去拉一个已被删掉的二进制。

## v3.9.0 — 2026-10-16

- **修复「同样内容播两遍」：这次真正摘掉了 Claude 的 Stop 钩子** — v3.8.0 宣称「摘 Stop、只留 MessageDisplay」，但那次 commit 实际只把 `UserPromptSubmit` 置成了 no-op，`install-hooks.sh` 的 Claude 分支**仍是默认 `event=Stop`**；而该脚本是「有则跳过、无则补写」，于是每次 `make update` 都把 Stop 留住/补回。结果 `settings.json` 里 Stop 与 MessageDisplay 并存——MessageDisplay 已把回复逐段播完（final 批含完整结尾），Stop 又拿 `last_assistant_message` **整条再念一遍**。日志实证：相邻两条请求，55 字（MessageDisplay 末批）+ 983 字（Stop 重播）。处置：Claude 分支改挂 **MessageDisplay**，`write_hook` 补 `MessageDisplay` 事件分派；`install-hooks.sh` 守住「**只写不删**」的边界（存量 Stop 须人工摘除，已写进 architecture.md 与脚本注释）。Codex / Qwen 无 MessageDisplay 事件，仍走 Stop（Qwen 见下条已下线）。
- **下线 Qwen Code 与 DeepSeek Harness 支持（快捷键 + 播报）** — 项目不再支持这两个 agent，一次摘干净：删 QuickActions 的 `Opt+Q`（原「开终端跑 qwen」，三处枚举同改）、`install-hooks.sh` 的 Qwen 与 DSH 两个分支（后者含 cordis 插件铺装与 `cordis.patch.yml` 挂载）、`integrations/dsh/` 整个目录、配置模板 `sourceVoices` 里的 `qwen`/`dsh` 键，并同步 `CLAUDE.md` / `architecture.md` / `hook-chain.md`（含整篇 `dsh-tts.md`）/ `README.md` 等文档。**顺带堵住一个坑**：素材源探测判据原为「同级同时有 `pi/` 与 `dsh/`」，删掉 `dsh/` 后它在部署态永远不成立、会落到不存在的 `../integrations` —— 已改为只看 `pi/`。**特意没动** `Qwen3-TTS`/`Qwen3-ASR`（本地模型名，与 Qwen Code 无关）与 CHANGELOG/archive 的历史条目。
- **QuickActions 键位重排：codex 移到 `Opt+X`、pi 移到 `Opt+Q`** — `Opt+Q` 随 Qwen Code 下线空出，pi 从 `Opt+X` 挪过去、codex 从 `Opt+W` 挪到 `Opt+X`；`Opt+W` 就此空出（不再绑定任何动作）。现在左手区是 `Opt+Z`（裸终端）/ `Opt+A`（claude）/ `Opt+Q`（pi）/ `Opt+X`（codex）/ `Opt+C`（复制路径）。`GlobalKeyTap` 的 enum/binding、`Daemon` 分派、`QuickActionsService`、两处启动日志串与全部文档同步改。
- **启停收归 `ivox autostart`，删除 `ivox on` / `off` / `restart`** — 两套启停并存（`on/off` 的 nohup 手动模式 vs LaunchAgent 托管）是 `make update` 那三个报错的土壤：`ivox off` 发的停止信号会被 KeepAlive 立刻拉回（总误报「守护进程未退出」），而 `deploy-bin` 又在进程活着时 `cp` 覆盖二进制 → macOS 判签名失配（`OS_REASON_CODESIGNING`）把进程杀掉，极端情况 launchd 还可能拉起到**写了一半的文件**。现在只有一个入口：**`ivox autostart on`**（起 + 开登录自启）、**`ivox autostart off`**（停 + 关自启）。`autostart on` 做成**幂等**——未加载 `bootstrap`、已加载 `kickstart -k`（`ivox upgrade`、微信授权后重启都靠它，此前那种「bootstrap 失败只打印一句提示」在 job 已加载时等于漏重启）；就绪窗口 10s → **30s**（模型加载 + 键盘层权限轮询实测要十几秒，10s 必然误报）。`runtime.sh` 的 `stop`/`start` 不再分叉，一律 `launchctl bootout` → 编译覆盖 → `bootstrap`，且**只卸 job、不删 plist**——中途失败也不会丢登录自启配置。
- **安装即启动**：`install-binary.sh` 与 `make install` 收尾直接 `ivox autostart on`（前者失败只提示、不中断安装）。README 里「安装完服务已在后台运行」那句至此名副其实。
- **QuickActions 换用 Ghostty 开终端，删掉临时 `.command` 那一套** — Terminal.app 没有 CLI 参数能「指定目录 + 执行命令」，只能在两条都不理想的路里选：AppleScript `do script`（要多一份 **Terminal 的 Automation 授权**，且 iDict 时代有双窗问题）或写临时 `.command`（要回收 + mtime 竞态）。Ghostty 的 `--working-directory` + `--initial-command` 是原生参数，一条 LaunchServices 调用就够——`makeCommandFile` / `cleanupOldCommandFiles` 连同注释共约 40 行**整个删除**。三个实测坑都记进了代码注释：① 参数必须经 `NSWorkspace.OpenConfiguration.arguments` 下发（命令行 `open --args` 会把含空格的参数**拆坏**，数组则保留边界）；② **必须配 `createsNewApplicationInstance`**——复用已运行的 Ghostty 实例时参数会被**静默忽略**（命令根本不跑），代价是每开一次多一个 Ghostty 进程；③ **不能用 `-e`**——它每次都会弹 macOS 的「Allow Ghostty to execute」确认框（Ghostty 针对沙箱逃逸报告加的安全机制，目前无配置项可关，issue #8648 仍在讨论），`--initial-command` 不走那条通道。命令仍写 `/bin/zsh -lc <cmd>` 套一层 login shell：`initial-command` 默认经 `/bin/bash --noprofile --norc -c` 执行，而 `/opt/homebrew/bin`、`~/.local/bin` 都不在 GUI 进程的最小 PATH 里。实测进程链 `Ghostty → /usr/bin/login → bash -c → zsh -lc → claude` 完整跑通。

## v3.8.0 — 2026-10-14

- **Claude 会话过程内容逐句播报（MessageDisplay 钩子）+ 播报去重收敛** — 交互式 Claude Code 会话里「提交后过程回复听不见」：此前只靠 `Stop` 钩子在回复写完一次性播最终文本，分步/工具多段的中间过程没通路进 ivox。现改用 **`MessageDisplay` 钩子**（`hook.sh msgdisplay claude`）——assistant 消息流式显示时按行批触发，`delta` 增量逐句进桶播报，过程（第一步/第二步…）边写边播，最后一条 assistant 即完整结尾。**修复播两遍**：根因是 MessageDisplay 的 final 批已含完整结尾、与 `Stop` 的 `last_assistant_message` 同播重复，且 `make update` 经 `install-hooks.sh` 把 UserPromptSubmit interrupt 写回 settings.json、提交即触发打断叠加错乱。处置：摘 `Stop`（只留 MessageDisplay）、摘 `UserPromptSubmit`、`hook.sh` 移除 **interrupt 分支**（`ivox quiet` 手动能力保留）、`install-hooks.sh` 的 `write_prompt_hook` 置 no-op（不再自动挂提交打断）。`MessageDisplay` 钩子须极快返回（Claude 等它渲染该批）。**微信链路只拿 assistant 帧**——最后一条 assistant 即结尾，不单独取 result（内容重复），`askStreaming` 简化为只回调过程段、去重逻辑删除。

## v3.7.0 — 2026-10-14

- **打断权收紧为「仅快捷键」：按轮分桶排队、播全播完** — 用户「什么都没干也老被打断」的根因：打断来源几乎全是 `stop:claude`（Claude Code 的 `UserPromptSubmit` 钩子每个会话轮次都触发）与流式新轮顶替。现打断权**只归用户快捷键**——right⌘ 说话、Cmd+D 译文、Ctrl+Esc 闭嘴；`{type:stop}` 停止帧**完全失效**（已摘除 `~/.claude/settings.json` 的 UserPromptSubmit interrupt 钩子，daemon 收到停止帧只记日志忽略）。PlaybackQueue 从「单一 `jobs` 数组 + 单值 `currentTurn` 门控」重构为**有序 `QueueBucket`（每轮一桶）**：新 turn 排队不打断、队首桶播完才前移 = 「播全播完」；全局 `turnOpen` 单布尔改为 `anyTurnInFlight`（由每桶 `ended` 推导），修多轮按序排队时最后一桶播完音乐不恢复的误判。验证：`make build`+单测 108 ✓+混合队列压测（Claude 普通播报串联 pi 双流）顺序正确、零自动打断、末尾音乐正常恢复、`ivox status` 六域 ✓
- **Ctrl+Esc 手动闭嘴快捷键** — 新增打断键：不录音，只静音当前播报 + 恢复音乐（语义同停止帧，与 right⌘「说话+暂停音乐」互补）。用户嫌「没干什么老被打断」后定位到 `stop:claude`，此为手动替代方案，实测顺手
- **`ivox autostart on|off`：daemon 登录自启 + 崩溃自动重启（LaunchAgent）** — daemon 原靠 `ivox on`（nohup）手动拉起、无 launchd，登录后要手动开、崩了没人管。新增 `ivox autostart on`：写 `~/Library/LaunchAgents/com.ivox.daemon.plist`（RunAtLoad 登录自启 + KeepAlive 崩溃自动重启，launchctl bootstrap 接管）并启停当前手动 daemon；`ivox autostart off`：bootout 停 + 删 plist。`ivox off` 在 KeepAlive 下已不能真停——要停得 `ivox autostart off`。**配套**：`RestartCommand`（`ivox on` / `make update` 都走它）感知 autostart——已托管时改用 `launchctl kickstart -k` 让 launchd 用当前部署的二进制重载 job，不做「发停止+nohup 拉起」否则会被 KeepAlive 立刻用旧二进制拉起、重启失效。实测：`autostart on` 后 daemon 父进程=launchd；`kill -9` daemon 自动重启（新 PID）；`ivox on`/`make update` 后 daemon 仍是 launchd 托管、健康
- **`toggleApp` 真实回检：open 后确认进程真起来，不误报 opened** — 排查「Web 控制台打开不开 app」时发现：`/usr/bin/open` 命令发出返回 0，但系统 LaunchServices 缓存异常时进程根本不出现，`openApp` 却照记「应用已启动」、toggle 返回 `opened`，让人抓瞎（日志看着成功、实际没开）。现 `openApp` 在 `open` 后轮询 `NSRunningApplication` 该 bundleID ≤5s，进程真出现才判成功，超时判 failed 返回前端。额外收获：这次排查也坐实了「打开不 app」是系统层（重启/重建 metal 缓存后恢复），与 Web UI/index.html 无关
- **`cancelAll` 剥离媒体控制：改由各能力域自理音乐暂停/恢复** — 语音输入「按快捷键说话音乐没停」的根因：`cancelAll` 内部 `pumpOrResume` 会在打断后悄悄 `media.resume()` 恢复音乐，而语音输入按下要的是「打断 + 保持暂停」，两个意图打架、resume 常把刚暂停的音乐又放回来。现把媒体控制从 `cancelAll` 彻底剥掉——它只做**打断清场**（作废全部流式轮 + 清在播 + 关 turn），音乐归调用方自理：语音输入按下 `pause` / 松开 `resumeIfIdle`、停止帧打断后 ConnectionHandler `resumeIfIdle`、Cmd+D 对话/pi·dsh 新轮交给 `processNext` 播报管道、Escape 自取消 `cancelTurn` 自身恢复。连带修复两个隐藏回归：`resumeIfIdle` 需先等**被取消的管道退净**再恢复（否则打断正播的一句后音乐会卡暂停，历史修过两次）；`cancelAll` 不再猜「是否要恢复音乐」。
- **hook.sh 动作参数改「动词在前」：`hook.sh speak|interrupt <source>`** — 原 `hook.sh <source> [say|interrupt]` 里 `say` 是假的（脚本只判了 `$2 == interrupt`，写不写 say 都一样）、且 source 打头可读性差。改为动作动词在前：`hook.sh speak claude`（念 claude 回复，底层 `ivox speak`，动词取自它自己）与 `hook.sh interrupt claude`（打断，来源 claude），一读即知这 hook 干什么。`install-hooks.sh` 挂载命令与存在检测同步为 `hook.sh speak <tool>` / `hook.sh interrupt <tool>`，并自动把历史旧格式（`hook.sh <tool> interrupt` 打尾、`hook.sh interrupt` 无来源）迁移成新格式；hook.sh 本体对 `hook.sh <source> [interrupt]` 旧调用做兼容。实测 `hook.sh speak claude` → 播报 `source=claude`、`hook.sh interrupt claude` → 打断来源 `stop:claude` 都正确
- **打断全链路带来源标识（`InterruptSource`）** — 播报侧 `PlaybackJob.source` 早已带（TTS 合成 `[source-batch]`），但打断侧是断开的：停止帧在 `ConnectionHandler` 记了来源，一进 `cancelAll()/bargeIn()` 就截断，引擎 TTS 取消、player 取消的日志都带不出「是谁掐的」。现引入 `InterruptSource`，覆盖打断的本质——**「用户开口」的三种方式**：①在 agent 里发消息（非流式 agent 提交瞬间的停止帧 `{type:stop,source:x}`→`stop:x`，流式 agent 发新消息的新轮→`turn:<source>`）、②说话（right⌘/right⌃→`speech`）、③划词翻译（Cmd+D→`dict`），另加退出清场→`shutdown`。`cancelAll`/`bargeIn`/`speakUserInitiated`/`beginTurn` 均带来源，`lastInterrupt` 一路传到引擎（`TTS 合成已取消（打断来源=…）`）；processNext 的完成日志在被掐时改打「合成作废（MLX 不响应中途取消…）」——否则打断后紧邻的「完成」会被人误读成「没掐住」。Escape 放弃自己那轮（`cancelTurn`）是**自取消**不是抢占，不进打断来源。顺手修了 `流式入队` 日志漏 source。实测 `bash hook.sh claude interrupt` → 打断→引擎取消→作废三条日志全部对上 `stop:claude`
- **源码目录按能力域重排** — `TTS/` 与 `Audio/` 是按**技术层**分的，于是 6 个能力域里只有 4 个有对应目录：自动播报横跨 `TTS/`（TTSEngine）与 `Audio/`（PlaybackQueue、AudioPlayer），媒体控制则埋在 `Audio/`（MediaController、MediaHTTPServer、AudioAppRegistry、HealthSnapshot）。现拆成 **`Playback/`**（自动播报三件套）与 **`MediaControl/`**（媒体控制四件套），六个能力域各一个目录，与 README 功能表、`ivox status` 一一对应；基础设施 `HotKey/` `Network/` `Daemon/` `Commands/` `Utilities/` `Resources/` 保持独立。**纯文件移动，SwiftPM 同 target 内零代码改动**（`make build` 直接过）
- **`ivox status` 补全「自动播报」并按能力排序** — 原来漏了最核心的 TTS 自动播报，且顺序随意（语音输入 / 微信桥接 / 媒体控制 / Web UI / 划词翻译 / 快速操作）。现列出六项能力：自动播报 / 语音输入 / 划词翻译 / 快速操作 / 微信桥接 / 媒体控制。**媒体控制即那个 Web 控制台**（打开 `127.0.0.1:8888` 远程控制音乐播放/切歌/音量），它的健康度就是 Web 服务的健康度，因此不再单列「Web UI」一行。`DaemonStatus.Features` 加 `playback`（TTS 模型就绪 → `ok`，未就绪 → `loading`），`health()` 认这个新状态显示「… 加载中」。README 功能表同步加「媒体控制」一行。六个能力域**彼此平级**——它们之间有协作（播报会暂停音乐、语音输入会打断播报、划词翻译借播报念译文），但没有主从；`DaemonStatus.Features` 也据此收敛为六个字段（删掉与 `mediaControl` 同值的冗余 `mediaHTTP`）
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

- architecture.md「ClaudeAskService」章节改写为原生直连；README 删 Node 依赖、架构图更新；调研文档 `native-bridge.md` 状态改为已实施。

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

- **支持 DeepSeek Harness 语音播报（插件直投）** — desktop profile 以 `- insert:` 挂载本地插件 `./plugins/ivox-tts.mjs`（`name` 以 `.` 开头时按 profile 目录解析，无需改 app.asar、无需 pnpm）；插件在 `session/event` 缓存候选消息（规则见 当时的 `docs/dsh-tts.md`），`agent/turn-stopping` 时 spawn `hook.sh dsh` 把原文写进 `last_assistant_message`。默认音色湾湾。详见 当时的 `docs/dsh-tts.md`

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
- 新增 `docs/audio-player-drain.md` 固化问题与三层解决方案（超时兜底 / 世代计数 / `.dataConsumed`），`docs/playback/queue.md` 同步维护约束

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
