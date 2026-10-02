// iVox 常驻 Claude Agent 桥（与上游解耦，单用户）
// 协议：stdin/stdout 逐行 NDJSON。
//   请求: {id, text, cwd}
//   事件: {id, type:"done"|"error", text?, session_id?, message?}
// 全局只持有一个不退出的 agent；底层 claude 进程常驻，后台任务可跨消息存活；
// 闲置 idleMs 自动回收，下条消息重建并 resume。

import { query } from "@anthropic-ai/claude-agent-sdk";
import { createInterface } from "node:readline";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const bridgeDir = dirname(fileURLToPath(import.meta.url));
mkdirSync(bridgeDir, { recursive: true });

const idleMs = Number(process.env.IVOX_BRIDGE_IDLE_MS ?? 30 * 60_000);
const stateFile = join(bridgeDir, "state.json");

// 永不关闭的异步消息队列：所有轮次的 user 消息都 push 进同一个 prompt 流
function makeQueue() {
  const items = [];
  const resolvers = [];
  return {
    push(x) {
      if (resolvers.length) resolvers.shift()({ value: x, done: false });
      else items.push(x);
    },
    end() {
      while (resolvers.length) resolvers.shift()({ value: undefined, done: true });
    },
    [Symbol.asyncIterator]() {
      return {
        next: () =>
          new Promise((resolve) => {
            if (items.length) resolve({ value: items.shift(), done: false });
            else resolvers.push(resolve);
          }),
      };
    },
  };
}

function emit(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

function loadState() {
  try {
    return JSON.parse(readFileSync(stateFile, "utf8"));
  } catch {
    return {};
  }
}

function saveState(patch) {
  writeFileSync(stateFile, JSON.stringify({ ...loadState(), ...patch }));
}

// 唯一 agent
let stream = null;
const inbox = makeQueue();
const waiters = [];
let idleTimer = null;

function armIdle() {
  clearTimeout(idleTimer);
  idleTimer = setTimeout(() => {
    stream?.close();
    stream = null;
  }, idleMs);
}

// 常驻消费循环：永不提前退出，result 时分发给当前等待者
async function pump() {
  try {
    for await (const msg of stream) {
      if (msg.type !== "result") continue;
      armIdle();
      if (msg.session_id) saveState({ session_id: msg.session_id });
      waiters.shift()?.(msg);
    }
  } catch (err) {
    const fail = { is_error: true, result: String(err?.message ?? err) };
    while (waiters.length) waiters.shift()(fail);
  }
}

// 重置会话：关闭当前 agent、清 session_id，下条消息开新会话
function resetSession() {
  clearTimeout(idleTimer);
  stream?.close();
  stream = null;
  saveState({ session_id: null });
  while (waiters.length) {
    waiters.shift()({ is_error: true, result: "会话已被 /new 重置" });
  }
}

function handle(req) {
  const { id, text, cwd } = req;

  // /new：开新会话，不发给模型
  if (text.trim() === "/new") {
    resetSession();
    emit({ id, type: "done", text: "已开启新会话" });
    return;
  }

  armIdle();

  try {
    if (!stream) {
      // 首轮：query 的 prompt 是长开队列，进程据此保持多轮、stdin 不关闭
      mkdirSync(cwd, { recursive: true });
      const state = loadState();
      stream = query({
        prompt: inbox,
        options: {
          cwd,
          env: { ...process.env },
          model: process.env.ANTHROPIC_MODEL,
          permissionMode: "bypassPermissions",
          stderrToFile: join(bridgeDir, "stderr.log"),
          ...(state.session_id ? { resume: state.session_id } : {}),
        },
      });
      pump();
    }

    // 每轮（含首轮）都把消息 push 进同一队列，query 自然读到
    inbox.push({ type: "user", message: { role: "user", content: text } });
  } catch (err) {
    emit({ id, type: "error", message: String(err?.message ?? err) });
    return;
  }

  // 等本轮 result
  new Promise((resolve) => waiters.push(resolve)).then((msg) => {
    if (msg.is_error || msg.subtype === "error_during_execution") {
      emit({ id, type: "error", message: msg.result ?? "agent 执行出错" });
    } else {
      emit({ id, type: "done", text: msg.result ?? "", session_id: msg.session_id });
    }
  });
}

const rl = createInterface({ input: process.stdin });
rl.on("line", (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;
  try {
    handle(JSON.parse(trimmed));
  } catch (err) {
    emit({ type: "error", message: "坏请求: " + String(err?.message ?? err) });
  }
});

async function shutdown() {
  clearTimeout(idleTimer);
  inbox.end();
  stream?.close();
  process.exit(0);
}
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
rl.on("close", shutdown);

// 防止未捕获的流错误拖垮进程
process.on("uncaughtException", (err) => emit({ type: "error", message: String(err) }));
