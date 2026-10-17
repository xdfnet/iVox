#!/bin/bash
# iVox + iW Hook — Claude Code / Codex / PI 播报 Hook
# Usage: hook.sh <speak|msgdisplay> <source>   # source: claude | codex | pi
#   hook.sh speak claude       → 念 claude 的回复（Codex 等无 MessageDisplay 的走这条）
#   hook.sh msgdisplay claude  → MessageDisplay：assistant 行批增量，按 turn_id 装进同一摞
# 协议：stdout 必须保持干净；exit 0 = 继续，非 0 = 停止
# 手动静音（IVOX_SKIP=1，如 Samantha 内部调用）或 reflexio 后台学习调用（CLAUDE_SMART_INTERNAL=1）→ 不播报
[[ "${IVOX_SKIP:-}" == "1" ]] && exit 0
[[ "${CLAUDE_SMART_INTERNAL:-}" == "1" ]] && exit 0
# 自检静音闸：存在 /tmp/ivox-hook-muted 就闭嘴。与 IVOX_SKIP 同思路，但走文件而非环境变量——
# hook 由 Claude Code 的 harness 拉起，环境在它启动时定死，改不动；文件每次执行都重新判断。
# 用法：`touch /tmp/ivox-hook-muted` 静音，`trash /tmp/ivox-hook-muted` 恢复。
# 起因：`make check-tts` 压的是真实 daemon，而真人对话的播报走同一个队列，会挤掉自检用例。
[[ -f /tmp/ivox-hook-muted ]] && exit 0

# 必须两个参数：动作（speak|msgdisplay）+ 来源。来源与动作一个都不能猜，宁缺毋滥。
# 注：interrupt 分支已移除——打断权只归快捷键（右⌘/Cmd+D/Ctrl+Esc）与命令行 `ivox skip`，
# 不再经 hook.sh 自动打断。（`ivox quiet` 已随停止帧一起删除。）
if [[ "$#" -lt 2 ]]; then exit 0; fi
if [[ "$1" == "msgdisplay" ]]; then
  # MessageDisplay：assistant 消息流式显示时按行批触发，delta = 自上一批以来新完成的整行文本。
  # 这就是「过程内容逐句进桶」的载体——Claude 分步/工具多段回复，各段写出来时各播一次，
  # 不再只等 Stop 终了一次。**必须极快返回**：交互模式下 Claude Code 等本钩子返回才渲染该批。
  # python 只做「delta 提取 + 审计写 hook.log」两件事且要快；播报用后台 & 不阻塞。
  # python 依次吐三行：分组号（摞）、页号、delta。delta 放最后是因为它可能含换行。
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
# 分组号用 turn_id（一次回复 = 一**摞**）；页号用 message_id（一**页**）。
# 两者都要：摞给「跳整摞」用，页给 Ctrl+2「读下一页」用。
# turn_id 缺失时回落 message_id（至少能分组）；都缺就不带这两个字段（退回普通播报）。
san = lambda v: re.sub(r'[^A-Za-z0-9_.-]', '', str(v or ''))   # header 按 , 和 : 切分，脏字符会切坏 meta
grp = san(d.get('turn_id','') or d.get('message_id',''))
pg  = san(d.get('message_id',''))
from pathlib import Path
from datetime import datetime
Path.home().joinpath('.config/ivox/hook.log').open('a').write(
    '%s hook.sh msgdisplay source=%s turn=%s mid=%s index=%s final=%s delta=%s\n' % (
    datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f')[:-3], '$2',
    d.get('turn_id',''), d.get('message_id',''), d.get('index',''), d.get('final',''), delta[:40]))
# 按 session_id 记下「这条会话最后一次是哪一摞」——Stop 的 payload 里**没有 turn_id**
# （只有 session_id + last_assistant_message），收尾信号要靠这一笔反查才能精确指认。
# 分文件存是为了两个会话并行时互不覆盖（一个文件按 session 一键）。
sid = san(d.get('session_id',''))
if sid and grp:
    _d = Path.home()/'.config/ivox/lastturn'
    _d.mkdir(parents=True, exist_ok=True)
    (_d/sid).write_text(grp)
print(grp)
print(pg)
print(delta)
" 2>/dev/null)
  grp="$(printf '%s' "$meta" | sed -n 1p)"
  pg="$(printf '%s' "$meta" | sed -n 2p)"
  delta="$(printf '%s' "$meta" | tail -n +3)"
  if [[ -n "${delta// }" ]]; then
    args=(speak --source "$2")
    [[ -n "$grp" ]] && args+=(--group "$grp")
    [[ -n "$pg" ]] && args+=(--page "$pg")
    # 后台 &：走 socket 短连 O(ms)，不阻塞本批渲染
    ivox "${args[@]}" -- "$delta" 2>/dev/null &
  fi
  echo '{"continue": true}'
  exit 0
fi
if [[ "$1" == "end" ]]; then
  # 回复真正结束（Claude 的 Stop 钩子）：只发一个**收尾信号**——不带一个字、不出声。
  # 作用：让队列立刻判「这一摞说完了」→ 收尾（收字幕），不必再等空闲宽限那 2 秒。
  # 与 msgdisplay 的分工：那条送**内容**，这条只说**完了**。
  # 当年摘 Stop（57179ae）是因为它连正文一起送、与 MessageDisplay 重复播两遍；现在只送暗号，不重复。
  # Stop 的 payload 里**没有 turn_id**（只有 session_id），所以按 session_id 反查 msgdisplay 记下的那一笔，
  # 把收尾精确指到本会话的最后一摞——查不到就不带 group（服务端退化成"收最后打开的那摞"）。
  # 另注：按 Esc 中断与 API 报错（走 StopFailure）时本钩子**不会触发**，那两种情形交给 2 秒空闲宽限兜底。
  payload="$(cat)"
  grp=$(printf '%s' "$payload" | python3 -c "
import json, sys, re
from pathlib import Path
try:
    sid = re.sub(r'[^A-Za-z0-9_.-]', '', str(json.load(sys.stdin).get('session_id','')))
    print((Path.home()/'.config/ivox/lastturn'/sid).read_text().strip() if sid else '')
except Exception:
    print('')
" 2>/dev/null)
  args=(speak --source "$2")
  [[ -n "$grp" ]] && args+=(--group "$grp")
  ivox "${args[@]}" --final -- "" 2>/dev/null &
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
