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
    "asrPath": "${HOME}/.config/ivox/model/Qwen3-ASR-1.7B-8bit",
    "ttsPath": "${HOME}/.config/ivox/model/Qwen3-TTS-12Hz-1.7B-Base-8bit"
  },
  "tts": { "language": "Chinese", "streamingInterval": 0.08, "maxRetries": 2, "retryDelayMs": 500, "outputSampleRate": 48000 },
  "playback": { "interruptCurrent": true, "idleReviveSeconds": 600, "drainBaseTimeoutSeconds": 10 },
  "mediaControl": { "enabled": true, "httpServerEnabled": true, "baseURL": "http://127.0.0.1:8888", "pausePath": "/api/pause", "resumePath": "/api/play" },
  "speechInput": { "enabled": true, "language": "zh", "autoEnter": true, "maxRecordingSeconds": 30 },
  "defaultVoice": "dayi",
  "sourceVoices": { "claude": "taozi", "codex": "wanwan", "qwen": "mizai", "pi": "dayi" },
  "voices": [
    { "name": "米仔", "id": "mizai", "refText": "大家好，我是米仔。我的声音温暖自然，适合日常播报和语音助手场景。无论是读书、讲故事，还是播报天气新闻，我都能轻松应对。", "refAudio": "~/.config/ivox/voices/ref_mizai.wav", "description": "Qwen Code 音色" },
    { "name": "甜妹桃子", "id": "taozi", "refText": "嗨，我是甜妹桃子。我有着活泼甜美的声线，听起来元气满满。如果你需要一位热情开朗的声音陪伴，选我就对了。", "refAudio": "~/.config/ivox/voices/ref_taozi.wav", "description": "Claude 音色" },
    { "name": "湾湾小何", "id": "wanwan", "refText": "你好，我是湾湾小何。我的声音温柔知性。", "refAudio": "~/.config/ivox/voices/ref_wanwan.wav", "description": "Codex 音色" },
    { "name": "大易", "id": "dayi", "refText": "大家好，我是大易。我有着沉稳可靠的男声，听起来踏实有力量。需要播报重要通知或者讲述深度内容，交给我就好。", "refAudio": "~/.config/ivox/voices/ref_dayi.wav", "description": "PI 音色" }
  ]
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
  # 独立安装时（curl | bash 走这条路径），内联下载 + 三级 fallback
  HF_BASE="https://huggingface.co"
  HF_MIRROR="https://hf-mirror.com"
  MS_BASE="https://www.modelscope.cn"
  MODELS=(
    "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit:Qwen3-TTS-12Hz-1.7B-Base-8bit"
    "mlx-community/Qwen3-ASR-1.7B-8bit:Qwen3-ASR-1.7B-8bit"
  )
  git lfs install --skip-repo 2>/dev/null || true
  for entry in "${MODELS[@]}"; do
    model_id="${entry%%:*}"
    dirname="${entry##*:}"
    target="$MODEL_DIR/$dirname"
    if [[ -d "$target" && -f "$target/config.json" ]] && ls "$target"/*.safetensors 1>/dev/null 2>&1; then
      info "模型已存在: $dirname"
      continue
    fi
    # ModelScope namespace 映射（mlx-community 在 ModelScope 不存在）
    # 用 case 替代关联数组，兼容 macOS bash 3.2 + set -u
    ms_id=""
    case "$model_id" in
      "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit") ms_id="qwen/Qwen3-TTS-12Hz-1.7B-Base" ;;
      "mlx-community/Qwen3-ASR-1.7B-8bit") ms_id="qwen/Qwen3-ASR-1.7B" ;;
    esac
    echo "  ↓ 下载 $model_id"
    mkdir -p "$target"
    ok=false
    if GIT_LFS_SKIP_SMUDGE=0 git clone --depth=1 "$HF_BASE/$model_id" "$target" 2>&1; then
      ok=true
    else
      echo "  [!] HF 失败，尝试 hf-mirror: $model_id"
      rm -rf "$target" && mkdir -p "$target"
      if GIT_LFS_SKIP_SMUDGE=0 git clone --depth=1 "$HF_MIRROR/$model_id" "$target" 2>&1; then
        ok=true
      else
        if [[ -n "$ms_id" ]]; then
          echo "  [!] hf-mirror 失败，尝试 ModelScope: $ms_id"
          rm -rf "$target" && mkdir -p "$target"
          if GIT_LFS_SKIP_SMUDGE=0 git clone --depth=1 "$MS_BASE/$ms_id.git" "$target" 2>&1; then
            ok=true
          fi
        else
          echo "  [!] ModelScope 无对应 namespace，跳过第三层 fallback"
        fi
      fi
    fi
    if ! $ok; then
      echo "  ✗ 模型下载失败: $model_id"
      rm -rf "$target"
      exit 1
    fi
    if [[ ! -f "$target/config.json" ]] || ! ls "$target"/*.safetensors 1>/dev/null 2>&1; then
      echo "  ✗ 模型下载不完整: $dirname"
      rm -rf "$target"
      exit 1
    fi
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
