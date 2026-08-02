# Hook → TTS 播报泄漏：后台进程文本进入播报

> 2026-08-03 记录

## 现象

用户听到 iVox 播报的内容**不只是屏幕上看到的回复**——偶尔会听到一段屏幕上没有的文本，例如：

```
source=claude raw=Both NEW-0 and NEW-1 are near-identical renderings of the same rule
(auditing a Stop-hook → TTS pipeline for thinking leakage)…
```

特征是英文、JSON 结构、规则整合/学习决策类内容，来自 **claude-smart（reflexio）后台学习系统**。

## 根因

`last_assistant_message` **不保证是"用户屏幕上看到的那条回复"**。它是"最近一次 Stop 会话的最后一条 assistant 文本"。当**后台/非交互式 CLI 进程**退出时，同样触发全局 Stop hook：

- 后台 agent、学习/规则提取系统（如 claude-smart reflexio）
- 子进程、自动化会话

这些进程的内部 assistant 文本会被当成"最后一条回复"播报，而它们在 UI 上不可见 → 用户"听见的不只是看见的"。

> 注意：这不是 thinking 块泄漏。Claude Code 组装 `last_assistant_message` 时已剥离 thinking 块；泄漏的是**屏幕上未渲染的 assistant 文本**。

## 四条 TTS 路径全量核查

| source= | 触发方 | 文本来源 | 是否安全 |
|---------|--------|----------|:---:|
| `claude` / `codex` | Stop hook（`~/.config/ivox/hook.sh`） | `last_assistant_message` | ⚠️ 有后台泄漏风险，见下文修复 |
| `samantha` | Samantha 应用 | `claude -p` JSON 的 `result` 字段（跳过非 result 消息） | ✅ 安全 |
| `iagent` | iAgent 独立进程 | 未知（源码未定位） | ⚠️ 待查 |
| `test` | 测试脚本 | 硬编码文本 | ✅ 安全 |

## 解决方案

reflexio 给它的 claude 子进程设置了官方内部标记（`claude_code_provider.py`）：

```python
env["CLAUDE_SMART_INTERNAL"] = "1"
```

其注释明确：*"so any hooks it fires can detect that this is a reflexio-internal invocation and skip publishing"* —— **hook 侧应识别此标签并跳过**。iVox 之前只认 `IVOX_SKIP`，未认领该标签，导致泄漏。

修复：`hook.sh` 增加对该标签的检查（源码版 + 部署版同步）：

```bash
# 手动静音（IVOX_SKIP=1，如 Samantha 内部调用）或 reflexio 后台学习调用（CLAUDE_SMART_INTERNAL=1）→ 不播报
[[ "${IVOX_SKIP:-}" == "1" ]] && exit 0
[[ "${CLAUDE_SMART_INTERNAL:-}" == "1" ]] && exit 0
```

涉及文件：
- `/Users/admin/iCode/iVox/Sources/iVox/Resources/hook.sh`（源码）
- `/Users/admin/.config/ivox/hook.sh`（部署副本，**必须同步**）

## 验证

模拟两种场景（用假 `ivox` 记录调用）：

```bash
PAYLOAD='{"last_assistant_message":"测试","hook_event_name":"Stop"}'
# 场景A：reflexio 后台调用 → 应静音
echo "$PAYLOAD" | CLAUDE_SMART_INTERNAL=1 bash ~/.config/ivox/hook.sh claude   # ivox 不被调用 ✅
# 场景B：正常前台 → 应播报
echo "$PAYLOAD" | bash ~/.config/ivox/hook.sh claude                            # ivox 被调用 ✅
```

## 排查方法论（可复用）

1. **日志对账**：`~/.config/ivox/daemon.log` 里 `source=` 分布枚举全部播报路径，`raw=` 是逐字 payload
2. **逐条比对**：每条 `raw` payload 与用户可见回复比对，对不上的即后台泄漏
3. **定位来源**：搜 `~/.claude/projects/<项目>/` 的 transcript 找泄漏文本特征词；`ps aux | grep -i claude` 找继承 hook 的子进程
4. **找官方开关**：后台系统常自带"内部调用"标记（如 reflexio 的 `CLAUDE_SMART_INTERNAL`），优先认领它，而非内容特征过滤

## 参考

- [Hook 链路](hook-chain.md)
- reflexio: `node_modules/claude-smart/plugin/vendor/reflexio/reflexio/server/llm/providers/claude_code_provider.py`
- 调试日志: `~/.config/ivox/daemon.log`
