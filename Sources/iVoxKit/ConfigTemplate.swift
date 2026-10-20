import Foundation

// 默认配置模板：**外部配置的说明书**。
//
// 为什么放在代码里而不是资源文件：装机脚本、`ivox init-config`、微信配置命令都要用同一份，
// 散成两处迟早漂。放这里 = 单一真源，改一处全体生效。
//
// 为什么是 TOML：能写注释。配置里最需要说明的就是「这一项是干嘛的」「我为什么改成这样」，
// JSON 写不了注释，就只能靠记忆。

public enum ConfigTemplate {
    /// 默认配置全文（TOML）。`ivox init-config` 写的就是它。
    public static let tomlText = #"""
# iVox 配置
#
# 格式是 TOML：`#` 后面是注释，方括号是段名，等号右边是值。
# 改完跑一次 `ivox restart` 生效（只重启守护进程，不动开机自启开关）。
#
# 想知道某一项是干嘛的，看这份注释；想知道全部能写什么，看 README 的「配置」一节。

# ── 快捷键 ─────────────────────────────────────────────
# 写法：cmd / ctrl / opt / shift + 字母或数字，用 + 连接（大小写无所谓）。
# 语音键（按住说话）单列在最后，取值 rightcmd / rightctrl / rightcmd+rightctrl / none。
[hotkeys]
translate = "cmd+d"             # 划词翻译：复制 → 翻译 → 浮窗 + 朗读
openTerminal = "opt+z"         # 开终端
openTerminalClaude = "opt+a"   # 开终端并跑 claude
openTerminalCodex = "opt+x"    # 开终端并跑 codex
openTerminalPi = "opt+q"       # 开终端并跑 pi
copyPath = "opt+c"             # 复制 Finder 里选中的路径
escInterrupt = "ctrl+2"        # 闭嘴（全掀：掐断当前播报 + 丢弃全部待播）
skipBucket = "ctrl+1"          # 跳整摞（掐断 + 丢弃这一摞的全部内容）
skipPage = "ctrl+esc"          # 读下一页（掐断 + 掀掉当前页剩余的块）
voice = "rightcmd"            # 语音输入：按住右⌘ 说话（可改 rightctrl / rightcmd+rightctrl / none）

# ── 语音输入 ───────────────────────────────────────────
[speechInput]
enabled = true                 # 总开关
language = "zh"                # 识别语言
autoEnter = true               # 说完自动回车
maxRecordingSeconds = 30       # 单次最长录音（秒）

# ── 划词翻译 ───────────────────────────────────────────
[translation]
enabled = true
provider = "google"            # google（双通道容灾）或 openai（兼容 OpenAI 协议）
baseURL = "https://api.openai.com/v1"   # provider=openai 时填你的服务地址
apiKey = ""                    # provider=openai 时填密钥；google 不需要
model = "gpt-5-mini"           # provider=openai 时用的模型
speechEnabled = true           # 译完是否朗读
# speechVoice = "taozi"        # 朗读用哪个音色；不写 = 用下面 sourceVoices.default
panelTimeoutSeconds = 60       # 浮窗兜底隐藏秒数（鼠标一移开就提前收起）
timeoutSeconds = 20            # 翻译请求超时
proxyURL = ""                  # 兜底代理（如 http://192.168.100.6:10808）；空 = 不走

# ── 播报 ───────────────────────────────────────────────
[playback]
captions = false               # 是否显示播报字幕

# ── 音色 ───────────────────────────────────────────────
# default = 没有指定来源时用哪个音色；下面几行是「按接入方分别选音色」。
# 内置音色只有四个（taozi / wanwan / …），在 `ivox voice list` 里能看到。
[sourceVoices]
default = "taozi"
claude = "taozi"
pi = "taozi"

# ── 微信桥接 ───────────────────────────────────────────
# token 用 `ivox wechat setup` 扫码获取；allowFrom 填允许发消息的微信账号 id。
[wechat]
token = ""
dataDir = ""
allowFrom = ""
longPollMS = 35000
baseURL = "https://ilinkai.weixin.qq.com"
claudePath = "~/.local/bin/claude"
"""#
}
