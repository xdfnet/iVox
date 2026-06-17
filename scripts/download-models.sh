#!/usr/bin/env bash
set -euo pipefail

MODEL_ROOT="${1:-$HOME/.config/ivox/model}"
HF_BASE="https://huggingface.co"

# 模型列表：(HF模型ID, 本地目录名)
MODELS=(
  "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit:Qwen3-TTS-12Hz-1.7B-Base-8bit"
  "mlx-community/Qwen3-ASR-1.7B-4bit:Qwen3-ASR-1.7B-4bit"
)

is_complete() {
  local dir="$1"
  [[ -d "$dir" && -f "$dir/config.json" ]] && ls "$dir"/*.safetensors 1>/dev/null 2>&1
}

for entry in "${MODELS[@]}"; do
  model_id="${entry%%:*}"
  dirname="${entry##*:}"
  target="$MODEL_ROOT/$dirname"

  if is_complete "$target"; then
    echo "[i] 模型已存在: $target ($(du -sh "$target" | cut -f1))"
    continue
  fi

  echo "↓  下载 $model_id -> $target"
  mkdir -p "$target"
  git lfs install --skip-repo 2>/dev/null
  GIT_LFS_SKIP_SMUDGE=0 git clone --depth=1 "$HF_BASE/$model_id" "$target" 2>&1

  if ! is_complete "$target"; then
    echo "✗  模型下载不完整: $target"
    exit 1
  fi
  echo "✓  模型就绪: $target ($(du -sh "$target" | cut -f1))"
done
