#!/usr/bin/env bash
# 安装 iVox hook 到 Claude / Codex / Qwen Code / PI，已存在则跳过
set -euo pipefail

HOOK_SH="${1:?用法: install-hooks.sh <hook-sh-path>}"

# ── 公共函数：用 jq 或 python3 安全写入 hook 配置 ──
write_hook() {
  local config_path="$1"
  local tool_name="$2"
  local timeout="$3"
  local cmd="bash $HOOK_SH $tool_name"

  if command -v jq &>/dev/null; then
    jq --arg cmd "$cmd" --argjson timeout "$timeout" \
      '.hooks.Stop += [{"hooks": [{"command": $cmd, "timeout": $timeout, "type": "command"}]}]' \
      "$config_path" > "${config_path}.tmp" && mv "${config_path}.tmp" "$config_path"
  elif command -v python3 &>/dev/null; then
    python3 -c "
import json, sys
cmd = sys.argv[1]
timeout = int(sys.argv[2])
path = sys.argv[3]
with open(path) as f:
    d = json.load(f)
d.setdefault('hooks', {}).setdefault('Stop', []).append({
    'hooks': [{'command': cmd, 'timeout': timeout, 'type': 'command'}]
})
with open(path, 'w') as f:
    json.dump(d, f, indent=2)
    f.write('\n')
" "$cmd" "$timeout" "$config_path"
  else
    return 1
  fi
}

# ── Claude ──
CLAUDE_JSON="$HOME/.claude/settings.json"
if [[ -f "$CLAUDE_JSON" ]]; then
  if grep -q 'hook.sh' "$CLAUDE_JSON" 2>/dev/null; then
    echo "[i] Claude hook 已存在"
  elif write_hook "$CLAUDE_JSON" "claude" 10; then
    echo "✓  Claude hook"
  else
    echo "⚠️  需要 jq 或 python3 写入 Claude 配置，请手动添加"
  fi
fi

# ── Codex ──
CODEX_JSON="$HOME/.codex/hooks.json"
mkdir -p "$(dirname "$CODEX_JSON")"
[[ -f "$CODEX_JSON" ]] || echo '{}' > "$CODEX_JSON"

if grep -q 'hook.sh' "$CODEX_JSON" 2>/dev/null; then
  echo "[i] Codex hook 已存在"
elif write_hook "$CODEX_JSON" "codex" 30; then
  echo "✓  Codex hook（首次触发时授权即可）"
else
  echo "⚠️  需要 jq 或 python3 写入 Codex 配置，请手动添加"
fi

# ── Qwen Code ──
QWEN_JSON="$HOME/.qwen/settings.json"
mkdir -p "$(dirname "$QWEN_JSON")"
[[ -f "$QWEN_JSON" ]] || echo '{}' > "$QWEN_JSON"

if grep -q 'hook.sh' "$QWEN_JSON" 2>/dev/null; then
  echo "[i] Qwen Code hook 已存在"
elif write_hook "$QWEN_JSON" "qwen" 60; then
  echo "✓  Qwen Code hook"
else
  echo "⚠️  需要 jq 或 python3 写入 Qwen Code 配置，请手动添加"
fi

# ── PI coding agent 扩展 ──
PI_EXT_DIR="$HOME/.pi/agent/extensions"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PI_EXT_SRC="$SCRIPT_DIR/ivox.ts"
if [[ -d "$PI_EXT_DIR" && -f "$PI_EXT_SRC" ]]; then
  if [[ -f "$PI_EXT_DIR/ivox.ts" ]]; then
    echo "[i] PI 扩展已存在"
  else
    cp "$PI_EXT_SRC" "$PI_EXT_DIR/ivox.ts"
    echo "✓  PI 扩展"
  fi
elif [[ -f "$PI_EXT_SRC" ]]; then
  echo "[i] PI 未安装，跳过扩展安装"
fi
