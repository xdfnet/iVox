#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

RUNTIME="${HOME}/.local/share/ivox/runtime"
LAUNCHER="${HOME}/.local/bin/ivox"
LABEL="com.user.ivox"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
CONFIG="${HOME}/.config/ivox/config.json"
HOOK_SH="${HOME}/.config/ivox/hook.sh"
LOG="${HOME}/.config/ivox/daemon.log"
SOCKET="${HOME}/.config/ivox/ivox.sock"
VOICE_DIR="${HOME}/.config/ivox/voices"
VOICE_SRC="${ROOT}/Sources/iVox/Resources/voices"

voice_files=(
  ref_mizai.wav
  ref_taozi.wav
  ref_wanwan.wav
  ref_dayi.wav
)

check_env() {
  command -v swift >/dev/null 2>&1 || {
    echo "✗  请先安装 Xcode 或 Swift 工具链"
    exit 1
  }
}

init_config() {
  mkdir -p "${HOME}/.config/ivox"

  if [[ ! -f "${CONFIG}" ]]; then
    cp "${ROOT}/Sources/iVox/Resources/config.example.json" "${CONFIG}"
    sed -i '' "s|\"~|\"${HOME}|g" "${CONFIG}"
    echo "✓  已生成配置: ${CONFIG}"
  else
    echo "[i] 配置已存在: ${CONFIG}"
  fi

  cp "${ROOT}/Sources/iVox/Resources/hook.sh" "${HOOK_SH}"
  chmod 755 "${HOOK_SH}"
  echo "✓  hook: ${HOOK_SH}"


  "${ROOT}/scripts/install-hooks.sh" "${HOOK_SH}"
}

install_voices() {
  mkdir -p "${VOICE_DIR}"

  for file in "${voice_files[@]}"; do
    src="${VOICE_SRC}/${file}"
    dst="${VOICE_DIR}/${file}"

    if [[ -f "${dst}" ]]; then
      echo "[i] 参考音频已存在: ${dst}"
    elif [[ -f "${src}" ]]; then
      cp "${src}" "${dst}"
      echo "✓  已初始化参考音频: ${dst}"
    else
      echo "✗  缺少参考音频资源: ${src}"
      exit 1
    fi
  done
}

sign_bin() {
  if codesign --force --sign - "${LAUNCHER}" 2>/dev/null; then
    echo "✓  ad-hoc 签名完成"
  else
    echo "⚠️  ad-hoc 签名失败: ${LAUNCHER}"
  fi
}

deploy_bin() {
  mkdir -p "${HOME}/.local/bin"
  cp "${ROOT}/.build/release/iVox" "${LAUNCHER}"
  chmod 755 "${LAUNCHER}"
  # 动态查找 Metal shader bundle（位置随编译配置变化）
  local mlx_bundle
  mlx_bundle=$(find "${ROOT}/.build" -type d -name "mlx-swift_Cmlx.bundle" 2>/dev/null | head -1)
  if [[ -n "$mlx_bundle" ]]; then
    rm -rf "${HOME}/.local/bin/mlx-swift_Cmlx.bundle"
    cp -R "$mlx_bundle" "${HOME}/.local/bin/"
  fi
  # 复制 SPM 资源包（index.html、图标等）
  # 优先用 release 版本，避免 find 随机命中 debug 旧包
  local ivox_bundle
  ivox_bundle=$(find "${ROOT}/.build/arm64-apple-macosx/release" -type d -name "iVox_iVox.bundle" 2>/dev/null | head -1)
  if [[ -n "$ivox_bundle" ]]; then
    rm -rf "${HOME}/.local/bin/iVox_iVox.bundle"
    cp -R "$ivox_bundle" "${HOME}/.local/bin/"
  fi
  sign_bin
}

write_launchd_plist() {
  mkdir -p "${HOME}/Library/LaunchAgents" "${HOME}/.config/ivox" "${RUNTIME}"
  cat > "${PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key><array>
    <string>${LAUNCHER}</string>
    <string>serve</string>
  </array>
  <key>WorkingDirectory</key><string>${HOME}/.local/bin</string>
  <key>ProcessType</key><string>Standard</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${LOG}</string>
  <key>StandardErrorPath</key><string>${LOG}</string>
  <key>EnvironmentVariables</key><dict>
    <key>HOME</key><string>${HOME}</string>
  </dict>
</dict></plist>
PLIST
}

start_launchd() {
  local domain="gui/$(id -u)"
  local output

  # 清理可能残留的旧进程
  pkill -x ivox 2>/dev/null || true

  write_launchd_plist
  launchctl bootout "${domain}" "${PLIST}" 2>/dev/null || \
    launchctl bootout "${domain}/${LABEL}" 2>/dev/null || true
  sleep 0.5
  rm -f "${SOCKET}"

  if ! output="$(launchctl bootstrap "${domain}" "${PLIST}" 2>&1)"; then
    if launchctl print "${domain}/${LABEL}" >/dev/null 2>&1; then
      launchctl kickstart -k "${domain}/${LABEL}" 2>/dev/null || true
    else
      echo "${output}"
      exit 1
    fi
  fi

  launchctl kickstart -k "${domain}/${LABEL}" 2>/dev/null || true
  echo -n "等待守护进程就绪"
  for _ in {1..40}; do
    [[ -S "${SOCKET}" ]] && { echo ""; break; }
    echo -n "."
    sleep 0.25
  done
  if [[ ! -S "${SOCKET}" ]]; then
    echo ""
    echo "✗  守护进程未就绪，请查看日志: ${LOG}"
    exit 1
  fi
  echo "✓  守护进程已启动"
}

uninstall_runtime() {
  launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
  rm -f "${PLIST}"
  rm -f "${LAUNCHER}"
  rm -rf "${HOME}/.local/share/ivox/runtime"
  echo "✓  已卸载（保留 ~/.config/ivox/）"
}

case "${1:-help}" in
  check-env) check_env ;;
  init) init_config ;;
  voices) install_voices ;;
  deploy-bin) deploy_bin ;;
  launchd) start_launchd ;;
  sign) sign_bin ;;
  uninstall) uninstall_runtime ;;
  *)
    echo "用法: scripts/runtime.sh {check-env|init|voices|deploy-bin|launchd|sign|uninstall}"
    exit 1
    ;;
esac
