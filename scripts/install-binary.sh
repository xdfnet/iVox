#!/usr/bin/env bash
# iVox 快速安装 — 从 GitHub Releases 下载预编译二进制
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/xdfnet/iVox/master/scripts/install-binary.sh | bash
#   # 或
#   bash scripts/install-binary.sh
set -euo pipefail

BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"
section() { echo -e "\n${BOLD}${CYAN}▸${RESET} ${BOLD}$1${RESET}"; }
ok()      { echo -e "  ${GREEN}✓${RESET} $1"; }
info()    { echo -e "  ${YELLOW}ℹ${RESET} $1"; }

REPO="xdfnet/iVox"
VERSION="${1:-latest}"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/ivox"
RUNTIME_DIR="$HOME/.local/share/ivox"
VOICE_DIR="$CONFIG_DIR/voices"

echo -e "${BOLD}iVox 快速安装${RESET}"

# ── 1. 检查环境 ──
section "检查环境"
case "$(uname -sm)" in
  Darwin\ arm64) ok "macOS Apple Silicon" ;;
  Darwin\ x86_64) info "macOS Intel（可能较慢）" ;;
  *) echo "✗ 仅支持 macOS"; exit 1 ;;
esac

# ── 2. 下载安装包 ──
section "下载 iVox"
mkdir -p "$BIN_DIR"

if [[ "$VERSION" == "latest" ]]; then
  ARCH="$(uname -m)"
  case "$ARCH" in
    arm64)   ARCH_PATTERN="arm64|aarch64" ;;
    x86_64)  ARCH_PATTERN="x86_64|amd64" ;;
    *)       ARCH_PATTERN="darwin" ;;
  esac
  ASSET_URL=$(curl -sfL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep "browser_download_url" | grep "\.tar\.gz" \
    | grep -iE "darwin|macos" | grep -iE "$ARCH_PATTERN" | cut -d'"' -f4 | head -1)
else
  ASSET_URL="https://github.com/$REPO/releases/download/$VERSION/ivox-${VERSION}.tar.gz"
fi

if [[ -z "$ASSET_URL" ]]; then
  echo "✗ 获取下载地址失败"
  exit 1
fi

echo "   来自: $ASSET_URL"
curl -fL --progress-bar -o /tmp/ivox-pkg.tar.gz "$ASSET_URL"
tar xzf /tmp/ivox-pkg.tar.gz -C "$BIN_DIR"
chmod 755 "$BIN_DIR/ivox"
rm -f /tmp/ivox-pkg.tar.gz
ok "iVox $(du -h "$BIN_DIR/ivox" | cut -f1) + Metal shader"

# ── 3.5. ad-hoc 签名 ──
section "ad-hoc 签名"
if codesign --force --sign - "$BIN_DIR/ivox" 2>/dev/null; then
  ok "ad-hoc 签名完成"
else
  info "ad-hoc 签名跳过（无 Xcode 命令行工具）"
fi

# ── 4. 配置 ──
section "配置初始化"
mkdir -p "$CONFIG_DIR" "$VOICE_DIR" "$RUNTIME_DIR"

# 默认配置
if [[ ! -f "$CONFIG_DIR/config.json" ]]; then
  cat > "$CONFIG_DIR/config.json" <<JSON
{
  "models": {
    "asrPath": "${HOME}/.config/ivox/model/Qwen3-ASR-1.7B-4bit",
    "ttsPath": "${HOME}/.config/ivox/model/Qwen3-TTS-12Hz-1.7B-Base-8bit"
  },
  "tts": { "language": "Chinese", "streamingInterval": 0.08, "maxRetries": 2, "retryDelayMs": 500, "outputSampleRate": 48000 },
  "playback": { "interruptCurrent": true, "idleReviveSeconds": 600, "drainBaseTimeoutSeconds": 10 },
  "mediaControl": { "enabled": true, "baseURL": "http://127.0.0.1:8888", "pausePath": "/api/pause", "resumePath": "/api/play" },
  "speechInput": { "enabled": true, "language": "zh", "autoEnter": true, "maxRecordingSeconds": 30 },
  "defaultVoice": "mizai",
  "sourceVoices": { "claude": "taozi", "codex": "wanwan" },
  "voices": []
}
JSON
  ok "默认配置"
else
  info "配置已存在"
fi

# ── 5. 下载模型 ──
section "下载 MLX 模型"
MODEL_DIR="$CONFIG_DIR/model"
mkdir -p "$MODEL_DIR"

# 检查是否有 download-models.sh（从源码运行时有）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$SCRIPT_DIR/download-models.sh" ]]; then
  bash "$SCRIPT_DIR/download-models.sh" "$MODEL_DIR"
else
  # 独立安装时，内联模型下载逻辑
  HF_BASE="https://huggingface.co"
  MODELS=(
    "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit:Qwen3-TTS-12Hz-1.7B-Base-8bit"
    "mlx-community/Qwen3-ASR-1.7B-4bit:Qwen3-ASR-1.7B-4bit"
  )
  for entry in "${MODELS[@]}"; do
    model_id="${entry%%:*}"
    dirname="${entry##*:}"
    target="$MODEL_DIR/$dirname"
    if [[ -d "$target" && -f "$target/config.json" ]] && ls "$target"/*.safetensors 1>/dev/null 2>&1; then
      info "模型已存在: $dirname"
      continue
    fi
    echo "  ↓ 下载 $model_id"
    mkdir -p "$target"
    git lfs install --skip-repo 2>/dev/null || true
    GIT_LFS_SKIP_SMUDGE=0 git clone --depth=1 "$HF_BASE/$model_id" "$target" 2>&1
    ok "$dirname ($(du -sh "$target" | cut -f1))"
  done
fi

# ── 6. 服务管理 ──
section "服务管理（不注册 launchd 自启）"
echo "  ivox 不再注册 launchd 自启动，需要时手动控制:"
echo "    启动: ${BIN_DIR}/ivox start"
echo "    停止: ${BIN_DIR}/ivox stop"
echo "    状态: ${BIN_DIR}/ivox status"

# ── 完成 ──
echo ""
echo -e "${GREEN}${BOLD}✓ iVox 安装完成！${RESET}"
echo ""
echo "   二进制: ${BIN_DIR}/ivox"
echo "   配置:   ${CONFIG_DIR}/config.json"
echo "   日志:   ${LOG}"
echo "   模型:   ${MODEL_DIR} $(du -sh "$MODEL_DIR" | cut -f1)"
echo ""
echo "   ivox serve    # 前台调试"
echo "   ivox status   # 查看状态"
