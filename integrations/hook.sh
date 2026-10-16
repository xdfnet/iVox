#!/bin/bash
# iVox + iW Hook — Claude Code / Codex / PI 播报 Hook
# Usage: hook.sh <speak|msgdisplay> <source>   # source: claude | codex | pi
#   hook.sh speak claude       → 念 claude 的回复（Codex 等无 MessageDisplay 的走这条）
#   hook.sh msgdisplay claude  → MessageDisplay：assistant 行批增量，按 turn_id 装进同一摞
# 协议：stdout 必须保持干净；exit 0 = 继续，非 0 = 停止
# 手动静音（IVOX_SKIP=1，如 Samantha 内部调用）或 reflexio 后台学习调用（CLAUDE_SMART_INTERNAL=1）→ 不播报
[[ "${IVOX_SKIP:-}" == "1" ]] && exit 0
[[ "${CLAUDE_SMART_INTERNAL:-}" == "1" ]] && exit 0

# 必须两个参数：动作（speak|msgdisplay）+ 来源。来源与动作一个都不能猜，宁缺毋滥。
# 注：interrupt 分支已移除——打断权只归快捷键（右⌘/Cmd+D/Ctrl+Esc）与手动 ivox quiet，
# 不再经 hook.sh 自动打断。ivox quiet 能力保留在 ivox CLI 侧。
if [[ "$#" -lt 2 ]]; then exit 0; fi
if [[ "$1" == "msgdisplay" ]]; then
  # MessageDisplay：assistant 消息流式显示时按行批触发，delta = 自上一批以来新完成的整行文本。
  # 这就是「过程内容逐句进桶」的载体——Claude 分步/工具多段回复，各段写出来时各播一次，
  # 不再只等 Stop 终了一次。**必须极快返回**：交互模式下 Claude Code 等本钩子返回才渲染该批。
  # python 只做「delta 提取 + 审计写 hook.log」两件事且要快；播报用后台 & 不阻塞。
  # python 依次吐两行：分组号、delta。delta 放最后是因为它可能含换行。
  payload="$(cat)"
  meta=$(printf '%s' "$payload" | python3 -c "
import json, sys, re
s = sys.stdin.read()
d = json.loads(s) if s.strip() else {}
delta = d.get('delta', '') or ''
# 过短纯西文确认（true/ok/done）不播；空/纯空白不播
if isinstance(delta, str):
    if len(delta) <= 5 and not re.search(r'[一-鿿]', delta):
        delta = ''
# 分组号用 turn_id（一次回复 = 一摞），**不是** message_id（一条 message = 一页）：
# 一次回复里夹了工具调用就有好几页，按页分桶的话「跳一摞」得按好几次、还跳不干净。
# turn_id 缺失时回落 message_id；都缺就不分组（退回普通播报）。
grp = str(d.get('turn_id','') or d.get('message_id','') or '')
grp = re.sub(r'[^A-Za-z0-9_.-]', '', grp)   # header 按 , 和 : 切分，脏字符会切坏 meta
from pathlib import Path
from datetime import datetime
Path.home().joinpath('.config/ivox/hook.log').open('a').write(
    '%s hook.sh msgdisplay source=%s turn=%s mid=%s index=%s final=%s delta=%s\n' % (
    datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f')[:-3], '$2',
    d.get('turn_id',''), d.get('message_id',''), d.get('index',''), d.get('final',''), delta[:40]))
print(grp)
print(delta)
" 2>/dev/null)
  grp="$(printf '%s' "$meta" | sed -n 1p)"
  delta="$(printf '%s' "$meta" | tail -n +2)"
  if [[ -n "${delta// }" ]]; then
    args=(speak --source "$2")
    [[ -n "$grp" ]] && args+=(--group "$grp")
    # 后台 &：走 socket 短连 O(ms)，不阻塞本批渲染
    ivox "${args[@]}" -- "$delta" 2>/dev/null &
  fi
  echo '{"continue": true}'
  exit 0
fi
[[ "$1" == "speak" ]] || exit 0   # 未知动作：不处理
source="$2"

exec 3>&1
exec 1>/dev/null

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
