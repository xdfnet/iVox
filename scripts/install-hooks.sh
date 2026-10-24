#!/usr/bin/env bash
# 安装 iVox hook 到 Claude / PI，已存在则跳过
set -euo pipefail

HOOK_SH="${1:?用法: install-hooks.sh <hook-sh-path>}"

# ── 素材源目录 ──
# 分发器与被它分发的资产**永远同目录**（仓库 scripts/ ↔ 部署态 ~/.config/ivox/scripts/），
# 所以素材源就是本脚本所在目录——不需要再探测。
# 早先的探测逻辑（判 pi/ 是否同级、否则回退 ../integrations）是因为分发器在 scripts/
# 而资产在仓库顶层 integrations/，两处分家才不得不猜；合到一处后整段删掉。
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR"

# hook.sh 本体从素材源铺到部署路径（挂载配置里写死引用 HOOK_SH）
if [[ -f "$SRC/hook.sh" ]]; then
  mkdir -p "$(dirname "$HOOK_SH")"
  cp "$SRC/hook.sh" "$HOOK_SH"
  chmod 755 "$HOOK_SH"
fi

# ── 公共函数：用 jq 或 python3 安全写入 hook 配置 ──
# 用法：write_hook <config> <source> <timeout> [event] [action]
#   event  = settings.json 里的事件键。**只认 Claude Code 认识的名字**——自造 End 之类
#            不认的名字会把整条 hook 静默丢弃（2026-10-16 修的就是这个）。
#   action = 命令选择：msgdisplay（送整页正文）| end（收尾暗号，不出声）
# 认不得的 action 直接失败，不猜——猜出来的是一条没人要的 hook。
write_hook() {
  local config_path="$1"
  local tool_name="$2"
  local timeout="$3"
  local event="${4:-MessageDisplay}"
  local action="${5:-$event}"   # 缺省跟 event 走，保持省略后两个参数的调用点行为不变
  local cmd
  case "$action" in
    MessageDisplay)   cmd="bash $HOOK_SH msgdisplay $tool_name" ;;
    end)              cmd="bash $HOOK_SH end $tool_name" ;;
    *)                return 1 ;;
  esac

  if command -v jq &>/dev/null; then
    jq --arg cmd "$cmd" --argjson timeout "$timeout" --arg event "$event" \
      '.hooks[$event] += [{"hooks": [{"command": $cmd, "timeout": $timeout, "type": "command"}]}]' \
      "$config_path" > "${config_path}.tmp" && mv "${config_path}.tmp" "$config_path"
  elif command -v python3 &>/dev/null; then
    python3 -c "
import json, sys
cmd, timeout, path, event = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
with open(path) as f:
    d = json.load(f)
d.setdefault('hooks', {}).setdefault(event, []).append({
    'hooks': [{'command': cmd, 'timeout': timeout, 'type': 'command'}]
})
with open(path, 'w') as f:
    json.dump(d, f, indent=2)
    f.write('\n')
" "$cmd" "$timeout" "$config_path" "$event"
  else
    return 1
  fi
}

# UserPromptSubmit 打断 hook 已**废弃**：不再自动挂「提交即打断」。
# 飞哥决策——打断权只归快捷键（右⌘ 说话 / Ctrl+Esc 闭嘴 / Opt+Z 译文），
# 任何 agent 会话轮次（提交、自动续写、后台）都**不再打断**播报（分桶排队播全）。
# 此前每次 make update 都经这里把 `hook.sh interrupt` 写回 settings.json，
# 与「不自动打断」决策相悖且造成提交即触发 interrupt 的重复/错乱。保留签名壳但不做事，
# 未来若要恢复「提交即打断」只需在此重新实现。
write_prompt_hook() {
  return 0   # no-op：不再挂 UserPromptSubmit interrupt
}

