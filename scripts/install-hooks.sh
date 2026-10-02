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

# ── DeepSeek Harness ──
# dsh 的回复文本由本地 cordis 插件 ivox-tts.mjs 在每轮结束时直投 hook.sh；
# 桥接插件（dsh-hooks-claude-code）的 Stop payload 不含回复文本，故不再使用。
DSH_PROFILE_DIR="$HOME/.dsh/profiles/desktop"
DSH_PATCH="$DSH_PROFILE_DIR/cordis.patch.yml"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

DSH_PLUGIN_SRC=""
for cand in "$SCRIPT_DIR/dsh-plugin" "$SCRIPT_DIR/../Sources/iVox/Resources/dsh-plugin"; do
  if [[ -f "$cand/ivox-tts.mjs" ]]; then
    DSH_PLUGIN_SRC="$cand"
    break
  fi
done

if [[ -d "$DSH_PROFILE_DIR" ]]; then
  if [[ -z "$DSH_PLUGIN_SRC" ]]; then
    echo "⚠️  未找到 dsh-plugin/ivox-tts.mjs，跳过 DSH 播报插件"
  else
    mkdir -p "$DSH_PROFILE_DIR/plugins"
    cp "$DSH_PLUGIN_SRC/ivox-tts.mjs" "$DSH_PROFILE_DIR/plugins/ivox-tts.mjs"
    # 匿名 package.json：profile 根 package.json 有 name 无 version，
    # 插件清单校验会顺着目录往上找到它并抛错，导致每次请求都失败。
    cp "$DSH_PLUGIN_SRC/package.json" "$DSH_PROFILE_DIR/plugins/package.json"

    if [[ -f "$DSH_PATCH" ]]; then
      if grep -q 'ivox-tts' "$DSH_PATCH"; then
        echo "[i] DSH 播报插件挂载已存在"
      else
        printf '\n- insert:\n    - id: ivox-tts\n      name: "./plugins/ivox-tts.mjs"\n' >> "$DSH_PATCH"
        echo "✓  DSH profile 已挂载 ivox-tts"
      fi
    else
      echo "⚠️  未找到 $DSH_PATCH，请手动挂载 ./plugins/ivox-tts.mjs"
    fi

    # 清理旧方案残留：hooks.json 的 Stop 已无意义（payload 没有文本）
    DSH_JSON="$HOME/.dsh/hooks.json"
    if [[ -f "$DSH_JSON" ]] && grep -q 'hook.sh' "$DSH_JSON" 2>/dev/null; then
      python3 - "$DSH_JSON" <<'PYEOF' 2>/dev/null && echo "✓  已清理 DSH hooks.json 里失效的 Stop"
import json, sys
p = sys.argv[1]
d = json.load(open(p))
if d.get("hooks", {}).get("Stop"):
    d["hooks"]["Stop"] = []
    json.dump(d, open(p, "w"), indent=2)
    open(p, "a").write("\n")
PYEOF
    fi

    echo "✓  DSH 播报插件（重启 dsh 生效）"
  fi
fi

# ── PI coding agent 扩展 ──
PI_EXT_DIR="$HOME/.pi/agent/extensions"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PI_EXT_SRC="$SCRIPT_DIR/ivox.ts"
if [[ -d "$PI_EXT_DIR" && -f "$PI_EXT_SRC" ]]; then
  # 无条件覆盖：与 dsh 插件一致，否则仓库里更新了扩展也永远装不上去
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
