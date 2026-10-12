// iVox TTS bridge for DeepSeek Harness (dsh).
// 第二层逐句流式：订阅 agent/assistant-stream 的 text-delta 增量，一 turn 一条
// 长连接按 \n 分帧转发给守护进程，服务端在安全边界切句清洗并立刻开播，不必等
// 整轮结束。切句/清洗真源只在服务端一份，这里绝不切句。
// 兜底：socket 连不上（守护进程未运行 / 旧版无流式协议）时，退回 turn-stopping
// 取整轮最终文本 spawn hook.sh，与旧行为一致。
// 挂载（profile 的 cordis.patch.yml）：
//   - insert: [{id: ivox-tts, name: "./plugins/ivox-tts.mjs"}]
// 相对路径按 profile 目录解析，无需改 app.asar，也无需 pnpm。
// 只用 node: 内置模块（profile 的 node_modules 是空的）。
import { spawn } from "node:child_process";
import { createConnection } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";

export const name = "ivox-tts";
export const inject = [];

const HOOK = join(homedir(), ".config", "ivox", "hook.sh");
const SOCKET = join(homedir(), ".config", "ivox", "ivox.sock");

// 数据帧用自描述长度帧 `L<字节数>\n<原文>`：正文可含 \n/{end} 等任意字符，
// 服务端按字节精确切，杜绝正文恰好为 `{end}` 被误判成控制帧。
function sendData(sock, text) {
var body = Buffer.from(text, "utf8");
sock.write("L" + body.length + "\n");
sock.write(body);
}

// 拼出一条 assistant 消息的纯文本（跳过 tool_use / reasoning 等块）——兜底路径用
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
// 只在兜底路径、且没有任何非空 assistant 消息时用。
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

const randomTurn = () =>
Math.floor(Math.random() * 0xffffffff).toString(16).padStart(8, "0") +
Date.now().toString(16);

export function apply(ctx, config) {
config = config || {};
var hookScript = config.hookScript || HOOK;
var source = config.source || "dsh";
// 兜底路径：最后一条非空 assistant 消息 / 流式累积文本
var lastMessage = new Map(); // session.id -> content[]
var streamed = new Map();    // session.id -> 流式累积文本
// 流式连接：session.id -> 连接状态
var conns = new Map();
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

// ── 第二层流式：agent/assistant-stream 逐 chunk 增量 ──
ctx.on("agent/assistant-stream", function (args) {
var agent = args && args.agent;
var frame = args && args.frame;
var sid = agent && agent.session && agent.session.id;
if (!sid || !frame || subs.has(sid)) return;

if (frame.type === "start") {
var st0 = conns.get(sid);
if (!st0 || st0.turnNo !== frame.turn) {
// 新 turn：重开一条流（自带打断旧轮语义）；同 turn 的后续 attempt（工具调用）
// 复用连接，仅在两段文本之间补换行。
openStream(sid, frame.turn);
} else {
st0.pendingNL = true;   // 同 turn 新 attempt：工具调用后的下一段文本
}
return;
}

if (frame.type !== "chunk") return;
var ch = frame.chunk;
if (!ch || ch.type !== "text-delta" || typeof ch.text !== "string") return; // 跳过 reasoning/tool-call

var state = conns.get(sid);
if (!state) state = openStream(sid, undefined); // 无 start 的兜底开流
if (state.socketDead) return;

// 仅在文本块切换（工具调用前后 / content index 变化）时补一个换行作为段落边界。
// 同一 text block 内的增量裸转发、绝不补换行——服务端把 \n 当 flush 边界，逐
// token 补会切成一堆超短块，且模型慢吐时上一段播完下一段还没到，句间空档=卡顿。
if (state.pendingNL || (typeof ch.index === "number" && ch.index !== state.lastIndex)) {
sendData(state.sock, "\n");
state.lastIndex = ch.index;
}
state.pendingNL = false;
sendData(state.sock, ch.text);
state.streamed = true;
});

function openStream(sid, turnNo) {
closeStream(sid, false);
var sock = createConnection(SOCKET);
var state = {
sock: sock,
turnNo: turnNo,
turnId: randomTurn(),
socketDead: false,
streamed: false,
lastIndex: -1,
pendingNL: false
};
sock.on("error", function () { state.socketDead = true; });
// node net 会在真正建连前缓冲写入，无需等 connect 事件，避免建连期 chunk 被丢
sock.write("{type:stream,source:" + source + ",turn:" + state.turnId + "}\n");
conns.set(sid, state);
return state;
}

function closeStream(sid, sendEnd) {
var st = conns.get(sid);
if (!st) return undefined;
if (sendEnd && !st.socketDead) {
// 优雅半关：end 等内核把 {end} 发完再 FIN，destroy 强杀可能随 RST 丢尾帧。
try { st.sock.end("{end}\n"); } catch (e) { try { st.sock.destroy(); } catch (e2) {} }
} else {
try { st.sock.destroy(); } catch (e) {}
}
conns.delete(sid);
return st;
}

// 每个 step 落一条 assistant/message（含带工具调用的中间回复），只缓存供兜底取最终文本
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
var sid = session.id;

var st = closeStream(sid, true);   // 流式收尾：flush 残尾并关连接
if (subs.has(sid)) { cleanup(sid); return; }

// 流式已成功投递 → 不走整段兜底，避免重复播报
if (st && st.streamed && !st.socketDead) { cleanup(sid); return; }

// 兜底：取最后一条非空 assistant 文本（无则流式累积）整段投 hook.sh
var content = lastMessage.get(sid);
var text = content !== undefined ? textOfContent(content) : (streamed.get(sid) || "");
cleanup(sid);
if (text.trim().length === 0) return;
deliver(session, text);
});

function cleanup(sid) {
lastMessage.delete(sid);
streamed.delete(sid);
}

ctx.on("session/disposed", function (session) {
closeStream(session.id, false);
cleanup(session.id);
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
