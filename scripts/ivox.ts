import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFile } from "node:child_process";
import { createConnection, type Socket } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";

/**
 * iVox TTS extension for pi coding agent — 第二层逐句流式。
 *
 * 模型边生成边把 text_delta 原文帧转发给守护进程（一 turn 一条长连接），
 * 服务端在安全边界（句末/段落、代码围栏配平）切句清洗并立刻开播，
 * 不必等整轮 agent_settled。切句/清洗真源只在服务端一份，这里绝不切句。
 *
 * agent_settled 仅作兜底：老版本无 message_update，或 socket 连不上时，
 * 退回整段 `ivox speak`；正常流式过的轮次不再重复播报。
 */

const SOCKET_PATH = join(homedir(), ".config", "ivox", "ivox.sock");

export default function (pi: ExtensionAPI) {
  let sock: Socket | null = null;
  let turnId = "";
  let streamed = false;   // 本轮是否已成功转发过流式增量
  let socketDead = false; // 连接是否失败过（失败则本轮退回整段兜底）
  let lastContentIndex = -1;

  const randomTurn = () =>
    Math.floor(Math.random() * 0xffffffff).toString(16).padStart(8, "0") +
    Date.now().toString(16);

  function startTurn() {
    turnId = randomTurn();
    streamed = false;
    socketDead = false;
    lastContentIndex = -1;
    closeSock();
    const s = createConnection(SOCKET_PATH);
    s.on("error", () => {
      // 守护进程未运行/路径不存在：静默，settled 时退回整段 speak
      socketDead = true;
    });
    s.write(`{type:stream,source:pi,turn:${turnId}}\n`);
    sock = s;
  }

  function closeSock() {
    if (sock) {
      sock.destroy();
      sock = null;
    }
  }

  function sendFrame(text: string) {
    if (sock && !socketDead && !sock.destroyed) sock.write(text + "\n");
  }

  // 有交互 UI（tui/rpc）才播报；print/json/后台脚本不打扰
  const hasUI = (ctx: unknown) =>
    (ctx as { hasUI?: boolean } | undefined)?.hasUI !== false;

  pi.on("turn_start", (_e: unknown, ctx: unknown) => {
    if (!hasUI(ctx)) return;
    startTurn();
  });

  // 用户发新消息：立即打断上一轮（即使 assistant turn 尚未/未正常开始）
  pi.on("message_start", (event: unknown, ctx: unknown) => {
    if (!hasUI(ctx)) return;
    if ((event as { message?: { role?: string } }).message?.role === "user") {
      if (sock && !socketDead) sock.write("{cancel}\n");
      closeSock();
      stopPlayback();
      startTurn();
    }
  });

  // 发送全局停止哨兵（打断当前在播，barge-in）。用 socket 短连。
  function stopPlayback() {
    const s = createConnection(SOCKET_PATH);
    s.on("error", () => {});
    s.write("__IVOX_STOP_PLAYBACK__");
    s.end();
  }

  pi.on("message_update", (event: unknown, ctx: unknown) => {
    if (!hasUI(ctx)) return;
    const ev = event as { assistantMessageEvent?: { type?: string; contentIndex?: number; delta?: string } };
    const d = ev.assistantMessageEvent;
    if (!d || d.type !== "text_delta" || typeof d.delta !== "string") return; // 跳过 thinking/toolcall
    if (!turnId) startTurn(); // 某些模式可能无 turn_start
    // 工具调用前后是不同文本块：块间补换行，避免两句话粘连
    if (d.contentIndex !== undefined && d.contentIndex !== lastContentIndex) {
      if (lastContentIndex !== -1) sendFrame("\n");
      lastContentIndex = d.contentIndex;
    }
    sendFrame(d.delta);
    streamed = true;
  });

  pi.on("message_end", (_e: unknown, ctx: unknown) => {
    if (!hasUI(ctx)) return;
    if (sock && !socketDead) sock.write("{end}\n");
    closeSock();
  });

  pi.on("agent_settled", async (event: unknown, ctx: unknown) => {
    if (!hasUI(ctx)) return;
    const aborted = (event as { aborted?: boolean }).aborted === true;
    if (aborted) {
      // 用户中断：通知服务端丢弃本轮未播内容
      if (sock && !socketDead) sock.write("{cancel}\n");
      closeSock();
      return
    }
    if (streamed && !socketDead) { closeSock(); return; } // 已流式播报，不重复

    // 兜底：取最后一条 assistant 文本消息整段播报
    closeSock();
    const entries = (ctx as { sessionManager: { getEntries(): Array<{
      type: string;
      message: { role: string; content?: Array<{ type: string; text?: string }> };
    }> } }).sessionManager.getEntries();
    let lastText = "";
    for (let i = entries.length - 1; i >= 0; i--) {
      const entry = entries[i];
      if (entry.type !== "message") continue;
      const msg = entry.message;
      if (msg.role !== "assistant") continue;
      let text = "";
      for (const block of msg.content ?? []) {
        if (block.type === "text" && typeof block.text === "string") text += block.text;
      }
      if (text.trim()) { lastText = text; break; }
    }
    if (!lastText) return;
    if (lastText.length <= 5 && !/[一-鿿]/.test(lastText)) return;

    execFile("ivox", ["speak", "--source", "pi", "--", lastText], {
      cwd: homedir(),
      env: { ...process.env, IVOX_SKIP: "" },
      windowsHide: true,
    });
  });
}
