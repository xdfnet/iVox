#!/usr/bin/env bash
# 在 ~/.config/ivox/bridge 安装常驻 agent 桥脚本 + Claude Agent SDK。
# 幂等；国内网络用 npmmirror 兜底。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE="${HOME}/.config/ivox/bridge"

mkdir -p "$BRIDGE"
cp "$ROOT/Sources/iVox/Resources/bridge/bridge.messenger.mjs" "$BRIDGE/bridge.messenger.mjs"

# 旧版按用户分文件存 session，现单 agent：迁移唯一 session_id 到 state.json
if [[ ! -f "$BRIDGE/state.json" && -d "$BRIDGE/users" ]]; then
  sid=$(find "$BRIDGE/users" -name '*.json' -print0 2>/dev/null \
    | xargs -0 grep -hoE '"session_id":"[^"]+"' 2>/dev/null | head -1 | cut -d'"' -f4)
  if [[ -n "$sid" ]]; then
    printf '{"session_id":"%s"}\n' "$sid" > "$BRIDGE/state.json"
    echo "[i] 已迁移历史会话到 state.json"
  fi
fi

if [[ -d "$BRIDGE/node_modules/@anthropic-ai/claude-agent-sdk" ]]; then
  echo "[i] Agent SDK 已安装，跳过"
  exit 0
fi

command -v npm >/dev/null 2>&1 || {
  echo "✗  未找到 npm，请先安装 Node.js"
  exit 1
}

cd "$BRIDGE"
[[ -f package.json ]] || npm init -y >/dev/null

echo "安装 @anthropic-ai/claude-agent-sdk…"
if ! npm install @anthropic-ai/claude-agent-sdk; then
  echo "[i] 默认源失败，改用 npmmirror…"
  npm install @anthropic-ai/claude-agent-sdk --registry=https://registry.npmmirror.com
fi

echo "✓  桥与 Agent SDK 已就绪: $BRIDGE"
