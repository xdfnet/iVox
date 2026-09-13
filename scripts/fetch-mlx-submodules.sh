#!/usr/bin/env bash
# 当 git 协议走不通时，用 GitHub tarball API 预填 mlx-swift 的子模块
# 让 SwiftPM 跳过 git submodule fetch
set -euo pipefail

MLX_SWIFT_CHECKOUT="${1:-/Users/admin/iCode/iVox/.build/checkouts/mlx-swift}"
CMLX_DIR="$MLX_SWIFT_CHECKOUT/Source/Cmlx"

SUBMODULES="mlx:https://github.com/ml-explore/mlx
mlx-c:https://github.com/ml-explore/mlx-c"

fetch_one() {
  local name="$1"
  local url="$2"
  local target="$CMLX_DIR/$name"

  if [[ -d "$target" && -n "$(ls -A "$target" 2>/dev/null)" ]]; then
    echo "[i] 子模块已存在: $target"
    return 0
  fi

  echo "↓  下载 $name (tarball)"
  rm -rf "$target"
  mkdir -p "$target"
  curl -sL --max-time 120 "$url/archive/refs/heads/main.tar.gz" \
    | tar -xz --strip-components=1 -C "$target"
  touch "$target/.git"
  echo "✓  $name 就绪: $target"
}

while IFS=: read -r name url; do
  fetch_one "$name" "$url"
done <<< "$SUBMODULES"

echo "✓  mlx 子模块预填完成"
