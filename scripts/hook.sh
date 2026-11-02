#!/bin/bash
# iVox Hook —— **只管 Claude Code 这一端**。
#
# 干什么：Claude Code 的 `MessageDisplay` 钩子按行批送来 assistant 消息，
# 这里按 message_id **攒成一整页**，攒齐了（final=True）就拼一条
# `ivox speak --source claude --voice <音色> -- "<整页>"` 交给播报。
#
# **播报的唯一入口是 `ivox speak`**（2026-11-02）：客户端自己拼命令、自己带来源与音色，
# 守护进程只管照单念，不猜、不管。微信那一端不走 hook（那个 claude 以 --bare 启动，
# 压根不触发钩子），所以本脚本里没有微信、也没有别的来源。
#
# 协议：stdout 必须保持干净；exit 0 = 继续，非 0 = 停止
#
# **别的端不要靠本 hook 播报**：Samantha 这类要出声的端，自己走 `ivox speak`
# （自己攒页、自己查音色、自己拼参数）——那是唯一入口。本 hook 只服务 Claude Code 的
# MessageDisplay。IVOX_SKIP=1 是兜底闸：任何触发了本 hook 又不该出声的场合，自行设上它。
[[ "${IVOX_SKIP:-}" == "1" ]] && exit 0
[[ "${CLAUDE_SMART_INTERNAL:-}" == "1" ]] && exit 0
# 自检静音闸：存在 /tmp/ivox-hook-muted 就闭嘴。与 IVOX_SKIP 同思路，但走文件而非环境变量——
# hook 由 Claude Code 的 harness 拉起，环境在它启动时定死，改不动；文件每次执行都重新判断。
# 用法：`touch /tmp/ivox-hook-muted` 静音，`trash /tmp/ivox-hook-muted` 恢复。
# 起因：`make check-tts` 压的是真实 daemon，而真人对话的播报走同一个队列，会挤掉自检用例。
[[ -f /tmp/ivox-hook-muted ]] && exit 0

# **ivox 用绝对路径**：hook 是被 claude 拉起的，继承 claude 进程的环境，
# 裸名 `ivox` 未必在 PATH 里（2026-10-26 实测：微信侧 claude 继承 launchd 托管 daemon 的
# 残缺 PATH，播报静默失效）。hook 不该依赖「谁拉起它、那人有什么 PATH」，路径写死最稳。
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

# MessageDisplay：assistant 消息渲染时按行批触发，delta = 自上一批以来新完成的整行文本。
# **整页搬运**：MessageDisplay 会把一页拆成十几批增量送来，这里按 message_id 攒着，
# 等 final=True（这一页说完了）再把整页一次性交给播报助理，由它自己切句排队。
# 一页 = 一条 assistant 消息 = 队列里的一个单位；页与页之间**先来先进**。
# **必须极快返回**：交互模式下 Claude Code 等本钩子返回才渲染该批。
# python 只做「攒页 + 审计写 hook.log + 取音色」三件事；播报用后台 & 不阻塞。
# python 吐三段：音色 id、页号（message_id）、整页文本。
# **顺序有讲究**：正文放最后且从第 3 行起全取——正文可能含换行，取单行会截断。
#
# **音色由本端自己取**（2026-11-02）：来源与音色是客户端的事，服务端不猜。
# 映射表仍是 config.toml 的 `[playback.sourceVoices]`（唯一真源）：
# 先取 `claude` 自己的键，取不到退回 `default` 键。两处都没有 → 不带 `--voice` 送出去
# （服务端会走默认音色；`--voice` 在 `ivox speak` 上是可省的）。
payload="$(cat)"
meta=$(printf '%s' "$payload" | python3 -c "
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

def voice_for(source):
    cfg = home/'.config/ivox/config.toml'
    table = {}
    if cfg.exists():
        in_section = False
        for line in cfg.read_text(errors='replace').splitlines():
            t = line.strip()
            if t.startswith('[') and t.endswith(']'):
                in_section = (t == '[playback.sourceVoices]')
                continue
            if not in_section or not t or t.startswith('#'):
                continue
            m = re.match(r'^([A-Za-z0-9_.-]+)\s*=\s*\"([^\"]*)\"', t)
            if m:
                table[m.group(1)] = m.group(2)
    return table.get(source) or table.get('default') or ''

voice = voice_for('claude')
home.joinpath('.config/ivox/hook.log').open('a').write(
    '%s hook.sh source=claude voice=%s turn=%s mid=%s index=%s final=%s delta=%s\n' % (
    datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f')[:-3], voice or '（无）',
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

print(voice)
print(pg)
print(page)
" 2>/dev/null)
voice="$(printf '%s' "$meta" | sed -n 1p)"
pg="$(printf '%s' "$meta" | sed -n 2p)"
# 正文可能含换行 → 从第 3 行起全要（不能只取一行）
page="$(printf '%s' "$meta" | tail -n +3)"
if [[ -n "${page// }" ]]; then
  # 后台 &：走 socket 短连 O(ms)，不阻塞本批渲染
  if [[ -n "$voice" ]]; then
    "$IVO" speak --source claude --voice "$voice" -- "$page" 2>/dev/null &
  else
    "$IVO" speak --source claude -- "$page" 2>/dev/null &
  fi
fi
echo '{"continue": true}'
exit 0
