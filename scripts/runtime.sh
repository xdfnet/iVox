#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

RUNTIME="${HOME}/.local/share/ivox/runtime"
LAUNCHER="${HOME}/.local/bin/ivox"
LABEL="com.user.ivox"
CONFIG="${HOME}/.config/ivox/config.json"
HOOK_SH="${HOME}/.config/ivox/hook.sh"
INTEGRATIONS_DIR="${HOME}/.config/ivox/integrations"
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
    echo "   热键可在配置的 hotkeys 段改（如 \"translate\": \"cmd+shift+d\"），改完跑 ivox restart"
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

# 停止守护进程：交给 CLI 的 `ivox off`，这里不再自己拼 launchctl——两处各写一套已经吃过
# 一次亏（`ivox autostart off` 删 plist、本文件的 stop 却保留 plist，同样叫「停」却是两回事）。
# `|| true` 兜住首装场景（那时 ~/.local/bin/ivox 还不存在）与 set -e。
stop_daemon() {
  "${LAUNCHER}" off || true
}

# 启动守护进程：交给 CLI 的 `ivox on`（enable + 写 plist + bootstrap + 等 socket 就绪）。
# 就绪窗口在 CLI 里（30s：模型加载 + 键盘层权限轮询实测要十几秒）。
# **不吞退出码**：`ivox on` 起不来时返回非 0，必须让它冒泡——`make update` 靠它判断
# 「新二进制是不是坏的」，吞了就没有回滚的触发点（update 会报成功而服务是死的）。
start_daemon() {
  "${LAUNCHER}" on
}

# ── 更新的备份/回滚 ──
# 备份范围**等于部署范围**：`deploy-bin` 覆盖什么就备什么，多一分不备、少一分不漏。
#   · 二进制 + 两个资源包（约 59M，SSD 上毫秒级）
#   · 集成资产 hook.sh / integrations/（约 30K）
# 刻意**不**碰 settings.json 之类：install-hooks 对别人的配置是「只写不删」，
# 回滚去改它就越界了（那份归各 agent 自己管）。
ROLLBACK_DIR="${HOME}/.config/ivox/rollback"
BIN_ITEMS=(ivox mlx-swift_Cmlx.bundle iVox_iVox.bundle)
CONFIG_ITEMS=(hook.sh integrations)

# 更新前：留一份当前部署态
snapshot_bin() {
  rm -rf "${ROLLBACK_DIR}"
  mkdir -p "${ROLLBACK_DIR}/bin" "${ROLLBACK_DIR}/config"
  # 用 if 不用 `[[ ]] && cp`：后者在文件不存在时整条返回 1，set -e 会直接把脚本带走
  for item in "${BIN_ITEMS[@]}"; do
    if [[ -e "${HOME}/.local/bin/${item}" ]]; then
      cp -R "${HOME}/.local/bin/${item}" "${ROLLBACK_DIR}/bin/"
    fi
  done
  for item in "${CONFIG_ITEMS[@]}"; do
    if [[ -e "${HOME}/.config/ivox/${item}" ]]; then
      cp -R "${HOME}/.config/ivox/${item}" "${ROLLBACK_DIR}/config/"
    fi
  done
  echo "✓  已备份当前版本（回滚用）"
}

# 更新成功：备份没用了
discard_snapshot() {
  rm -rf "${ROLLBACK_DIR}"
}

# 更新失败（含被中断）：还原上一版并把它拉起来。
# 编译失败时二进制其实没被动过，但这里一律"还原 + 起"——统一一条路径，
# 且还原的是同一份内容，等价于把状态复原。
rollback_bin() {
  if [[ -d "${ROLLBACK_DIR}/bin" ]]; then
    echo "⚠️  更新失败，回滚到上一版…"
    for item in "${BIN_ITEMS[@]}"; do
      [[ -e "${ROLLBACK_DIR}/bin/${item}" ]] || continue
      rm -rf "${HOME}/.local/bin/${item}"
      cp -R "${ROLLBACK_DIR}/bin/${item}" "${HOME}/.local/bin/"
    done
    chmod 755 "${LAUNCHER}"
    sign_bin
    for item in "${CONFIG_ITEMS[@]}"; do
      [[ -e "${ROLLBACK_DIR}/config/${item}" ]] || continue
      rm -rf "${HOME}/.config/ivox/${item}"
      cp -R "${ROLLBACK_DIR}/config/${item}" "${HOME}/.config/ivox/"
    done
  else
    echo "⚠️  更新失败，但没有备份可回滚（首次部署？），仅把服务拉回来"
  fi
  "${LAUNCHER}" on || echo "⚠️  回滚后服务仍未能启动，请查看 ${HOME}/.config/ivox/daemon.log"
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
  snapshot) snapshot_bin ;;
  discard-snapshot) discard_snapshot ;;
  rollback) rollback_bin ;;
  sign) sign_bin ;;
  uninstall) uninstall_runtime ;;
  *)
    echo "用法: scripts/runtime.sh {check-env|init|voices|deploy-bin|stop|start|snapshot|discard-snapshot|rollback|sign|uninstall}"
    exit 1
    ;;
esac
