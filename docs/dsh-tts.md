# DeepSeek Harness 语音播报接入

DSH（DeepSeek Harness）回复时用 iVox 朗读。**默认第二层逐句流式**：模型边生成、iVox 边切句开播，不必等整轮。音色走 `sourceVoices.dsh`，默认**湾湾**。

## 结论：流式优先，整段兜底

```
模型生成中
  └─ agent/assistant-stream  逐 frame：start / chunk(text-delta 真增量) / end
        text-delta 经一条长连接转发：块内裸增量直接 write（不补任何字符），
        仅在文本块切换（content index 变化 / 工具调用后新段）时补一个 \n：
        {type:stream,source:dsh,turn:<id>}\n  → <裸增量>…\n<下一段裸增量>…
        ⚠ 绝不能每个 delta 后都加 \n：服务端把 \n 当段落 flush 边界，逐 token
          补会切成一堆超短块，模型慢吐时上一段播完下一段还没到 → 句间空档卡顿
  └─ Daemon: StreamBuffer 安全边界切句 → cleanText → splitSentences
             → 连续播放管道（边合成边播）
一轮结束
  └─ agent/turn-stopping  发 {end}\n 关流（flush 残尾）
        · 本轮已成功流式 → 结束，不重复播报
        · socket 不可用（守护进程未运行 / 旧版）→ 退回整段：按官方规则
          选最终文本 spawn hook.sh（stdin last_assistant_message）
```

流贯穿整个 agent turn：同 turn 内多个 attempt（工具调用前后多段文本）复用一条连接，仅在段间补换行；`frame.turn` 变化才开新流（**新 turn 排队，不打断旧轮**——队列按轮分桶播全播完）。子代理会话（`subs`）不转发。全程无轮询、无临时文件、无竞态。

> 注：`assistant/message` / `assistant/attempt` 的 `event.data.stream` 是**该 step 的完整紧凑流（累计）**，不是增量，不能直接逐帧转发；真增量只在 `agent/assistant-stream` 的 `chunk` frame（`chunk.chunk = {type:'text-delta', index, text}`，跳过 reasoning/tool-call delta）。

## 为什么不用 DSH 内置的 hooks 桥接

DSH 自带两个「Claude Code / Codex hook 兼容」桥接插件，但它们的 Stop payload 里**没有回复文本**：

| 桥接插件 | Stop payload 的 `last_assistant_message` |
|---|---|
| `@deepseek-ai/dsh-hooks-claude-code` | 字段根本不存在（`stopPayload()` 只给 session_id / transcript_path / cwd / hook_event_name / stop_hook_active） |
| `@deepseek-ai/dsh-hooks-codex` | 写死为 `null` |

所以 `hook.sh` 从 stdin 拿不到文本，只能自己另找来源。曾试过「Stop 触发后回头读本地会话日志」，但：

- 会话日志在 `~/.dsh/sessions/<cwd 编码>/session-<uuid>/session.v4.jsonl.zstd`
- 旧实现按 `.../<uuid>/session.v4.jsonl.zstd` 拼路径（漏了 `session-` 前缀），必然读不到文件，`text` 恒为空、静默 `exit 0`
- 就算路径修对，还要 zstd 解码 + 轮询等刷盘（0.25s × N，最多 2 秒），且有「播到上一轮旧内容」的竞态

因此改为**自制本地 cordis 插件**，在内存里直接拿文本。

## 关键机制

### 1. 可用的扩展点

| 扩展点 | 时机 | 用途 |
|---|---|---|
| `agent/assistant-stream` | attempt 的 start/chunk/end 帧（**逐 token 真增量**） | 流式转发 `text-delta` 到长连接（主路径） |
| `session/event` | 任一 session 日志事件落盘 | 过滤 `assistant/message`（登记候选最终消息）与 `assistant/attempt`（累积兜底文本）；仅 socket 不可用时用 |
| `agent/turn-stopping` | 一轮结束（Stop 的对应点） | 流式发 `{end}` 收尾；未流式成功则按官方规则选最终文本 spawn hook.sh |
| `subagent/start` / `subagent/end` | 子代理起止 | 登记子代理会话，流式与兜底都跳过，避免一次提问念多遍 |
| `session/disposed` | 会话销毁 | 关流并清理缓存/连接 |

