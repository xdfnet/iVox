#!/bin/bash
# iVox + iW Hook — Claude Code / Codex / Qwen Code Stop Hook
# Usage: hook.sh <source>   # source: claude | codex | qwen | dsh
# 协议：stdout 必须保持干净；exit 0 = 继续，非 0 = 停止
# 手动静音（IVOX_SKIP=1，如 Samantha 内部调用）或 reflexio 后台学习调用（CLAUDE_SMART_INTERNAL=1）→ 不播报
[[ "${IVOX_SKIP:-}" == "1" ]] && exit 0
[[ "${CLAUDE_SMART_INTERNAL:-}" == "1" ]] && exit 0
exec 3>&1
exec 1>/dev/null

payload="$(cat)"
source="${1:-claude}"

if [[ "$source" == "dsh" ]]; then
# dsh 桥接的 Stop payload 不含回复文本，从本地 zstd 会话日志取最后一条 assistant 消息
sid=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('session_id',''))" "$payload" 2>/dev/null)
cwd=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('cwd',''))" "$payload" 2>/dev/null)
enc=$(python3 -c "import sys; print('-' + (sys.argv[1] + '/').replace('/', '-') + '-')" "$cwd")
log="$HOME/.dsh/sessions/$enc/$sid/session.v4.jsonl.zstd"
text=$(zstd -dc "$log" 2>/dev/null | python3 -c "
import json, sys, re
last = ''
for line in sys.stdin:
    try: e = json.loads(line)
    except ValueError: continue
    if e.get('type') == 'assistant/message':
        msg = e.get('data', {}).get('message', {})
        last = ''.join(b.get('text', '') for b in msg.get('content', []) if b.get('type') == 'text')
# 过短的纯西文确认（如 true/ok/done）不播报
if last and len(last) <= 5 and not re.search(r'[一-鿿]', last):
    last = ''
print(last[:5000])
")
else
text=$(python3 -c "
import json, sys, re
d = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
text = d.get('last_assistant_message', '')
# 过短的纯西文确认（如 true/ok/done）不播报
if text and len(text) <= 5 and not re.search(r'[一-鿿]', text):
    text = ''
print(text[:5000] if text else '')
" "$payload" 2>/dev/null)
fi

[[ -z "${text// }" ]] && echo '{"continue": true}' >&3 && exit 0
ivox speak --source "$source" -- "$text" 2>/dev/null 3>&- &
echo '{"continue": true}' >&3
