#!/usr/bin/env bash
# iVox 播报黑盒自检的薄 wrapper：找到 node 即转交给 tts-check.mjs。
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v node >/dev/null 2>&1; then
  echo "✗ 需要 Node.js 18+ 才能跑播报自检：brew install node" >&2
  exit 2
fi

exec node "$DIR/tts-check.mjs" "$@"
