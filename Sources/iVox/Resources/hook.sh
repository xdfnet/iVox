#!/bin/bash
# iVox + iW Hook — Claude Code / Codex / Qwen Code / DeepSeek Harness Stop Hook
# Usage: hook.sh <source>   # source: claude | codex | qwen | dsh
# 协议：stdout 必须保持干净；exit 0 = 继续，非 0 = 停止
# 手动静音（IVOX_SKIP=1，如 Samantha 内部调用）或 reflexio 后台学习调用（CLAUDE_SMART_INTERNAL=1）→ 不播报
[[ "${IVOX_SKIP:-}" == "1" ]] && exit 0
[[ "${CLAUDE_SMART_INTERNAL:-}" == "1" ]] && exit 0
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
