#!/bin/bash
# iVox + iW Hook — Claude Code / Codex / Qwen Code Stop Hook
# Usage: hook.sh <source>   # source: claude | codex | qwen
# 协议：stdout 必须保持干净；exit 0 = 继续，非 0 = 停止
[[ "${IVOX_SKIP:-}" == "1" ]] && exit 0
exec 3>&1
exec 1>/dev/null

payload="$(cat)"
source="${1:-claude}"

text=$(python3 -c "
import json, sys, re
d = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
text = d.get('last_assistant_message', '')
# 过短的纯西文确认（如 true/ok/done）不播报
if text and len(text) <= 5 and not re.search(r'[一-鿿]', text):
    text = ''
print(text[:5000] if text else '')
" "$payload" 2>/dev/null)

[[ -z "${text// }" ]] && echo '{"continue": true}' >&3 && exit 0
ivox wechat text "$text" 2>/dev/null 3>&- &
ivox speak --source "$source" -- "$text" 2>/dev/null 3>&- &
echo '{"continue": true}' >&3
