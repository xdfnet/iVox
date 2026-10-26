import Foundation

// 默认配置模板：**外部配置的说明书**。
//
// 为什么放在代码里而不是资源文件：装机脚本、`ivox init-config`、微信配置命令都要用同一份，
// 散成两处迟早漂。放这里 = 单一真源，改一处全体生效。
//
// 为什么是 TOML：能写注释。配置里最需要说明的就是「这一项是干嘛的」「我为什么改成这样」，
// JSON 写不了注释，就只能靠记忆。
//
// **注释规范（2026-10-24 统一）**：每一项的注释**写在行尾**，一律三段——**是什么 ｜ 默认值 ｜ 可选值**，
// 全文件只有这一种风格（键名不重复，键就在左边）。需要展开说明的项，在它**上一行**另起一行、
// 以 `#   ` 缩进写补充。默认值取自代码里的真源（`Config.swift` 各类型的 `default`），别抄错。

public enum ConfigTemplate {
    /// 默认配置全文（TOML）。`ivox init-config` 写的就是它。
    public static let tomlText = #"""
# iVox 配置
#
# 格式是 TOML：`#` 后面是注释，方括号是段名，等号右边是值。
# 改完跑一次 `ivox restart` 生效（只重启守护进程，不动开机自启开关）。
#
# **每一项的注释写在行尾，统一三段：是什么 ｜ 默认值 ｜ 可选值**——照「可选值」那一栏填就行。
# 需要展开说明的项，在它上面另起一行、以 `#   ` 缩进写补充。
# 键名一律驼峰；写错的键不会静默，启动日志里会被点名（`ivox status` 里也看得到）。
# 项的顺序按功能排，不是字母序。

# ── 快捷键 ─────────────────────────────────────────────
# 键位写法：cmd / ctrl / opt / shift + 主键，用 + 连接（大小写无所谓）。
# 主键可用：a-z、0-9、esc、space、tab、return、backspace、delete、f1-f12、方向键。
[hotkeys]
openTerminal = "opt+q"          # 开终端 ｜ 默认 opt+q ｜ 任意组合键
openTerminalClaude = "opt+a"    # 开终端并跑 claude ｜ 默认 opt+a ｜ 任意组合键
openTerminalCodex = "opt+x"     # 开终端并跑 codex ｜ 默认 opt+x ｜ 任意组合键
openTerminalPi = "opt+s"        # 开终端并跑 pi ｜ 默认 opt+s ｜ 任意组合键
copyPath = "opt+c"              # 复制 Finder 选中路径 ｜ 默认 opt+c ｜ 任意组合键
translate = "opt+z"             # 划词翻译（复制→翻译→浮窗+朗读）｜ 默认 opt+z ｜ 任意组合键
skipPage = "ctrl+1"            # 读下一页（掐断+掀掉当前页剩余的块）｜ 默认 ctrl+1 ｜ 任意组合键
skipBucket = "ctrl+2"           # 跳整摞（掐断+丢弃这一摞的全部内容）｜ 默认 ctrl+2 ｜ 任意组合键
skipAll = "ctrl+3"              # 闭嘴（全掀）｜ 默认 ctrl+3 ｜ 任意组合键
voice = "rightcmd"              # 按住说话（长按）｜ 默认 rightcmd ｜ rightcmd/rightctrl/rightcmd+rightctrl/none

# ── 语音输入 ───────────────────────────────────────────
[speechInput]
enabled = true                  # 语音输入总开关 ｜ 默认 true ｜ true/false
language = "zh"                 # 识别语言（ISO 代码，只写字母）｜ 默认 "zh" ｜ zh/en/ja… 引擎支持的语言
autoEnter = true                # 说完自动回车 ｜ 默认 true ｜ true/false
maxRecordingSeconds = 30        # 单次最长录音（秒）｜ 默认 30 ｜ 数字（>0）

# ── 划词翻译 ───────────────────────────────────────────
[translation]
enabled = true                  # 划词翻译总开关 ｜ 默认 true ｜ true/false
provider = "google"             # 翻译服务 ｜ 默认 "google" ｜ google/openai
baseURL = "https://api.openai.com/v1"   # OpenAI 兼容服务地址 ｜ 默认 同值 ｜ 任意 http(s)（仅 openai）
apiKey = ""                     # 服务密钥 ｜ 默认 ""（空）｜ 任意字符串（仅 openai）
model = "gpt-5-mini"            # 翻译用的模型 ｜ 默认 "gpt-5-mini" ｜ 任意模型 id（仅 openai）
speechEnabled = true            # 译完是否朗读 ｜ 默认 true ｜ true/false
# speechVoice = "taozi"         # 朗读用哪个音色 ｜ 默认 空＝用 sourceVoices.default ｜ 音色 id
panelTimeoutSeconds = 60        # 浮窗兜底隐藏秒数（鼠标一移开就提前收起）｜ 默认 60 ｜ 数字（≥0）
timeoutSeconds = 20             # 翻译请求超时（秒）｜ 默认 20 ｜ 数字（>0）
proxyURL = ""                   # 直连失败后的兜底代理 ｜ 默认 ""（空＝不走）｜ 任意 http(s)

# ── 播报 ───────────────────────────────────────────────
[playback]
#   idleGraceSeconds 只是兜底——端说完了（Claude 的 Stop / pi 的 {end}）就立刻收，不等这个数。
#   太小会误判：一轮回复里夹工具调用，页与页之间常隔二十秒以上（实测 20~130 秒）。
idleGraceSeconds = 60           # 空闲宽限（秒）｜ 默认 60 ｜ 数字

# ── 浮窗（屏幕上的那块 iVox 窗口：字幕、译文都往它里面放）──
[overlay]
#   守护进程每次启动都打一行「屏幕清单」（型号 + 尺寸 + UUID），要钉哪块就从那儿抄一个填进来。
screen = ""                     # 浮窗钉在哪块屏（屏的 UUID）｜ 默认 空＝跟鼠标所在屏 ｜ 任一在屏 UUID
inset = 20                      # 距可见区底边的点数（程序坞在底部时＝距程序坞上沿）｜ 默认 20 ｜ 数字（≥0）
gap = 8                         # 同一块载体里两行之间的距离（如原文与译文）｜ 默认 8 ｜ 数字（≥0）
padding = 14                    # 载体内边距（内容离边缘）｜ 默认 14 ｜ 数字（≥0）
cornerRadius = 10               # 载体圆角 ｜ 默认 10 ｜ 数字（≥0）
fontSize = 16                   # 字号 ｜ 默认 16 ｜ 数字（>0）
maxWidth = 600                  # 一行文字的宽度上限（超出折行）｜ 默认 600 ｜ 数字（>0)
maxHeightRatio = 0.3            # 内容总高度上限＝可见高的比例（超出截最后一行）｜ 默认 0.3 ｜ 0~1 之间的数

# ── 字幕（独立段：屏幕上的显示，与「播报怎么排队收尾」分开）──
[captions]
enabled = false                 # 播报字幕开关（念到哪句显示哪句）｜ 默认 false ｜ true/false

# ── 音色 ───────────────────────────────────────────────
# 键名 = 接入方自报的名字；`default` 是默认音色（没有来源时用它）。
# 可选值 = 音色 id：`ivox voice list` 里能看到（内置 taozi / wanwan / mizai / dayi，另有自建的）。
[sourceVoices]
default = "taozi"               # 默认音色 ｜ 默认 "taozi" ｜ 音色 id
claude = "taozi"                # Claude 的回复用哪个音色 ｜ 默认 "taozi" ｜ 音色 id
pi = "taozi"                    # pi 的回复用哪个音色 ｜ 默认 "taozi" ｜ 音色 id

# ── 微信桥接 ───────────────────────────────────────────
[wechat]
token = ""                      # ilink bot 凭据 ｜ 默认 ""（空＝不启用）｜ `ivox wechat setup` 扫码写入
dataDir = ""                    # 会话数据目录 ｜ 默认 ""（用默认目录）｜ 任意路径
allowFrom = ""                  # 允许发消息的微信账号 id ｜ 默认 ""（谁都不许发）｜ 账号 id（逗号分隔）
longPollMS = 35000              # 长轮询间隔（毫秒）｜ 默认 35000 ｜ 数字
baseURL = "https://ilinkai.weixin.qq.com"   # ilink 服务地址 ｜ 默认 同值 ｜ 任意 http(s)
claudePath = "~/.local/bin/claude"          # claude 可执行文件 ｜ 默认 同值 ｜ 任意路径
askTimeoutSeconds = 300         # 单条提问等待上限（秒）｜ 默认 300 ｜ 数字
speak = false                   # 微信回复要不要在本机念出来 ｜ 默认 false（不念）｜ true / false

# ── 自建音色（可选）─────────────────────────────────────
# 只放你自建或覆盖的音色；内置的四个在代码里（`ivox voice list` 会标出哪个是内置）。
# 同 id 时，你的条目覆盖内置的。字段：id（必填）｜ name ｜ refAudio ｜ refText ｜ description
# [[voices]]
# id = "myvoice"                # 音色 id（引用它就写这个）｜ 默认 无 ｜ 任意小写名
# name = "我的音色"              # 显示名 ｜ 默认 无 ｜ 任意字符串
# refAudio = "~/.config/ivox/voices/ref_myvoice.wav"   # 参考音频路径 ｜ 默认 无 ｜ 任意路径
# refText = "这是一段参考音频对应的文字。"               # 参考音频对应的文字 ｜ 默认 无 ｜ 任意字符串
# description = "自建"           # 备注 ｜ 默认 无 ｜ 任意字符串
"""#
}
