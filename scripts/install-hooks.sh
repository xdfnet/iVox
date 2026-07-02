#!/usr/bin/env bash
# 安装 iVox hook 到 Claude / Codex / Qwen Code，已存在则跳过
set -euo pipefail

HOOK_SH="${1:?用法: install-hooks.sh <hook-sh-path>}"

# ── Claude ──
CLAUDE_JSON="$HOME/.claude/settings.json"
if [[ -f "$CLAUDE_JSON" ]]; then
  if grep -q 'hook.sh' "$CLAUDE_JSON" 2>/dev/null; then
    echo "[i] Claude hook 已存在"
  else
    # 用 jq 加 hook，没有 jq 就 fallback 到系统 python3
    if command -v jq &>/dev/null; then
      jq '.hooks.Stop += [{"hooks": [{"command": "bash '"$HOOK_SH"' claude", "timeout": 10, "type": "command"}]}]' "$CLAUDE_JSON" > "${CLAUDE_JSON}.tmp" && mv "${CLAUDE_JSON}.tmp" "$CLAUDE_JSON"
      echo "✓  Claude hook"
    elif command -v python3 &>/dev/null; then
      python3 -c "
import json
with open('$CLAUDE_JSON') as f:
    d = json.load(f)
d.setdefault('hooks', {}).setdefault('Stop', []).append({
    'hooks': [{'command': 'bash $HOOK_SH claude', 'timeout': 10, 'type': 'command'}]
})
with open('$CLAUDE_JSON', 'w') as f:
    json.dump(d, f, indent=2)
    f.write('\n')
"
      echo "✓  Claude hook"
    else
      echo "⚠️  需要 jq 或 python3 写入 Claude 配置，请手动添加"
    fi
  fi
fi

# ── Codex ──
CODEX_JSON="$HOME/.codex/hooks.json"
mkdir -p "$(dirname "$CODEX_JSON")"
[[ -f "$CODEX_JSON" ]] || echo '{}' > "$CODEX_JSON"

if grep -q 'hook.sh' "$CODEX_JSON" 2>/dev/null; then
  echo "[i] Codex hook 已存在"
else
  if command -v jq &>/dev/null; then
    jq '.hooks.Stop += [{"hooks": [{"command": "bash '"$HOOK_SH"' codex", "timeout": 30, "type": "command"}]}]' "$CODEX_JSON" > "${CODEX_JSON}.tmp" && mv "${CODEX_JSON}.tmp" "$CODEX_JSON"
    echo "✓  Codex hook（首次触发时授权即可）"
  elif command -v python3 &>/dev/null; then
    python3 -c "
import json
with open('$CODEX_JSON') as f:
    d = json.load(f)
d.setdefault('hooks', {}).setdefault('Stop', []).append({
    'hooks': [{'command': 'bash $HOOK_SH codex', 'timeout': 30, 'type': 'command'}]
})
with open('$CODEX_JSON', 'w') as f:
    json.dump(d, f, indent=2)
    f.write('\n')
"
    echo "✓  Codex hook（首次触发时授权即可）"
  else
    echo "⚠️  需要 jq 或 python3 写入 Codex 配置，请手动添加"
  fi
fi

# ── Qwen Code ──
QWEN_JSON="$HOME/.qwen/settings.json"
mkdir -p "$(dirname "$QWEN_JSON")"
[[ -f "$QWEN_JSON" ]] || echo '{}' > "$QWEN_JSON"

if grep -q 'hook.sh' "$QWEN_JSON" 2>/dev/null; then
  echo "[i] Qwen Code hook 已存在"
else
  if command -v jq &>/dev/null; then
    jq '.hooks.Stop += [{"hooks": [{"command": "bash '"$HOOK_SH"' qwen", "timeout": 60, "type": "command"}]}]' "$QWEN_JSON" > "${QWEN_JSON}.tmp" && mv "${QWEN_JSON}.tmp" "$QWEN_JSON"
    echo "✓  Qwen Code hook"
  elif command -v python3 &>/dev/null; then
    python3 -c "
import json
with open('$QWEN_JSON') as f:
    d = json.load(f)
d.setdefault('hooks', {}).setdefault('Stop', []).append({
    'hooks': [{'command': 'bash $HOOK_SH qwen', 'timeout': 60, 'type': 'command'}]
})
with open('$QWEN_JSON', 'w') as f:
    json.dump(d, f, indent=2)
    f.write('\n')
"
    echo "✓  Qwen Code hook"
  else
    echo "⚠️  需要 jq 或 python3 写入 Qwen Code 配置，请手动添加"
  fi
fi
