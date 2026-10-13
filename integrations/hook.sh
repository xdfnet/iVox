#!/bin/bash
# iVox + iW Hook — Claude Code / Codex / Qwen Code / DeepSeek Harness Stop Hook
# Usage: hook.sh <source> [say|interrupt]   # source: claude | codex | qwen | dsh
#   hook.sh claude           → Stop（回复完成）念新回复
#   hook.sh claude say       → 同上（显式）
#   hook.sh claude interrupt → UserPromptSubmit，用户提交即打断（发带来源的停止帧）
# 协议：stdout 必须保持干净；exit 0 = 继续，非 0 = 停止
# 手动静音（IVOX_SKIP=1，如 Samantha 内部调用）或 reflexio 后台学习调用（CLAUDE_SMART_INTERNAL=1）→ 不播报
[[ "${IVOX_SKIP:-}" == "1" ]] && exit 0
[[ "${CLAUDE_SMART_INTERNAL:-}" == "1" ]] && exit 0

# interrupt：挂在 UserPromptSubmit，用户一提交就打断当前播报（不读文本、不发声）。
# 带来源发 `{type:stop,source:claude}`，让 daemon 日志认出是哪个来源打断的。
if [[ "${2:-}" == "interrupt" ]]; then
  cat >/dev/null 2>&1
  src="${1:-unknown}"
  printf '%s hook.sh interrupt source=%s\n' "$(date '+%Y-%m-%d %H:%M:%S.%3N')" "$src" >>~/.config/ivox/hook.log 2>/dev/null
  ivox quiet --source "$src" 2>/dev/null
  exit 0
fi

exec 3>&1
exec 1>/dev/null

# 注：dsh 的回复文本由 profile 本地插件 ivox-tts.mjs 直接写进 payload 的
# last_assistant_message，这里不再回头读 ~/.dsh/sessions/*.zstd。
payload="$(cat)"
source="${1:-claude}"

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
