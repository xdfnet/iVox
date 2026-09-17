#!/usr/bin/env bash
set -euo pipefail

MODEL_ROOT="${1:-$HOME/.config/ivox/model}"
HF_BASE="https://huggingface.co"
HF_MIRROR="https://hf-mirror.com"
MS_BASE="https://www.modelscope.cn"

# 模型列表：(HF模型ID, 本地目录名)
MODELS=(
  "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit:Qwen3-TTS-12Hz-1.7B-Base-8bit"
  "mlx-community/Qwen3-ASR-1.7B-8bit:Qwen3-ASR-1.7B-8bit"
)

# ModelScope namespace 与 HF 不同：mlx-community 在 ModelScope 上不存在，
# 这里只放已确认存在的原始权重映射，未命中则跳过 ModelScope 直接报错
declare -A MS_MAPPING=(
  ["mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit"]="qwen/Qwen3-TTS-12Hz-1.7B-Base"
  ["mlx-community/Qwen3-ASR-1.7B-8bit"]="qwen/Qwen3-ASR-1.7B"
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

  echo "↓ 下载 $model_id -> $target"
  rm -rf "$target"
  mkdir -p "$target"
  git lfs install --skip-repo 2>/dev/null
  ok=false
  if GIT_LFS_SKIP_SMUDGE=0 git clone --depth=1 "$HF_BASE/$model_id" "$target" 2>&1; then
    ok=true
  else
    echo "[!] HF 失败，切换 hf-mirror: $model_id"
    rm -rf "$target" && mkdir -p "$target"
    if GIT_LFS_SKIP_SMUDGE=0 git clone --depth=1 "$HF_MIRROR/$model_id" "$target" 2>&1; then
      ok=true
    else
      ms_id="${MS_MAPPING[$model_id]:-}"
      if [[ -n "$ms_id" ]]; then
        echo "[!] hf-mirror 失败，切换 ModelScope: $ms_id"
        rm -rf "$target" && mkdir -p "$target"
        if GIT_LFS_SKIP_SMUDGE=0 git clone --depth=1 "$MS_BASE/$ms_id.git" "$target" 2>&1; then
          ok=true
        fi
      else
        echo "[!] ModelScope 无对应 namespace，跳过第三层 fallback"
      fi
    fi
  fi

  if ! $ok; then
    echo "✗ 模型下载失败: $model_id"
    rm -rf "$target"
    exit 1
  fi
  if ! is_complete "$target"; then
    echo "✗ 模型下载不完整: $target"
    rm -rf "$target"
    exit 1
  fi
  echo "✓ 模型就绪: $target ($(du -sh "$target" | cut -f1))"
done
