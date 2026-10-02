// iVox TTS bridge for DeepSeek Harness (dsh).
// 每轮回复结束时，按 dsh 官方的「最终输出」规则取出该轮文本，直接交给 ivox hook.sh。
// 取代旧方案「Stop hook -> 回头读 sessions/*.zstd 取文本」：
// 不解 zstd、不猜 session 目录名、不轮询等刷盘、无「播到上一轮」竞态。
// 挂载（profile 的 cordis.patch.yml）：
//   - insert: [{id: ivox-tts, name: "./plugins/ivox-tts.mjs"}]
// 相对路径按 profile 目录解析，故无需改 app.asar，也无需 pnpm 安装。
// 只用 node: 内置模块（profile 的 node_modules 是空的，不能 import dsh 内部包）。
import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";

export const name = "ivox-tts";
export const inject = [];

const HOOK = join(homedir(), ".config", "ivox", "hook.sh");

// 拼出一条 assistant 消息的纯文本（跳过 tool_use / reasoning 等块）
function textOfContent(content) {
if (Array.isArray(content)) {
var out = "";
for (var i = 0; i < content.length; i++) {
var block = content[i] || {};
if (block.type === "text") {
if (typeof block.text === "string") out += block.text;
}
}
return out;
}
return "";
}

function textOf(message) {
return textOfContent((message || {}).content);
}

// 一条 durable 事件里累积的流式文本（dsh-llm 的 joinAssistantStreamText 同款取法）。
// 只在没有任何非空 assistant 消息时兜底用。
function streamTextOf(stream) {
if (!Array.isArray(stream)) return "";
var out = "";
for (var i = 0; i < stream.length; i++) {
var record = stream[i] || {};
if (record.type === "text-chunks" && Array.isArray(record.texts)) {
out += record.texts.join("");
} else if (record.type === "chunk" && record.chunk && record.chunk.type === "text-delta") {
if (typeof record.chunk.text === "string") out += record.chunk.text;
}
}
return out;
}

export function apply(ctx, config) {
config = config || {};
var hookScript = config.hookScript || HOOK;
var source = config.source || "dsh";
// 选取规则复刻 dsh-subagent 的 AssistantOutputFold（官方「最终输出」定义）：
// 取最后一条**内容非空**的 assistant 消息；内容为空的消息（max-tokens 且无可执行块）
// 不覆盖它。若始终没有非空消息，则退回流式累积文本。
var lastMessage = new Map(); // session.id -> content[]（最后一条非空 assistant 消息）
var streamed = new Map();    // session.id -> 流式累积文本（兜底）
// 子代理会话 id：不播报，避免一次提问念多遍
var subs = new Set();

function childOf(info) {
try {
var agents = ctx.get("agents");
if (agents && info) return agents.get(info.id);
} catch (e) {}
return undefined;
}

ctx.on("subagent/start", function (info) {
var child = childOf(info);
if (child && child.session) subs.add(child.session.id);
});

ctx.on("subagent/end", function (info) {
var child = childOf(info);
if (child && child.session) subs.delete(child.session.id);
});

// 每个 step 都会落一条 assistant/message（含带工具调用的中间回复），
// 所以只缓存，整轮结束时取最后一条。
ctx.on("session/event", function (session, event) {
if (!event) return;
if (event.type !== "assistant/message" && event.type !== "assistant/attempt") return;
var data = event.data || {};
if (event.type === "assistant/message") {
var content = (data.message || {}).content;
if (Array.isArray(content) && content.length > 0) lastMessage.set(session.id, content);
}
var piece = streamTextOf(data.stream);
if (piece.length > 0) {
var acc = streamed.get(session.id);
streamed.set(session.id, acc === undefined ? piece : acc + piece);
}
});

ctx.on("agent/turn-stopping", function (args) {
var session = args && args.agent && args.agent.session;
if (!session) return;
var content = lastMessage.get(session.id);
var text = content !== undefined ? textOfContent(content) : (streamed.get(session.id) || "");
lastMessage.delete(session.id);
streamed.delete(session.id);
if (text.trim().length === 0) return;
if (subs.has(session.id)) return;
deliver(session, text);
});

ctx.on("session/disposed", function (session) {
lastMessage.delete(session.id);
streamed.delete(session.id);
subs.delete(session.id);
});

function deliver(session, text) {
var header = session.header || {};
var payload = JSON.stringify({
session_id: session.id,
transcript_path: "",
cwd: header.cwd || process.cwd(),
hook_event_name: "Stop",
stop_hook_active: false,
last_assistant_message: text,
source: source
});
try {
var child = spawn("bash", [hookScript, source], {
detached: true,
stdio: ["pipe", "ignore", "ignore"]
});
child.on("error", function () {});
child.stdin.on("error", function () {});
child.stdin.end(payload);
child.unref();
} catch (e) {
if (ctx.logger) ctx.logger.warn("ivox-tts: cannot spawn hook.sh: " + String(e));
}
}
}
