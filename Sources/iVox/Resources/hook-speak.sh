#!/bin/bash
# iVox Hook — Claude Code / Codex Stop Hook
# 协议：stdout 必须保持干净；exit 0 = 继续，非 0 = 停止
[[ "${IVOX_SKIP:-}" == "1" ]] && exit 0
# 保存原始 stdout，Codex Stop hook 要求返回 JSON
exec 3>&1
exec 1>/dev/null

SOURCE="${1:-claude}"
payload="$(cat)"

text=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
text = d.get('last_assistant_message', '')
print(text[:5000] if text else '')
" "$payload" 2>/dev/null)

[[ -z "${text// }" ]] && echo '{"continue": true}' >&3 && exit 0
ivox speak --source "$SOURCE" "$text" 2>/dev/null &
echo '{"continue": true}' >&3
exit 0