# ── Claude ──
# 播报走 MessageDisplay：assistant 行批增量，**按 `turn_id` 装进同一摞**（一摞 = 一次回复）。
# 收尾判据是「新的 turn 来了就把上一个盖上」（服务端 `enqueueGrouped` 里做）；**另挂 Stop 只作收尾信号**
# （`hook.sh end`，不出声）——用户说完一轮后不会有下一条 turn，光靠"盖上"只能等空闲宽限，Stop 一到就能
# 立刻收尾（字幕立刻回来）。历史坑：去重那次（57179ae）摘的是**指向 `hook.sh speak` 的**那条 Stop
# （连正文一起送 → 与 MessageDisplay 重复播两遍），不是"不许挂 Stop"；现在这条不发正文，不重复。
# **本脚本只写不删**：遗留的旧 Stop（命令里是 `hook.sh speak claude`）请人工摘除，否则重复播报。
CLAUDE_JSON="$HOME/.claude/settings.json"
if [[ -f "$CLAUDE_JSON" ]]; then
  if grep -q 'hook.sh msgdisplay claude' "$CLAUDE_JSON" 2>/dev/null; then
    echo "[i] Claude MessageDisplay hook 已存在"
  elif write_hook "$CLAUDE_JSON" "claude" 10 MessageDisplay; then
    echo "✓  Claude MessageDisplay hook"
  else
    echo "⚠️  需要 jq 或 python3 写入 Claude 配置，请手动添加"
  fi
  # 收尾信号：Stop 事件 → `hook.sh end`，**只发"说完了"这个暗号、不带正文**。
  # 有了它，回复一结束队列立刻收尾（字幕立刻回来），空闲宽限退化成纯兜底；
  # 没有它也不会错——只是最后那 2 秒要等满（用户不按任何键时）。
  # 与「历史坑」的区别：当年挂的是 `hook.sh speak`（连正文一起送 → 与 MessageDisplay 重复播两遍），
  # 现在这条不出声，不构成重复。
  # 坑点（2026-10-16）：此处原本传 `End`——那不是 Claude Code 认识的事件名，整条 hook 被静默
  # 丢弃（只在启动告警里提一句），收尾信号从未生效，全靠 2 秒空闲宽限兜底。正解：键名 `Stop`
  # + 第 5 参 `end`。
  if grep -q 'hook.sh end claude' "$CLAUDE_JSON" 2>/dev/null; then
    echo "[i] Claude Stop hook（收尾信号）已存在"
  elif write_hook "$CLAUDE_JSON" "claude" 10 Stop end; then
    echo "✓  Claude Stop hook（收尾信号，不出声）"
  else
    echo "⚠️  需要 jq 或 python3 写入 Claude 配置，请手动添加"
  fi
  write_prompt_hook "$CLAUDE_JSON" 10 claude
fi

# ── PI coding agent 扩展 ──
PI_EXT_DIR="$HOME/.pi/agent/extensions"
PI_EXT_SRC="$SRC/pi/ivox.ts"
if [[ -d "$PI_EXT_DIR" && -f "$PI_EXT_SRC" ]]; then
  # 无条件覆盖：否则仓库里更新了扩展也永远装不上去
  cp "$PI_EXT_SRC" "$PI_EXT_DIR/ivox.ts"
  echo "✓  PI 扩展"
elif [[ -f "$PI_EXT_SRC" ]]; then
  echo "[i] PI 未安装，跳过扩展安装"
fi

# ── 确保 macOS GUI 环境能找到 ~/.local/bin（.zprofile 注入） ──
ZPROFILE="$HOME/.zprofile"
if [[ -f "$ZPROFILE" ]] && grep -q '\.local/bin' "$ZPROFILE" 2>/dev/null; then
  echo "[i] .zprofile 已包含 ~/.local/bin"
elif grep -q 'export PATH' "$ZPROFILE" 2>/dev/null; then
  # 已有 .zprofile 但没包含 ~/.local/bin，追加一行到 export PATH
  sed -i '' 's|export PATH=.*:.*$|\0:$HOME/.local/bin|' "$ZPROFILE" 2>/dev/null || true
  echo "✓  已追加 ~/.local/bin 到现有 .zprofile"
else
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$ZPROFILE"
  echo "✓  已创建 .zprofile，包含 ~/.local/bin"
fi
