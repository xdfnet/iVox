import Foundation

// 默认配置模板：**外部配置的说明书**。
//
// 为什么放在代码里而不是资源文件：装机脚本、`ivox init-config`、微信配置命令都要用同一份，
// 散成两处迟早漂。放这里 = 单一真源，改一处全体生效。
//
// 为什么是 TOML：能写注释。配置里最需要说明的就是「这一项是干嘛的」「我为什么改成这样」，
// JSON 写不了注释，就只能靠记忆。
//
// **注释规范（2026-10-24 统一）**：每一项的注释一律三段——**是什么 ｜ 默认值 ｜ 可选值**，
// 写在键的上一行，行尾不留注释（全文件只有这一种风格）。补充说明另起一行、以「#   」缩进。
// 默认值取自代码里的真源（`Config.swift` 各类型的 `default`），别抄错。

public enum ConfigTemplate {
    /// 默认配置全文（TOML）。`ivox init-config` 写的就是它。
    public static let tomlText = #"""
# iVox 配置
#
# 格式是 TOML：`#` 后面是注释，方括号是段名，等号右边是值。
# 改完跑一次 `ivox restart` 生效（只重启守护进程，不动开机自启开关）。
#
# **每一项的注释统一三段：是什么 ｜ 默认值 ｜ 可选值**——照「可选值」那一栏填就行。
# 键名一律驼峰；写错的键不会静默，启动日志里会被点名（`ivox status` 里也看得到）。
# 项的顺序按功能排，不是字母序。

# ── 快捷键 ─────────────────────────────────────────────
# 键位写法：cmd / ctrl / opt / shift + 主键，用 + 连接（大小写无所谓）。
# 主键可用：a-z、0-9、esc、space、tab、return、backspace、delete、f1-f12、方向键。
[hotkeys]
# openTerminal：开终端 ｜ 默认 opt+z ｜ 可选 任意组合键
openTerminal = "opt+z"
# openTerminalClaude：开终端并跑 claude ｜ 默认 opt+a ｜ 可选 任意组合键
openTerminalClaude = "opt+a"
# openTerminalCodex：开终端并跑 codex ｜ 默认 opt+x ｜ 可选 任意组合键
openTerminalCodex = "opt+x"
# openTerminalPi：开终端并跑 pi ｜ 默认 opt+q ｜ 可选 任意组合键
openTerminalPi = "opt+q"
# copyPath：复制 Finder 里选中的路径 ｜ 默认 opt+c ｜ 可选 任意组合键
copyPath = "opt+c"
# translate：划词翻译（复制 → 翻译 → 浮窗 + 朗读）｜ 默认 opt+s ｜ 可选 任意组合键
translate = "opt+s"
# skipPage：读下一页（掐断 + 掀掉当前页剩余的块）｜ 默认 ctrl+esc ｜ 可选 任意组合键
skipPage = "ctrl+esc"
# skipBucket：跳整摞（掐断 + 丢弃这一摞的全部内容）｜ 默认 ctrl+1 ｜ 可选 任意组合键
skipBucket = "ctrl+1"
# skipAll：闭嘴（全掀：掐断当前播报 + 丢弃全部待播）｜ 默认 ctrl+2 ｜ 可选 任意组合键
skipAll = "ctrl+2"
# voice：按住说话（要长按，与上面「点一下就触发」不同）｜ 默认 rightcmd ｜ 可选 rightcmd / rightctrl / rightcmd+rightctrl / none
voice = "rightcmd"

# ── 语音输入 ───────────────────────────────────────────
[speechInput]
# enabled：语音输入总开关 ｜ 默认 true ｜ 可选 true / false
enabled = true
# language：识别语言（ISO 语言代码，只写字母）｜ 默认 "zh" ｜ 可选 zh / en / ja … 引擎支持的语言
language = "zh"
# autoEnter：说完自动回车 ｜ 默认 true ｜ 可选 true / false
autoEnter = true
# maxRecordingSeconds：单次最长录音秒数 ｜ 默认 30 ｜ 可选 数字（>0）
maxRecordingSeconds = 30

# ── 划词翻译 ───────────────────────────────────────────
[translation]
# enabled：划词翻译总开关 ｜ 默认 true ｜ 可选 true / false
enabled = true
# provider：翻译服务 ｜ 默认 "google" ｜ 可选 google / openai
provider = "google"
# baseURL：OpenAI 兼容服务的地址 ｜ 默认 "https://api.openai.com/v1" ｜ 可选 任意 http(s) 地址（provider=openai 时才用）
baseURL = "https://api.openai.com/v1"
# apiKey：服务密钥 ｜ 默认 ""（空）｜ 可选 任意字符串（provider=openai 时才用）
apiKey = ""
# model：翻译用的模型 ｜ 默认 "gpt-5-mini" ｜ 可选 任意模型 id（provider=openai 时才用）
model = "gpt-5-mini"
# speechEnabled：译完是否朗读 ｜ 默认 true ｜ 可选 true / false
speechEnabled = true
# speechVoice：朗读用哪个音色 ｜ 默认 空＝用 sourceVoices.default ｜ 可选 音色 id（`ivox voice list`）
# speechVoice = "taozi"
# panelTimeoutSeconds：结果浮窗的兜底隐藏秒数（鼠标一移开就提前收起，这里只是鼠标不动时的保险）｜ 默认 60 ｜ 可选 数字（≥0）
panelTimeoutSeconds = 60
# timeoutSeconds：翻译请求超时秒数 ｜ 默认 20 ｜ 可选 数字（>0）
timeoutSeconds = 20
# proxyURL：直连失败后的兜底代理 ｜ 默认 ""（空＝不走）｜ 可选 任意 http(s) 地址
# proxyURL = "http://192.168.100.6:10808"

# ── 播报 ───────────────────────────────────────────────
[playback]
# captions：播报字幕开关（念到哪句就在屏上显示哪句）｜ 默认 false ｜ 可选 true / false
captions = false
# idleGraceSeconds：空闲宽限秒数（声音停下后再等这么久没新内容，才判「说完了」）｜ 默认 60 ｜ 可选 数字
#   它只是兜底——端说完了（Claude 的 Stop / pi 的 {end}）就立刻收，不等这个数。太小会误判：
#   一轮回复里夹工具调用，页与页之间常隔二十秒以上（实测 20~130 秒），判早了这一轮会被切成好几摞。
idleGraceSeconds = 60
# captionScreen：字幕钉在哪块屏（填那块屏的 UUID）｜ 默认 空＝主屏 ｜ 可选 任一在屏的 UUID
#   守护进程每次启动打一行「屏幕清单」（型号 + 尺寸 + UUID），从那儿抄一个填进来。
captionScreen = ""

# ── 音色 ───────────────────────────────────────────────
# 键名 = 接入方自报的名字；`default` 是默认音色（没有来源时用它）。
# 可选值 = 音色 id：`ivox voice list` 里能看到（内置 taozi / wanwan / mizai / dayi，另有自建的）。
[sourceVoices]
# default：默认音色 ｜ 默认 "taozi" ｜ 可选 音色 id
default = "taozi"
# claude：Claude 的回复用哪个音色 ｜ 默认 "taozi" ｜ 可选 音色 id
claude = "taozi"
# pi：pi 的回复用哪个音色 ｜ 默认 "taozi" ｜ 可选 音色 id
pi = "taozi"

# ── 微信桥接 ───────────────────────────────────────────
[wechat]
# token：ilink bot 凭据 ｜ 默认 ""（空＝微信桥接不启用）｜ 由 `ivox wechat setup` 扫码写入
token = ""
# dataDir：会话数据目录 ｜ 默认 ""（空＝用默认目录）｜ 可选 任意路径
dataDir = ""
# allowFrom：允许给它发消息的微信账号 id ｜ 默认 ""（空＝谁都不许发）｜ 可选 账号 id（多个用逗号隔开）
allowFrom = ""
# longPollMS：长轮询间隔毫秒 ｜ 默认 35000 ｜ 可选 数字
longPollMS = 35000
# baseURL：ilink 服务地址 ｜ 默认 "https://ilinkai.weixin.qq.com" ｜ 可选 任意 http(s) 地址
baseURL = "https://ilinkai.weixin.qq.com"
# claudePath：claude 可执行文件 ｜ 默认 "~/.local/bin/claude" ｜ 可选 任意路径
claudePath = "~/.local/bin/claude"
# askTimeoutSeconds：单条提问的等待上限秒数 ｜ 默认 300 ｜ 可选 数字
askTimeoutSeconds = 300

# ── 自建音色（可选）─────────────────────────────────────
# 只放你自建或覆盖的音色；内置的四个在代码里（`ivox voice list` 会标出哪个是内置）。
# 同 id 时，你的条目覆盖内置的。
# id：音色 id（必填，引用它就写这个）｜ 可选 任意小写名
# name：显示名 ｜ 可选 任意字符串
# refAudio：参考音频路径 ｜ 可选 任意路径
# refText：参考音频对应的文字 ｜ 可选 任意字符串
# description：备注 ｜ 可选 任意字符串
# [[voices]]
# id = "myvoice"
# name = "我的音色"
# refAudio = "~/.config/ivox/voices/ref_myvoice.wav"
# refText = "这是一段参考音频对应的文字。"
# description = "自建"
"""#
}
