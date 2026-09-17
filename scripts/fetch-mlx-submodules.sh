#!/usr/bin/env bash
# 当 git 协议走不通时，用 GitHub tarball API 预填 mlx-swift 的子模块
# 让 SwiftPM 跳过 git submodule fetch
set -euo pipefail

# 默认从 git 仓库根目录推导 checkout 路径，避免硬编码特定用户名/位置
if [[ -n "${1:-}" ]]; then
  MLX_SWIFT_CHECKOUT="$1"
elif git_root=$(git rev-parse --show-toplevel 2>/dev/null); then
  MLX_SWIFT_CHECKOUT="$git_root/.build/checkouts/mlx-swift"
else
  echo "✗ 需要传入 MLX_SWIFT_CHECKOUT 路径，或在 git 仓库内运行" >&2
  exit 1
fi
CMLX_DIR="$MLX_SWIFT_CHECKOUT/Source/Cmlx"

# 防御性检查：避免在意外路径（如其他用户的目录）写入文件
if [[ ! -d "$MLX_SWIFT_CHECKOUT" ]]; then
  echo "✗ checkout 目录不存在: $MLX_SWIFT_CHECKOUT（SwiftPM 还没拉过 mlx-swift？）" >&2
  exit 1
fi

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
