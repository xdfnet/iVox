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

# **只搬结论：一摞一页，与 `ivox speak` 同形。**
# codex 一次输入会产出一条条 assistant 消息，transcript 里靠 `phase` 区分身份：
#   · `Commentary`    —— 中途解说（「我先看看」「找到了，改一下」）
#   · `PartialAnswer` —— 正式答案写到一半的中间态
#   · `FinalAnswer`   —— 本轮最终答案，**通常只有一条**
# 早先一版把本轮**全部**消息都搬过来当多页，听着「一次输入有回音」；实际听着是
# 半截结论 + 过程碎片 + 结论重播，且 codex 的增量不落盘（AgentMessageContentDelta
# → None）也没有流式钩子，Stop 时已经是「迟到一步」——搬得越多，越像在念日志。
# 2026-10-18 飞哥裁决：**只留 Stop、只搬运结论**，行为对齐 `ivox speak`——
# 一摞一页，Ctrl+1 掀摞 / Ctrl+2 掀页都还成立（只是这一摞本来就只有一页）。
# **不带 `--page`**：一页的东西没有页号可编，助理自编一个即可，多传反而添乱。
#
# 正文从 payload 的 `transcript_path`（rollout jsonl）里按 turn_id + phase 挑。
# 挑不到（无 transcript / 换版本改了字段名 / 本轮没落 FinalAnswer）时退回
# `last_assistant_message`——Stop 自带它，**那本来就是结论**，兜底不会播成过程碎片。
# 正文走 base64 一段一行：正文可能含换行，按行读原文会被拆错；`mapfile` 是 bash 4+
# 才有的，macOS /bin/bash 是 3.2 直接报 command not found。
b64=$(python3 -c "
import json, os, re, sys
d = json.loads(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].strip() else {}
tid = str(d.get('turn_id') or '')
tp  = d.get('transcript_path') or ''
finals, seen = [], set()
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
                if str(item.get('phase') or '') != 'FinalAnswer': break   # 中途解说/半截答案一律不搬
                s = ''.join(c['text'] for c in (item.get('content') or [])
                            if isinstance(c, dict) and isinstance(c.get('text'), str) and c['text']).strip()
                if s: finals.append(s)
                break
    except Exception:
        pass
if not finals:
    last = str(d.get('last_assistant_message') or '').strip()
    if last: finals = [last]
import base64
if finals:
    text = '\n\n'.join(finals).strip()
    # 过短的纯西文确认（如 true/ok/done）不播报
    if len(text) <= 5 and not re.search(r'[一-鿿]', text): raise SystemExit
    sys.stdout.write(base64.b64encode(text.encode('utf-8')).decode('ascii'))
" "$payload" 2>/dev/null)

[[ -n "$b64" ]] || { echo '{"continue": true}' >&3; exit 0; }
body=$(printf '%s' "$b64" | /usr/bin/base64 -D 2>/dev/null)
[[ -n "${body// }" ]] || { echo '{"continue": true}' >&3; exit 0; }

args=(speak --source "$source")
[[ -n "$grp" ]] && args+=(--group "$grp")
ivox "${args[@]}" -- "$body" 2>/dev/null 3>&-
echo '{"continue": true}' >&3
