#!/usr/bin/env bash
# 安装 iVox hook 到 Claude / PI，已存在则跳过
set -euo pipefail

HOOK_SH="${1:?用法: install-hooks.sh <hook-sh-path>}"

# ── 素材源目录 ──
# 分发器与被它分发的资产**永远同目录**（仓库 scripts/ ↔ 部署态 ~/.config/ivox/scripts/），
# 所以素材源就是本脚本所在目录——不需要再探测。
# 早先的探测逻辑（判 pi/ 是否同级、否则回退 ../integrations）是因为分发器在 scripts/
# 而资产在仓库顶层 integrations/，两处分家才不得不猜；合到一处后整段删掉。
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR"

# hook.sh 本体从素材源铺到部署路径（挂载配置里写死引用 HOOK_SH）
if [[ -f "$SRC/hook.sh" ]]; then
  mkdir -p "$(dirname "$HOOK_SH")"
  cp "$SRC/hook.sh" "$HOOK_SH"
  chmod 755 "$HOOK_SH"
fi

# ── 公共函数：用 jq 或 python3 安全写入 hook 配置 ──
# 用法：write_hook <config> <timeout> [event]
#   event  = settings.json 里的事件键。**只认 Claude Code 认识的名字**——自造 End 之类
#            不认的名字会把整条 hook 静默丢弃（2026-10-16 修的就是这个）。
# 认不得的 event 直接失败，不猜——猜出来的是一条没人要的 hook。
#
# hook.sh **只管 Claude 这一端**（2026-11-02），所以命令不带任何来源参数：
# 它自己知道「我是 Claude 的钩子」，拼好 `ivox speak --source claude …` 交出去。
write_hook() {
  local config_path="$1"
  local timeout="$2"
  local event="${3:-MessageDisplay}"
  local cmd
  case "$event" in
    MessageDisplay)   cmd="bash $HOOK_SH" ;;
    *)                return 1 ;;
  esac

  if command -v jq &>/dev/null; then
    jq --arg cmd "$cmd" --argjson timeout "$timeout" --arg event "$event" \
      '.hooks[$event] += [{"hooks": [{"command": $cmd, "timeout": $timeout, "type": "command"}]}]' \
      "$config_path" > "${config_path}.tmp" && mv "${config_path}.tmp" "$config_path"
  elif command -v python3 &>/dev/null; then
    python3 -c "
import json, sys
cmd, timeout, path, event = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
with open(path) as f:
    d = json.load(f)
d.setdefault('hooks', {}).setdefault(event, []).append({
    'hooks': [{'command': cmd, 'timeout': timeout, 'type': 'command'}]
})
with open(path, 'w') as f:
    json.dump(d, f, indent=2)
    f.write('\n')
" "$cmd" "$timeout" "$config_path" "$event"
  else
    return 1
  fi
}

# UserPromptSubmit 打断 hook 已**废弃**：不再自动挂「提交即打断」。
# 飞哥决策——打断权只归快捷键（右⌘ 说话 / Ctrl+3 闭嘴 / Opt+Z 译文），
# 任何 agent 会话轮次（提交、自动续写、后台）都**不再打断**播报（分桶排队播全）。
# 此前每次 make update 都经这里把 `hook.sh interrupt` 写回 settings.json，
# 与「不自动打断」决策相悖且造成提交即触发 interrupt 的重复/错乱。保留签名壳但不做事，
# 未来若要恢复「提交即打断」只需在此重新实现。
write_prompt_hook() {
  return 0   # no-op：不再挂 UserPromptSubmit interrupt
}

# ── Claude ──
# 播报走 MessageDisplay：一页（一条 assistant 消息）搬一次，**页与页先来先进**，
# 不按 turn 分组。**本脚本只写不删**：遗留的旧 Stop（`hook.sh speak claude`）请人工摘除，
# 否则重复播报。
CLAUDE_JSON="$HOME/.claude/settings.json"
# 「已存在」要**只看 MessageDisplay 这一段**：整份文件里 grep 'hook.sh' 会把存量那条
# Stop（`hook.sh end claude`）也当成「已有」→ 反而把该装的 MessageDisplay 漏掉。
has_message_display_hook() {
  if command -v jq &>/dev/null; then
    # any(生成器; 条件)：生成器是 `.[]`（MessageDisplay 下的每个 hook 组），
    # 条件再看该组里的 command 有没有 hook.sh。
    jq -e '(.hooks.MessageDisplay // []) | any(.[]; ((.hooks // [])[] | .command? // "") | test("hook\\.sh"))' \
      "$CLAUDE_JSON" >/dev/null 2>&1
  else
    python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
groups = d.get('hooks', {}).get('MessageDisplay', [])
ok = any('hook.sh' in (h.get('command') or '')
         for g in groups for h in (g.get('hooks') or []))
sys.exit(0 if ok else 1)
" "$CLAUDE_JSON" >/dev/null 2>&1
  fi
}

if [[ -f "$CLAUDE_JSON" ]]; then
  if has_message_display_hook; then
    echo "[i] Claude MessageDisplay hook 已存在"
  elif write_hook "$CLAUDE_JSON" 10 MessageDisplay; then
    echo "✓  Claude MessageDisplay hook"
  else
    echo "⚠️  需要 jq 或 python3 写入 Claude 配置，请手动添加"
  fi
  # **不再挂 Stop 钩子**（2026-11-02）：队列里不再有「摞」，端也不再报告「这一轮说完了」——
  # 队列排空即收尾。**本脚本只写不删**：存量那条 Stop 请人工摘除。
  write_prompt_hook "$CLAUDE_JSON" 10 claude
fi

# ── PI coding agent 扩展 ──
PI_EXT_DIR="$HOME/.pi/agent/extensions"
PI_EXT_SRC="$SRC/pi/ivox.ts"
if [[ -d "$PI_EXT_DIR" && -f "$PI_EXT_SRC" ]]; then
  # 无条件覆盖：否则仓库里更新了扩展也永远装不上去
  cp "$PI_EXT_SRC" "$PI_EXT_DIR/ivox.ts"
  echo "✓  PI 扩展"
elif [[ -f "$PI_EXT_SRC" ]]; then
  echo "[i] PI 未安装，跳过扩展安装"
fi

# ── 确保 macOS GUI 环境能找到 ~/.local/bin（.zprofile 注入） ──
ZPROFILE="$HOME/.zprofile"
if [[ -f "$ZPROFILE" ]] && grep -q '\.local/bin' "$ZPROFILE" 2>/dev/null; then
  echo "[i] .zprofile 已包含 ~/.local/bin"
elif grep -q 'export PATH' "$ZPROFILE" 2>/dev/null; then
  # 已有 .zprofile 但没包含 ~/.local/bin，追加一行到 export PATH
  sed -i '' 's|export PATH=.*:.*$|\0:$HOME/.local/bin|' "$ZPROFILE" 2>/dev/null || true
  echo "✓  已追加 ~/.local/bin 到现有 .zprofile"
else
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$ZPROFILE"
  echo "✓  已创建 .zprofile，包含 ~/.local/bin"
fi
