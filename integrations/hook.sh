#!/bin/bash
# iVox Hook — Claude Code 播报 Hook（PI 走自己的 TS 扩展，不经过这里）
# Usage: hook.sh <msgdisplay|end> <source>   # source: claude
#   hook.sh msgdisplay claude  → MessageDisplay：assistant 行批增量，按 turn_id 装进同一摞
#   hook.sh end claude         → Stop：只送「说完了」这个暗号，不出声
# 协议：stdout 必须保持干净；exit 0 = 继续，非 0 = 停止
# 手动静音（IVOX_SKIP=1，如 Samantha 内部调用）或 reflexio 后台学习调用（CLAUDE_SMART_INTERNAL=1）→ 不播报
[[ "${IVOX_SKIP:-}" == "1" ]] && exit 0
[[ "${CLAUDE_SMART_INTERNAL:-}" == "1" ]] && exit 0
# 自检静音闸：存在 /tmp/ivox-hook-muted 就闭嘴。与 IVOX_SKIP 同思路，但走文件而非环境变量——
# hook 由 Claude Code 的 harness 拉起，环境在它启动时定死，改不动；文件每次执行都重新判断。
# 用法：`touch /tmp/ivox-hook-muted` 静音，`trash /tmp/ivox-hook-muted` 恢复。
# 起因：`make check-tts` 压的是真实 daemon，而真人对话的播报走同一个队列，会挤掉自检用例。
[[ -f /tmp/ivox-hook-muted ]] && exit 0

# 必须两个参数：动作（msgdisplay|end）+ 来源。来源与动作一个都不能猜，宁缺毋滥。
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
final = d.get('final', False)
san = lambda v: re.sub(r'[^A-Za-z0-9_.-]', '', str(v or ''))   # header 按 , 和 : 切分，脏字符会切坏 meta
grp = san(d.get('turn_id','') or d.get('message_id',''))
pg  = san(d.get('message_id',''))
from pathlib import Path
from datetime import datetime
home = Path.home()
home.joinpath('.config/ivox/hook.log').open('a').write(
    '%s hook.sh msgdisplay source=%s turn=%s mid=%s index=%s final=%s delta=%s\n' % (
    datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f')[:-3], '$2',
    d.get('turn_id',''), d.get('message_id',''), d.get('index',''), final, delta[:40]))

# **整页搬运**：MessageDisplay 会把一页拆成十几批增量送来，这里先攒着，
# 等 final=True（这一页说完了）再把整页一次性交给播报助理，由它自己切句排队。
# 早先每批都立刻发，一页会涌进十几个碎片，队列顺序被切碎、也不像「一页」。
bufdir = home/'.config/ivox/pagebuf'
if pg:
    bufdir.mkdir(parents=True, exist_ok=True)
    f = bufdir/pg
    if delta:
        with f.open('a') as fh:
            fh.write(delta)
    if final:
        page = f.read_text() if f.exists() else ''
        f.unlink(missing_ok=True)
    else:
        page = ''
else:
    page = ''

# 过短纯西文确认（true/ok/done）不播；空/纯空白不播
if isinstance(page, str):
    if len(page) <= 5 and not re.search(r'[一-鿿]', page):
        page = ''

# 按 session_id 记下「这条会话最后一次是哪一摞」——**Claude 的 Stop payload 里没有 turn_id**
# （只有 prompt_id 与 last_assistant_message，见官方 hooks reference），收尾信号要靠这一笔
# 反查才能精确指认。
# 分文件存是为了两个会话并行时互不覆盖（一个文件按 session 一键）。
sid = san(d.get('session_id',''))
if sid and grp:
    _d = home/'.config/ivox/lastturn'
    _d.mkdir(parents=True, exist_ok=True)
    (_d/sid).write_text(grp)
print(grp)
print(pg)
print(page)
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
  # Claude 的 Stop **没有 turn_id**（官方 hooks reference 的 Stop 事件专属字段只有
  # stop_hook_active / last_assistant_message / background_tasks / session_crons，
  # 通用字段里是 prompt_id 不是 turn_id），只能按 session_id 反查 msgdisplay 记下的那一笔。
  # 先试 payload 里万一有 turn_id，没有再反查；两条都取不到就不带 group（服务端退化成「收最后打开的那摞」）。
  # 另注：按 Esc 中断与 API 报错（走 StopFailure）时本钩子**不会触发**，那两种情形交给 2 秒空闲宽限兜底。
  payload="$(cat)"
  grp=$(printf '%s' "$payload" | python3 -c "
import json, sys, re
import time
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
# 顺手给 lastturn/ 扫一遍：Stop 一轮一次，一天几十次，便宜。这张表只存「session →
# 最后一摞」的对照，回复结束就不再有用，留着只是白占目录（实测已堆到 30 个文件）。
# 七天是下限：七天内的会话还有可能被 Stop 反查，更早的不可能还在对话里。
try:
    _dir = p.parent if p else Path.home()/'.config/ivox/lastturn'
    _cut = time.time() - 7*86400
    for _f in _dir.iterdir():
        if _f.is_file() and _f.stat().st_mtime < _cut:
            _f.unlink()
except Exception:
    pass
" 2>/dev/null)
  args=(speak --source "$2")
  [[ -n "$grp" ]] && args+=(--group "$grp")
  ivox "${args[@]}" --final -- "" 2>/dev/null &
  echo '{"continue": true}'
  exit 0
fi

