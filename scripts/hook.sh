#!/bin/bash
# iVox Hook — Claude Code 播报 Hook（PI 走自己的 TS 扩展，不经过这里）
# Usage: hook.sh <source>   # source: claude
#   hook.sh claude  → MessageDisplay：一整页（一条 assistant 消息）搬一次
#
# **没有动作名**：收尾信号已随「摞」一起删了，只剩「搬一页」这一件事，
# 再挂个 msgdisplay 的名字纯属多余。
#
# 协议：stdout 必须保持干净；exit 0 = 继续，非 0 = 停止
# 手动静音（IVOX_SKIP=1，如 Samantha 内部调用）或 reflexio 后台学习调用（CLAUDE_SMART_INTERNAL=1）→ 不播报
[[ "${IVOX_SKIP:-}" == "1" ]] && exit 0
[[ "${CLAUDE_SMART_INTERNAL:-}" == "1" ]] && exit 0
# 自检静音闸：存在 /tmp/ivox-hook-muted 就闭嘴。与 IVOX_SKIP 同思路，但走文件而非环境变量——
# hook 由 Claude Code 的 harness 拉起，环境在它启动时定死，改不动；文件每次执行都重新判断。
# 用法：`touch /tmp/ivox-hook-muted` 静音，`trash /tmp/ivox-hook-muted` 恢复。
# 起因：`make check-tts` 压的是真实 daemon，而真人对话的播报走同一个队列，会挤掉自检用例。
[[ -f /tmp/ivox-hook-muted ]] && exit 0

# 微信链路的 claude（daemon spawn 出来的那个）**照样会触发本 hook**——
# hook 配在 user 级 settings.json，谁启动 claude 都吃。它的来源由环境变量标出：
# ClaudeAskService spawn 时注入 IVOX_SOURCE=wechat，hook 进程继承该环境。
# 这里**只标来源、不自己决定播不播**：微信要不要念由 daemon 按 config.toml 的
# `wechat.speak` 裁决（真源在配置里，hook 不猜）。
# 早先微信侧没出声是「碰巧」：hook 触发了，却因为 PATH 里没有 ~/.local/bin 找不到
# ivox 而静默失败（2026-10-26 实测）——那是巧合不是机制，不能当规则。
SOURCE="${IVOX_SOURCE:-${1:-}}"
# 给 python 段用：审计行要写来源。用 export 而不是 `VAR=x meta=$(...)` 前缀赋值——
# 前缀环境对**纯赋值语句**里的命令替换不生效（实测 source= 写成空）。
export IVOX_HOOK_SOURCE="$SOURCE"

# **ivox 用绝对路径**：hook 是被 claude 拉起的，继承 claude 进程的环境。
# 微信侧 claude 由 launchd 托管的 daemon spawn，PATH 只有 /usr/bin:/bin:/usr/sbin:/sbin，
# 裸名 `ivox` 找不到 → 播报静默失效（2026-10-26 实测）。
# hook 不该依赖「谁拉起它、那人有什么 PATH」，路径写死最稳。
IVO="$HOME/.local/bin/ivox"

# hook.log 的轮转：只增不减是没有上限的，而 daemon.log 有 5M 阈值——用久了这里会涨到几百 M。
# 规则与 Logger.swift 的 rotateIfNeeded 一致（超阈值就把主文件改名成 .old，旧的被覆盖）。
# 用 mv 覆盖而不是先 rm 再 mv：省一步，也不用在 hook 里做删除。
HOOK_LOG_MAX=$((5 * 1024 * 1024))
rotate_hook_log() {
  local f="$HOME/.config/ivox/hook.log"
  [[ -f "$f" ]] || return 0
  local sz; sz=$(stat -f%z "$f" 2>/dev/null) || return 0
  (( sz > HOOK_LOG_MAX )) && mv "$f" "$f.old"
  return 0
}
rotate_hook_log

# 来源只认 claude / wechat 两个：别的（多半是配置没更新干净）一律不出声——宁缺毋滥，不猜。
# 注：打断与收尾都不再经 hook——打断权只归快捷键（Ctrl+1 掀页 / Ctrl+2 全掀）与命令行
# `ivox skip`；「这一轮说完了」也不再由端报告（队列排空即收尾）。
case "$SOURCE" in
  claude|wechat) ;;
  *) exit 0 ;;
esac

# MessageDisplay：assistant 消息渲染时按行批触发，delta = 自上一批以来新完成的整行文本。
# **整页搬运**：MessageDisplay 会把一页拆成十几批增量送来，这里按 message_id 攒着，
# 等 final=True（这一页说完了）再把整页一次性交给播报助理，由它自己切句排队。
# 一页 = 一条 assistant 消息 = 队列里的一个单位；页与页之间**先来先进**，
# 不再按 turn 分组（turn_id 只留在日志里，不参与排队）。
# **必须极快返回**：交互模式下 Claude Code 等本钩子返回才渲染该批。
# python 只做「攒页 + 审计写 hook.log」两件事；播报用后台 & 不阻塞。
# python 吐两行：页号（message_id）、整页文本。文本放最后是因为它可能含换行。
payload="$(cat)"
IVOX_HOOK_SOURCE="$SOURCE" meta=$(printf '%s' "$payload" | python3 -c "
import json, os, sys, re
s = sys.stdin.read()
d = json.loads(s) if s.strip() else {}
delta = d.get('delta', '') or ''
final = d.get('final', False)
san = lambda v: re.sub(r'[^A-Za-z0-9_.-]', '', str(v or ''))   # 文件名用的清洗
pg  = san(d.get('message_id',''))
from pathlib import Path
from datetime import datetime
home = Path.home()
home.joinpath('.config/ivox/hook.log').open('a').write(
    '%s hook.sh source=%s turn=%s mid=%s index=%s final=%s delta=%s\n' % (
    datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f')[:-3], os.environ.get('IVOX_HOOK_SOURCE',''),
    d.get('turn_id',''), d.get('message_id',''), d.get('index',''), final, delta[:40]))

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

print(pg)
print(page)
" 2>/dev/null)
pg="$(printf '%s' "$meta" | sed -n 1p)"
page="$(printf '%s' "$meta" | tail -n +2)"
if [[ -n "${page// }" ]]; then
  # 后台 &：走 socket 短连 O(ms)，不阻塞本批渲染
  "$IVO" speak --source "$SOURCE" -- "$page" 2>/dev/null &
fi
echo '{"continue": true}'
exit 0
