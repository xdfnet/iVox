#!/usr/bin/env bash
# 安装 iVox hook 到 Claude / Codex / PI，已存在则跳过
set -euo pipefail

HOOK_SH="${1:?用法: install-hooks.sh <hook-sh-path>}"

# ── 素材源目录探测 ──
# 部署态：本脚本就在 ~/.config/ivox/integrations/ 内，pi/、hook.sh 与它同级；
# 源码态：本脚本在 scripts/，素材在 ../integrations。
# 判据只看 pi/：原先要求 pi/ 与 dsh/ 同时存在，Qwen Code / DSH 下线删掉 dsh/ 后，
# 该判据在部署态永远不成立 → 落到 else 找 ../integrations（部署态不存在）→ 素材源取空。
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -d "$SCRIPT_DIR/pi" ]]; then
  SRC="$SCRIPT_DIR"
else
  SRC="$(cd "$SCRIPT_DIR/../integrations" && pwd)"
fi

# hook.sh 本体从素材源铺到部署路径（挂载配置里写死引用 HOOK_SH）
if [[ -f "$SRC/hook.sh" ]]; then
  mkdir -p "$(dirname "$HOOK_SH")"
  cp "$SRC/hook.sh" "$HOOK_SH"
  chmod 755 "$HOOK_SH"
fi

# ── 公共函数：用 jq 或 python3 安全写入 hook 配置 ──
# 用法：write_hook <config> <source> <timeout> [event]
#   event 默认 Stop（念回复）；MessageDisplay → hook.sh msgdisplay
write_hook() {
  local config_path="$1"
  local tool_name="$2"
  local timeout="$3"
  local event="${4:-Stop}"
  local cmd
  case "$event" in
    UserPromptSubmit) cmd="bash $HOOK_SH interrupt $tool_name" ;;
    MessageDisplay)   cmd="bash $HOOK_SH msgdisplay $tool_name" ;;
    *)                cmd="bash $HOOK_SH speak $tool_name" ;;
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
# 飞哥决策——打断权只归快捷键（右⌘ 说话 / Ctrl+Esc 闭嘴 / Cmd+D 译文），
# 任何 agent 会话轮次（提交、自动续写、后台）都**不再打断**播报（分桶排队播全）。
# 此前每次 make update 都经这里把 `hook.sh interrupt` 写回 settings.json，
# 与「不自动打断」决策相悖且造成提交即触发 interrupt 的重复/错乱。保留签名壳但不做事，
# 未来若要恢复「提交即打断」只需在此重新实现。
write_prompt_hook() {
  return 0   # no-op：不再挂 UserPromptSubmit interrupt
}

# ── Claude ──
# 播报走 MessageDisplay：assistant 行批增量，**按 `turn_id` 装进同一摞**（一摞 = 一次回复）。
# **不挂 Stop**——收尾判据是「新的 turn 来了就把上一个盖上」（服务端 `enqueueGrouped` 里做），
# 不需要回合结束事件。历史坑：去重那次（57179ae）commit 说「摘 Stop」，实际只把
# UserPromptSubmit 置了 no-op、这里仍默认 event=Stop，每次 make update 又把它补回来；
# **本脚本只写不删**，遗留的 Stop 请人工摘除（settings.json 的 hooks.Stop）。
# 注：Codex 无 MessageDisplay 事件，仍走 Stop（见下），别跟着一起改。
CLAUDE_JSON="$HOME/.claude/settings.json"
if [[ -f "$CLAUDE_JSON" ]]; then
  if grep -q 'hook.sh msgdisplay claude' "$CLAUDE_JSON" 2>/dev/null; then
    echo "[i] Claude MessageDisplay hook 已存在"
  elif write_hook "$CLAUDE_JSON" "claude" 10 MessageDisplay; then
    echo "✓  Claude MessageDisplay hook"
  else
    echo "⚠️  需要 jq 或 python3 写入 Claude 配置，请手动添加"
  fi
  write_prompt_hook "$CLAUDE_JSON" 10 claude
fi

# ── Codex ──
CODEX_JSON="$HOME/.codex/hooks.json"
mkdir -p "$(dirname "$CODEX_JSON")"
[[ -f "$CODEX_JSON" ]] || echo '{}' > "$CODEX_JSON"

if grep -q 'hook.sh speak codex' "$CODEX_JSON" 2>/dev/null; then
  echo "[i] Codex hook 已存在"
elif write_hook "$CODEX_JSON" "codex" 30; then
  echo "✓  Codex hook（首次触发时授权即可）"
else
  echo "⚠️  需要 jq 或 python3 写入 Codex 配置，请手动添加"
fi
write_prompt_hook "$CODEX_JSON" 30 codex

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
