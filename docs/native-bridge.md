# 调研：去 Node 桥的原生 Swift 方案

状态：**已实施于 v3.4.0（2026-10-03）**。本文所有结论均来自对 `claude` 2.1.283 的裸进程探针，而非仅凭 SDK 源码推断。

---

## 1. 背景与动机

v3.3.0 用官方 `@anthropic-ai/claude-agent-sdk` 起常驻 node sidecar，实现了"后台任务跨微信消息存活"。功能达标，部署代价却重：

```
~/.config/ivox/bridge/        278 MB
  node_modules/               278 MB   ← 几乎全部体积
  bridge.messenger.mjs        8 KB     ← 实际逻辑
  state.json / package.json   可忽略
```

- 为 8 KB 转发脚本背整套 TS 依赖树（278 MB），并要求用户额外装 Node.js 18+。
- 多一跳：Swift → node → claude。

**关键事实**：Agent SDK 不做推理，它只做两件事——spawn 原生 `claude` 二进制、通过 stdio 交换 NDJSON。Node 不是能力本身，只是官方目前只给 TS/Python 封装。Swift 可直连。

环境基线：

- `claude` 路径 `/Users/admin/.local/bin/claude` → 软链 `~/.local/share/claude/versions/2.1.283`，版本 **2.1.283 (Claude Code)**。
- SDK 既可用系统 `claude`，也可用包内自带二进制（`@anthropic-ai/claude-agent-sdk-darwin-arm64`）；本机走系统 CLI。

---

## 2. 通信协议（实测确证）

### 2.1 帧与格式

- stdin / stdout 均为 **NDJSON**：一行一个 JSON 对象，UTF-8，无额外分隔符。
- 启动固定四件套：

```
--input-format stream-json
--output-format stream-json
--verbose                 # print 模式下 stream-json 强制要求 verbose，否则报错退出
--dangerously-skip-permissions   # 最大权限（见 2.4）
```

### 2.2 stdin 消息：必须外包一层（最重要的坑）

发给 claude 的 user 消息**不是**裸 `{role,content}`，而要包一层 `type` + `message`：

```json
{"type":"user","message":{"role":"user","content":"文本"}}
```

实测对照：

| 发法 | 结果 |
|---|---|
| `{"role":"user","content":"…"}` | **静默忽略**，只回 SessionStart hook，无 result |
| `{"role":"user","content":[{"type":"text",…}]}` | 配合 print 缺 verbose 时直接 exit 1 |
| `{"type":"user","message":{"role":"user","content":"…"}}` | ✅ 正常处理，产出 result |

> 这正是 v3.3.0 桥代码里 `inbox.push({type:"user", message:{role,content}})` 的由来——SDK 已替我们包好。Swift 原生实现必须自己包这层。

`content` 传**字符串**即可（实测有效）；需要图片等富内容时才用 block 数组。

### 2.3 stdout 消息流

一次对话实测产出的消息序列：

```
system  subtype=hook_started        SessionStart hook
system  subtype=hook_response
system  subtype=init                ← 含 session_id，初始化完成
system  subtype=thinking_tokens …   （思考记账，可忽略）
assistant                            ← 助手消息块
result  subtype=success             ← 一轮结束（关键字段见下）
```

消息 `type` 清单（据 SDK 类型定义 + 实测）：

- `system`：`subtype` 有 `init`、`hook_started`、`hook_response`、`thinking_tokens`、`commands_changed`、`post_turn_summary`、`session_state_changed`、`compact_boundary` 等。
- `assistant`：含标准 Anthropic message，`message.content` 为 text / thinking / tool_use 等 block。
- `result`：一轮收尾。
- 其余可忽略：`user`、`stream_event`、`partial_assistant`、`tool_progress`、`hook_progress`、`keep_alive`、`control_*`。

`result` 关键字段：

```jsonc
{
  "type": "result",
  "subtype": "success",        // 成功；错误时另有标记
  "result": "在的",             // 最终文本（第一版只取它）
  "session_id": "fb2c376c-…",  // UUID
  "num_turns": 1,
  "is_error": false,
  "duration_ms": …, "total_cost_usd": …
}
```

### 2.4 权限模式

实测 **`--dangerously-skip-permissions` 单个 flag 即最大权限**：文件读写、shell、联网、删除全自动，无任何确认打断。这就是当前桥 `bypassPermissions` 的等价 CLI 表达，Swift 直接用该 flag，无需 SDK 那套 `--permission-mode bypassPermissions` + `--allow-dangerously-skip-permissions` 组合。

> 安全前提：微信侧已单用户精确白名单（只认飞哥本人），消息才会驱动这些操作。

### 2.5 会话与 resume

- `session_id` 为**标准 UUID**（如 `fb2c376c-4892-41ed-afc3-f186233bccfb`），无 `cse_` 前缀。
- **常驻多轮**：进程启动后 stdin 保持长开，连续写多条 user 消息即多轮对话；不在轮间关闭 stdin。
- **跨进程恢复**：启动加 `--resume <uuid>`，全新进程可载入该会话全部历史。

