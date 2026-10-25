#!/usr/bin/env bash
# iVox 播报黑盒自检的薄 wrapper：找到 node 即转交给 tts-check.mjs。
#
# **静音闸由这里落、也由这里收**：自检压的是真实 daemon，而真人对话的播报走同一个队列——
# 一边聊着天，队列就被回复占满，用例要么被噪声检测 skip、要么因合成被挤成欠载而假红。
# 闸在手上可见（`ls /tmp/ivox-hook-muted`），落与收都归这一条命令，
# 人就不用再手动 touch/trash（2026-10-25 漏清过一次：闸没撤 → Claude 的播报全被挡在门外，
# 「没声也没字幕」）。
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GATE=/tmp/ivox-hook-muted

if ! command -v node >/dev/null 2>&1; then
  echo "✗ 需要 Node.js 18+ 才能跑播报自检：brew install node" >&2
  exit 2
fi

# 收闸：正常结束、失败退出、被 Ctrl-C 打断，都得撤掉（漏了就没声了）
cleanup() {
  if [ -e "$GATE" ]; then
    command -v trash >/dev/null 2>&1 && trash "$GATE" || rm -f "$GATE"
    echo "# 静音闸已撤（$GATE）"
  fi
}
trap cleanup EXIT INT TERM

touch "$GATE"
echo "# 静音闸已落（$GATE）——自检期间真人对话不播报"

node "$DIR/tts-check.mjs" "$@"
