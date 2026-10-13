#!/bin/bash
# iVox + iW Hook — Claude Code / Codex / Qwen Code / DeepSeek Harness Stop Hook
# Usage: hook.sh <speak|interrupt> <source>   # source: claude | codex | qwen | dsh
#   hook.sh speak claude       → Stop（回复完成）念 claude 的回复
#   hook.sh interrupt claude   → UserPromptSubmit，用户提交即打断（发带来源的停止帧）
# 协议：stdout 必须保持干净；exit 0 = 继续，非 0 = 停止
# 手动静音（IVOX_SKIP=1，如 Samantha 内部调用）或 reflexio 后台学习调用（CLAUDE_SMART_INTERNAL=1）→ 不播报
[[ "${IVOX_SKIP:-}" == "1" ]] && exit 0
[[ "${CLAUDE_SMART_INTERNAL:-}" == "1" ]] && exit 0

# 必须两个参数：动作（speak|interrupt）+ 来源，缺一即静默退出、不处理。
# 来源与动作一个都不能猜——旧单参数 / source 打头的写法已丢弃，宁可静默也不误播/误断。
if [[ "$#" -lt 2 ]]; then exit 0; fi
if [[ "$1" == "interrupt" ]]; then
  cat >/dev/null 2>&1
  printf '%s hook.sh interrupt source=%s\n' "$(date '+%Y-%m-%d %H:%M:%S.%3N')" "$2" >>~/.config/ivox/hook.log 2>/dev/null
  ivox quiet --source "$2" 2>/dev/null
  exit 0
fi
[[ "$1" == "speak" ]] || exit 0   # 未知动作：不处理
source="$2"

exec 3>&1
exec 1>/dev/null

# 注：dsh 的回复文本由 profile 本地插件 ivox-tts.mjs 直接写进 payload 的
# last_assistant_message，这里不再回头读 ~/.dsh/sessions/*.zstd。
payload="$(cat)"

text=$(python3 -c "
import json, sys, re
d = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
text = d.get('last_assistant_message', '')
# 过短的纯西文确认（如 true/ok/done）不播报
if text and len(text) <= 5 and not re.search(r'[一-鿿]', text):
    text = ''
print(text if text else '')
" "$payload" 2>/dev/null)

[[ -z "${text// }" ]] && echo '{"continue": true}' >&3 && exit 0
ivox speak --source "$source" -- "$text" 2>/dev/null 3>&- &
echo '{"continue": true}' >&3