---

## 3. 探针实验记录（可复现）

探针目录 `/tmp/probe`。

**实验 1 — 单轮**（print 模式）：

```bash
printf '%s\n' '{"type":"user","message":{"role":"user","content":"只回复两个字：在的"}}' | \
claude --print --input-format stream-json --output-format stream-json \
  --verbose --dangerously-skip-permissions
# → result success "在的"
```

**实验 2 — 多轮常驻**（FIFO 保持 stdin）：同一进程依次发「记住数字 7291」「数字是多少」，结果：

```
INIT   session= fb2c376c-…
RESULT success '好'      fb2c376c-…
RESULT success '7291'    fb2c376c-…   ← 同进程、同 session、记忆保留
```

**实验 3 — resume 跨进程**：实验 2 进程退出后，全新进程带 `--resume fb2c376c-…` 问数字：

```
RESUME RESULT success '7291' fb2c376c-…   ← 历史随 resume 恢复
```

一个观察：探针环境里默认 model 出现 `[claude-code:unrecognized_model]`（env 残留 `ark-code-latest`）警告，但不影响结果。Swift 实现需显式传正确 `--model`，避免依赖 env 残留。

---

## 4. 目标架构

```
Daemon (actor)
  └─ ClaudeAskService（Swift，重写）：Process 直连 claude
        启动  claude --input-format stream-json --output-format stream-json
                   --verbose --dangerously-skip-permissions
                   [--model <m>] [--resume <sid>]   # cwd 用进程 currentDirectoryURL
        stdin  逐行写 {"type":"user","message":{role,content}}
        stdout 逐行读，忽略 system/assistant，取 result.result / session_id
        · 单常驻进程，stdin 长开
        · session_id 落盘，重启用 --resume
        · /new：关进程 + 清 session_id，下次裸启
        · 闲置回收 + cleanup 信号清理，无孤儿 claude
```

删除：node sidecar、`bridge.messenger.mjs`、`install-bridge-sdk.sh`、`~/.config/ivox/bridge/`（278 MB，用 trash 挪走）、Node.js 依赖。

---

## 5. 实施清单

1. **Swift 进程层重写** [ClaudeAskService.swift](../Sources/iVox/Network/ClaudeAskService.swift) → 验证：单轮问答文本与现桥一致。
   - 定位 claude：候选 `~/.local/bin/claude`、`which claude`。
   - 参数 §2.1；`currentDirectoryURL` 设 `~/.config/ivox/wechat/workspace`。
   - env 显式传 `--model`（不依赖残留）；保留现有 API/网关 env。
2. **NDJSON 行缓冲编解码**（复用现有 readabilityHandler 切行模式）→ 验证：result 收尾、错误分支、乱行不崩。
3. **stdin 写消息**：统一包 `{type:"user",message:{role:"user",content}}` → 验证：裸消息不发、包层正确。
4. **多轮常驻**：stdin 长开、连续 ask → 验证：同 session_id、上下文连续。
5. **resume + /new**：session_id 落盘/清空 → 验证：重启恢复历史；/new 后裸启新 session。
6. **生命周期**：cleanup 关 stdin → 等退出（复用现 60×50ms 等待）→ terminate 兜底 → 验证：无孤儿 claude / 工具子进程。
7. **部署与文档**：Makefile 去 `install-bridge-sdk.sh`；README 删 Node 18+；CHANGELOG 记录；旧 bridge 目录 trash 挪走。

## 6. 验收标准（沿用并强化 v3.3.0）

- 真机两条：第一条「执行 `sleep 300 &` 告诉我 pid」，第二条「`ps -p <pid>` 还在吗」→ 答"还在"，且两轮 session_id 一致。
- 守护进程重启后再发消息 → `--resume` 恢复上下文。
- `/new` 后 → session_id 变更、上下文从零。
- SIGTERM 守护进程 → claude 同步退出，`pgrep -fl claude` 无残留子进程。
- 全新安装占用：bridge 相关 **278 MB → 0**，且不要求 Node。

## 7. 权衡

- **收益**：省 278 MB、去 Node 依赖、链路少一跳、故障面更小。
- **成本**：自维护 stream-json 协议，官方升级需跟进。缓解：协议面收到最小（只发包层 user、只取 result 文本 + session_id），不碰 hook/control/权限回调等高级能力。
- **能力边界**：纯 CLI flag 无法实现 SDK 的 `canUseTool` 动态权限回调；本场景用最大权限 flag，不需要它。
- **结论**：协议三大核心（包层输入、常驻多轮、resume）已全部实测通过，**建议立项执行**。

## 8. 备选方案（次优，不采用）

- **不常驻 + 任务外置**：agent 用 `nohup`/`launchd submit` 把长任务交出、日志落盘、下轮读盘。绕开常驻，但交互弱、需改 agent 行为。
- **保留 node 桥**：零迁移成本，但 278 MB 与 Node 依赖长期存在，违背"小而稳"。
