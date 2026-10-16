#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

RUNTIME="${HOME}/.local/share/ivox/runtime"
LAUNCHER="${HOME}/.local/bin/ivox"
LABEL="com.user.ivox"
CONFIG="${HOME}/.config/ivox/config.json"
HOOK_SH="${HOME}/.config/ivox/hook.sh"
INTEGRATIONS_DIR="${HOME}/.config/ivox/integrations"
LOG="${HOME}/.config/ivox/daemon.log"
SOCKET="${HOME}/.config/ivox/ivox.sock"
AUTOSTART_PLIST="${HOME}/Library/LaunchAgents/com.ivox.daemon.plist"
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

  sync_integrations
}

# 组装集成资产权威源（~/.config/ivox/integrations）并幂等分发到各 agent。
# install（init）与 upgrade（deploy-bin）共用，保证升级即同步 hook/pi。
sync_integrations() {
  mkdir -p "${INTEGRATIONS_DIR}"
  cp -R "${ROOT}/integrations/." "${INTEGRATIONS_DIR}/"
  cp "${ROOT}/scripts/install-hooks.sh" "${INTEGRATIONS_DIR}/install-hooks.sh"
  chmod 755 "${INTEGRATIONS_DIR}/hook.sh" "${INTEGRATIONS_DIR}/install-hooks.sh"
  "${INTEGRATIONS_DIR}/install-hooks.sh" "${HOOK_SH}"
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
  else
    echo "⚠️  未找到 mlx-swift_Cmlx.bundle，跳过（可能未编译 MLX）" >&2
  fi
  # 复制 SPM 资源包（index.html、图标等）
  # 优先用 release 版本，避免 find 随机命中 debug 旧包
  local ivox_bundle
  ivox_bundle=$(find "${ROOT}/.build" -type d -name "iVox_iVox.bundle" 2>/dev/null | head -1)
  if [[ -n "$ivox_bundle" ]]; then
    rm -rf "${HOME}/.local/bin/iVox_iVox.bundle"
    cp -R "$ivox_bundle" "${HOME}/.local/bin/"
  else
    echo "⚠️  未找到 iVox_iVox.bundle，跳过（可能未编译资源包）" >&2
  fi
  sign_bin

  # 升级也要刷新全部集成资产（make update 走这里，不走 init）：权威源 integrations/
  # 整体重铺，再幂等分发 hook/pi（挂载已存在则跳过，未安装的 agent 安全跳过）。
  sync_integrations >/dev/null 2>&1 || true
  echo "✓  集成资产已同步: hook / pi"
}

# 是否还有 daemon 进程（不依赖 socket 文件——进程刚死时 socket 可能残留）。
daemon_alive() {
  pgrep -f "ivox serve" >/dev/null 2>&1
}

# 停止守护进程：bootout 卸载 job。KeepAlive 下只有它能真正停住——直接发停止信号会被
# 立刻拉回（旧版 `ivox off` 因此总误报「守护进程未退出」）。只卸 job、**不删 plist、
# 也不 disable**：这是升级中途的临时停，不该动用户的自启开关（那是 `ivox off` 的活）。
stop_daemon() {
  launchctl bootout "gui/$(id -u)/com.ivox.daemon" 2>/dev/null || true
  for _ in $(seq 1 40); do
    if ! daemon_alive; then
      echo "✓  守护进程已停止（launchctl bootout）"
      return 0
    fi
    sleep 0.25
  done
  echo "⚠️  守护进程未在 10s 内退出"
  return 0
}

# 启动守护进程：已装 plist 则 bootstrap 重载（RunAtLoad 拉起刚部署的二进制）；尚未装过
# （首装 / 从更早版本升级上来）则交给 CLI 写 plist 并起。
# 就绪窗口 30s——模型加载 + 键盘层权限轮询实测要十几秒，10s 会误报失败。
start_daemon() {
  if [[ -f "${AUTOSTART_PLIST}" ]]; then
    # 先 enable：`ivox off` 会 disable 本服务，被 disable 的 job 是 bootstrap 不进去的
    launchctl enable "gui/$(id -u)/com.ivox.daemon" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "${AUTOSTART_PLIST}" 2>/dev/null \
      || launchctl kickstart -k "gui/$(id -u)/com.ivox.daemon" 2>/dev/null || true
  else
    "${LAUNCHER}" on
    return 0
  fi
  for _ in $(seq 1 120); do
    if daemon_alive; then
      echo "✓  守护进程已启动（launchctl bootstrap）"
      return 0
    fi
    sleep 0.25
  done
  echo "⚠️  守护进程 30s 内未启动，请查看 ${LOG}"
  return 0
}

# 卸载要彻底：`ivox off` 只卸 job、保留 plist（那是留给「下次登录自动回来」的），
# 这里 plist 必须一起删——否则 launchd 下次登录仍会去拉一个已被删掉的二进制。
uninstall_runtime() {
  launchctl bootout "gui/$(id -u)/com.ivox.daemon" 2>/dev/null || true
  rm -f "${AUTOSTART_PLIST}"
  rm -f "${LAUNCHER}"
  rm -rf "${HOME}/.local/share/ivox/runtime"
  echo "✓  已卸载（保留 ~/.config/ivox/）"
}

case "${1:-help}" in
  check-env) check_env ;;
  init) init_config ;;
  voices) install_voices ;;
  deploy-bin) deploy_bin ;;
  stop) stop_daemon ;;
  start) start_daemon ;;
  sign) sign_bin ;;
  uninstall) uninstall_runtime ;;
  *)
    echo "用法: scripts/runtime.sh {check-env|init|voices|deploy-bin|stop|start|sign|uninstall}"
    exit 1
    ;;
esac