**注意**：每个 step 都会落一条 `assistant/message`（包括带工具调用的中间回复）。若在 `assistant/message` 上直接播，会把过程话全念出来。所以必须「缓存 + 整轮结束取最后一条」。

### 2. 选取规则对齐 DSH 官方定义

插件复刻的是 `dsh-subagent` 的 `AssistantOutputFold` / `finalAssistantOutput`（DSH 对「子代理最终输出」的规范选取）：

1. 取**最后一条内容非空**的 `assistant/message`（判据是 `content.length > 0`，不是"有没有文本块"）；
2. 内容为空的消息（`max-tokens` 且无可执行块时才会落一条）**不覆盖**前一条；
3. 若始终没有非空消息，**退回**该会话累积的流式文本（`assistant/message` / `assistant/attempt` 的 `event.data.stream`，按 `dsh-llm` 的 `joinAssistantStreamText` 取 `chunk.type === "text-delta"` 与 `text-chunks`）。

第 1 条的判据看着别扭，但必须照抄：一轮以「只有 tool-call、无文本块」的消息收尾时（`concludesTurn` 类工具），官方语义就是「没有文本输出」——此时**不播**，而不是回放上一步的旁白。

### 3. 插件怎么被加载

`~/.dsh/profiles/desktop/cordis.patch.yml` 里加：

```yaml
- insert:
    - id: ivox-tts
      name: "./plugins/ivox-tts.mjs"
```

- profile 树 = bundle 列表 → `cordis.patch.yml` → `--patch` overlay
- patch 只能改已有条目；**新增插件必须用 `- insert:` 列表**（直接写 `- id:` 会报 `patch: entry not found`）
- 加载器（`cordis-plugin-loader`）对以 `.` 开头的 `name` 走 `new URL(name, ctx.baseUrl)`，而 `baseUrl` 由 `cordis-plugin-include` 设成**配置文件所在目录**（即 profile 目录），所以放本地文件即可
- 因此**不用改 app.asar，也不用 pnpm 安装**

### 4. 插件文件的三条硬约束

| 约束 | 原因 |
|---|---|
| 后缀必须 `.mjs` | profile 的 `package.json` 没有 `"type": "module"`，`.js` 会被当 CJS |
| 只能 import `node:` 内置模块 | profile 的 `node_modules` 是空的，import 不到 dsh 内部包（如 schemastery） |
| 必须导出 `name` 与 `apply(ctx, config)` | cordis 插件契约（`inject` 可选） |

### 5. 匿名 package.json（必读，漏了整台 dsh 都不可用）

`~/.dsh/profiles/desktop/plugins/package.json`：

```json
{ "private": true }
```

**必须有。** 原因：DSH 内置的 `dsh-plugin-package-inventory-deepseek` 每次请求都会枚举所有 active 插件，对相对路径插件向上查找最近的 `package.json` —— 会命中 profile 的 `~/.dsh/profiles/desktop/package.json`，而它**有 `name` 没有 `version`**，清单校验要求两者同时非空，于是请求在 prepare 阶段直接抛错（`REQUEST_EXTENSION`），连 auto-review / 工具审查都一起挂掉。

放一个匿名包（无 `name`）会被当作 loose module 跳过校验。**不要用「给 profile 的 package.json 加 version」来修** —— 那会把 profile 本身当插件包上报。

失败解析不入进程缓存，改完通常下一轮即生效（保险起见可重启 dsh）。

## 安装

脚本（推荐，随 `make install` 走）：

```bash
scripts/install-hooks.sh ~/.config/ivox/hook.sh
```

它会把插件从 `integrations/dsh/` 复制到 `~/.dsh/profiles/desktop/plugins/`（含匿名 `package.json`），并确保 `cordis.patch.yml` 里有 `ivox-tts` 挂载；同时清掉 `~/.dsh/hooks.json` 里失效的 Stop。

手工安装：

```bash
D=~/.dsh/profiles/desktop
mkdir -p "$D/plugins"
cp integrations/dsh/ivox-tts.mjs "$D/plugins/"
cp integrations/dsh/package.json "$D/plugins/"
printf '\n- insert:\n    - id: ivox-tts\n      name: "./plugins/ivox-tts.mjs"\n' >> "$D/cordis.patch.yml"
```

**前提：`hook.sh` 必须是通用版。** 插件把文本写在 `last_assistant_message` 里，而旧的 dsh 分支只认 zstd 那条路、会把这个字段丢掉 —— 这一步漏了，插件就是白喂（插件投递成功、hook 却当空文本静默退出）。

