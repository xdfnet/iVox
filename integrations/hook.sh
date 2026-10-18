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
# 按 session_id 记下「这条会话最后一次是哪一摞」——**Claude 的** Stop payload 里没有 turn_id
# （只有 prompt_id 与 last_assistant_message，见官方 hooks reference），收尾信号要靠这一笔
# 反查才能精确指认。Codex 的 Stop 自带 turn_id，不走这条反查（见 end 分支）。
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
  # Stop 的 payload **两家不一样**，这行是关键的分叉（2026-10-18 核实）：
  #   · Codex  —— 带 `turn_id`（`StopRequest.session_id/turn_id/...`），直接用，精确指认。
  #   · Claude —— **没有 turn_id**（官方 hooks reference 的 Stop 事件专属字段只有
  #     stop_hook_active / last_assistant_message / background_tasks / session_crons，
  #     通用字段里是 prompt_id 不是 turn_id），只能按 session_id 反查 msgdisplay 记下的那一笔。
  # 两家都取不到就不带 group（服务端退化成"收最后打开的那摞"）。
  # 另注：按 Esc 中断与 API 报错（走 StopFailure）时本钩子**不会触发**，那两种情形交给 2 秒空闲宽限兜底。
  payload="$(cat)"
  grp=$(printf '%s' "$payload" | python3 -c "
import json, sys, re
from pathlib import Path
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
tid = re.sub(r'[^A-Za-z0-9_.-]', '', str(d.get('turn_id') or ''))
if tid:
    print(tid)
else:
    sid = re.sub(r'[^A-Za-z0-9_.-]', '', str(d.get('session_id','')))
    p = Path.home()/'.config/ivox/lastturn'/sid if sid else None
    print(p.read_text().strip() if p and p.exists() else '')
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

# **codex 的 Stop payload 带 `turn_id`**（`hooks/src/events/stop.rs` 的 `StopRequest`），
# 拿它当分组号，这一摞就是「这一次输入引发的全部回复」，Ctrl+1 能整摞掀掉。
# 早先这里只取 `last_assistant_message` 不带分组，codex 每次回复都成「无编号入队」——
# 叠加助理侧曾按无编号合并，一次掀摞把几十块一起丢了（2026-10-18 修）。
# Claude 的 Stop **没有** turn_id（只有 prompt_id），走本分支时 grp 为空，退回无分组入队——
# Claude 的正文由 MessageDisplay 送、带 turn_id，本分支对它不是主通路。
grp=$(printf '%s' "$payload" | python3 -c "
import json, sys, re
try:
    d = json.loads(sys.stdin.read()) if sys.stdin.readable() else {}
except Exception:
    d = {}
print(re.sub(r'[^A-Za-z0-9_.-]', '', str(d.get('turn_id') or '')))
" 2>/dev/null)

# **正文取「本轮全部 assistant 消息」，不是只有最后一条。**
# codex 一次输入会产出一条条消息（「我先看看」→「找到了，改一下」→「改完了」），
# 而 Stop 只带 `last_assistant_message`——**过程消息压根送不到播报站**，用户听到的
# 永远只有结尾（2026-10-18 实测：一次输入 941 字送进来，清洗后 704 字 11 块，
# 但 codex 界面上的过程消息远不止这些）。
# payload 里的 `transcript_path` 指向 rollout jsonl，每个「完成的 assistant 消息」都有
# 一条 ItemCompleted 记录且**带 turn_id**；按 turn_id 取本轮全部即可，**不需要游标**
# （turn 一结束就没人再往里加了）。增量不落盘（AgentMessageContentDelta → None），
# 所以拿不到「边生成边听」——只能结束时一次补齐，这是 codex 协议的上限。
#
# 取不到（无 transcript / 换版本改了包法 / 本轮没记录）时一律退回旧行为，绝不静默丢整轮。
# 正文走 **base64 每行一段**。这里踩过两个坑：
#   ① 按行读原文 → 含换行的消息被拆成好几页；
#   ② `mapfile` 是 bash 4+ 才有的，macOS 自带 /bin/bash 是 3.2，直接报 command not found。
# NUL 分隔（`read -d ''` + process substitution）也不可靠：命令替换会吞掉 NUL 字节，
# bash 3.2 的 `read -d ''` 行为又与 4.x 不同，没敢留在正式路径上。
# base64 纯 ASCII、一段一行、bash 3.2 稳，两端都不需要特殊处理。
mapfile_parts=()
while IFS= read -r b64; do
  [[ -n "$b64" ]] && mapfile_parts+=("$b64")
done < <(python3 -c "
import json, os, re, sys
d = json.loads(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].strip() else {}
tid = str(d.get('turn_id') or '')
tp  = d.get('transcript_path') or ''
out, seen = [], set()
if tp and tid and os.path.exists(tp):
    try:
        for line in open(tp, encoding='utf-8', errors='replace'):
            line = line.strip()
            if not line: continue
            try: rec = json.loads(line)
            except Exception: continue
            if not isinstance(rec, dict): continue
            for node in (rec.get('payload'), rec):      # 包法随版本变（payload 摊平与否）
                if not isinstance(node, dict): continue
                if str(node.get('turn_id') or '') != tid: continue
                item = node.get('item')
                if not isinstance(item, dict): break
                if 'agentmessage' not in str(item.get('type') or '').replace('_','').lower(): break
                iid = str(item.get('id') or '')
                if iid and iid in seen: break           # 同一条消息落盘两次时只取一次
                if iid: seen.add(iid)
                s = ''.join(c['text'] for c in (item.get('content') or [])
                            if isinstance(c, dict) and isinstance(c.get('text'), str) and c['text']).strip()
                if s: out.append(s)
                break
    except Exception:
        pass
if not out:
    last = str(d.get('last_assistant_message') or '').strip()
    if last: out = [last]
import base64
for t in out:
    # 过短的纯西文确认（如 true/ok/done）不播报
    if len(t) <= 5 and not re.search(r'[一-鿿]', t): continue
    sys.stdout.write(base64.b64encode(t.encode('utf-8')).decode('ascii') + chr(10))
" "$payload" 2>/dev/null)

parts=()
for b64 in "${mapfile_parts[@]}"; do
  t=$(printf '%s' "$b64" | /usr/bin/base64 -D 2>/dev/null)
  [[ -n "${t// }" ]] && parts+=("$t")
done

((${#parts[@]})) || { echo '{"continue": true}' >&3; exit 0; }
# 一条 assistant 消息 = 一页：逐条入队，page 号用序号（**只作同页线索**，
# 真页号由助理自编）。同 group → 助理认得它们是同一摞，Ctrl+1 能整摞掀。
#
# **必须串行，不能 `&` 并发**：并发时各次 socket 到达播报站的先后不确定，
# 「我先看看」可能排在「改完了」后面——顺序一乱，播出来的东西就自相矛盾。
# 每条是一次 O(ms) 的 socket 短连，Stop 的 timeout 是 30s，串行完全不构成负担。
for i in "${!parts[@]}"; do
  args=(speak --source "$source")
  [[ -n "$grp" ]] && args+=(--group "$grp" --page "p$i")
  ivox "${args[@]}" -- "${parts[$i]}" 2>/dev/null 3>&-
done
echo '{"continue": true}' >&3
