#!/usr/bin/env bash
set -euo pipefail

BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

section() { echo -e "\n${BOLD}${CYAN}▸${RESET} ${BOLD}$1${RESET}"; }
ok()      { echo -e "  ${GREEN}✓${RESET} $1"; }
info()    { echo -e "  ${YELLOW}ℹ${RESET} $1"; }

echo -e "${BOLD}iVox 安装程序${RESET}"

# --- 1. 检查环境 ---
section "检查环境"

command -v swift >/dev/null 2>&1 || { echo "请先安装 Xcode 或 Swift 工具链"; exit 1; }
ok "Swift $(swift --version | head -1)"

if ! pgrep -q Music 2>/dev/null && ! pgrep -q Spotify 2>/dev/null; then
  info "未检测到 Music / Spotify 运行，媒体控制将跳过未运行的应用"
fi

cd "$(dirname "$0")"

# --- 2. 安装 ---
section "安装 (模型初始化 + release 构建 + 部署 + 守护进程)"

make install
ok "模型、配置、Hook、launchd 已就绪"

# --- 完成 ---
echo ""
echo -e "${GREEN}${BOLD}✓ iVox 安装完成！${RESET}"
echo ""
echo "  TTS / ASR 使用本地 MLX 模型，无需额外启动推理服务"
echo ""