## 验证

```bash
# 1. 挂载与文件是否就位
#    （注意：desktop profile 由 Electron 独占，CLI 跑 dsh --profile desktop --dump-config
#      会被拒绝：error: profile "desktop" is managed exclusively by the Electron application）
grep -A2 ivox-tts ~/.dsh/profiles/desktop/cordis.patch.yml
ls -la ~/.dsh/profiles/desktop/plugins/

# 2. 手工喂一条 payload 测 hook.sh + daemon（会真的出声）
printf '%s' '{"last_assistant_message":"链路测试"}' | bash ~/.config/ivox/hook.sh dsh
tail -5 ~/.config/ivox/daemon.log        # 期望: 请求解析: source=dsh voice=wanwan

# 3. 真实轮结束后的证据（发一条消息，然后看）
grep "请求原始内容: source=dsh" ~/.config/ivox/daemon.log | tail -1
```

## 排障

| 症状 | 检查 |
|---|---|
| 完全没播报 | 插件文件在不在？`cordis.patch.yml` 有 `ivox-tts` 挂载吗？改完重启 dsh 了没？ |
| 每轮请求在 prepare 阶段失败（`REQUEST_EXTENSION`） | `plugins/package.json` 被当成垃圾删了？ |
| 念出过程话 / 播到上一轮内容 | `hook.sh` 是否被改回读 zstd 的老实现？正常实现只从 `last_assistant_message` 取一次 |
| 日志有 `source=dsh` 但没声音 | daemon 在跑吗？`pgrep -fl "ivox serve"`；再查代码签名与音量 |
| 插件加载报错 | `name` 是否以 `./` 开头（相对 profile 目录）？文件后缀是不是 `.mjs`？ |

## 已知限制

- **过程话的取舍**：默认走**第二层逐句流式**（吃 `agent/assistant-stream` 的 `text-delta`），首字延迟低；代价是流式阶段无法判断当前 step 是不是最终回答——带工具调用的中间步骤同样在产出文本，理论上「我先看看 X」这类过程话也会被念出来（实现上只转发 `text-delta`、跳过 reasoning/tool-call 块来压低概率）。若发现过程话被念，先查是不是误收了非 `text-delta` 的文本块。
  *（历史：早期版本粒度是整轮——`agent/turn-stopping` 时才一次性投递，保证「只念答案」但首字延迟≈整轮生成时间。已改为流式。）*
- **一轮以「无文本的 tool-call 消息」收尾时不播**：这是照抄 DSH 官方最终输出规则的结果（见上文「选取规则对齐 DSH 官方定义」）。若希望此时回放上一段文字，需要显式偏离官方语义。
- **过短纯西文不播**：长度 ≤ 5 且不含中文（如 `ok` / `done`）会被跳过。
- **文本走 argv**：`hook.sh` 用 `ivox speak -- "$text"` 传参，受 macOS `ARG_MAX`（1MB）约束。超长回复理论上会失败；要彻底解决得给 `speak` 加 stdin 入参。
- **插件是复制品**：升级 DSH、换 profile 或重建环境后需重跑安装脚本。

## 卸载

```bash
D=~/.dsh/profiles/desktop
rm -rf "$D/plugins"
# 再从 cordis.patch.yml 里删掉 id: ivox-tts 那个 insert 块
```

## 相关文件

| 路径 | 作用 |
|---|---|
| `integrations/dsh/ivox-tts.mjs` | 插件源码（仓库内，安装源） |
| `integrations/dsh/package.json` | 匿名包模板 |
| `~/.dsh/profiles/desktop/plugins/ivox-tts.mjs` | 实际被加载的插件 |
| `~/.dsh/profiles/desktop/plugins/package.json` | 匿名包（清单校验豁免） |
| `~/.dsh/profiles/desktop/cordis.patch.yml` | 挂载点 |
| `~/.config/ivox/hook.sh` | 通用 hook（读 `last_assistant_message`） |
| `~/.config/ivox/config.json` | `sourceVoices.dsh` 决定音色（默认湾湾） |
| `~/.config/ivox/daemon.log` | 链路日志，排障入口 |

## 参考

- [Hook 链路总览](hook-chain.md)
- [架构总览](architecture.md)
- [CHANGELOG](CHANGELOG.md)
