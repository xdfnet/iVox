import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createConnection, type Socket } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";

/**
 * iVox TTS extension for pi coding agent。
 *
 * 只干一件事：每页搬一次。一条 assistant message = 一页，页结束（message_end）
 * 时把整页原文发给守护进程，前面带一帧 `{page}` 说明「这是新的一页」。
 * 页号由守护进程自己数，扩展不给 id。切句/清洗/排队/播放全在守护进程那边。
 *
 * 不逐字转发、不攒缓冲、不兜底重念。守护进程没开就闭嘴。
 */

const SOCKET_PATH = join(homedir(), ".config", "ivox", "ivox.sock");

export default function (pi: ExtensionAPI) {
  let sock: Socket | null = null;
  let turnId = "";
  let muted = false; // 用户中断后，本 run 剩余的页不搬

  const hasUI = (ctx: unknown) =>
    (ctx as { hasUI?: boolean } | undefined)?.hasUI !== false;

  function startTurn() {
    turnId =
      Math.floor(Math.random() * 0xffffffff).toString(16).padStart(8, "0") +
      Date.now().toString(16);
    muted = false;
    sock?.destroy();
    const s = createConnection(SOCKET_PATH);
    s.on("error", () => { sock = null; }); // 守护进程没开：闭嘴，不出声
    s.write(`{type:stream,source:pi,turn:${turnId}}\n`);
    sock = s;
  }

  // 长度帧 L<字节数>\n<正文>：正文可含换行、{end} 等任意字符，守护进程按字节精确切
  function send(text: string) {
    if (!sock) return;
    const body = Buffer.from(text, "utf8");
    sock.write(`L${body.length}\n`);
    sock.write(body);
  }

  pi.on("agent_start", (_e: unknown, ctx: unknown) => {
    if (!hasUI(ctx)) return;
    startTurn();
  });

  // 一页 = 一条 assistant message。message_end 带的是已定稿的完整 message。
  pi.on("message_end", (event: unknown, ctx: unknown) => {
    if (!hasUI(ctx) || muted) return;
    const msg = (event as { message?: { role?: string; content?: Array<{ type: string; text?: string }> } }).message;
    if (msg?.role !== "assistant") return;
    let text = "";
    for (const block of msg.content ?? []) {
      if (block.type === "text" && typeof block.text === "string") text += block.text;
    }
    if (!text.trim()) return;
    sock?.write("{page}\n");
    send(text);
  });

  pi.on("agent_end", (_e: unknown, ctx: unknown) => {
    if (!hasUI(ctx)) return;
    const s = sock;
    sock = null;
    turnId = "";
    s?.end("{end}\n");
  });

  // 用户按 Esc 中断：丢弃本轮剩余内容
  pi.on("agent_settled", (event: unknown, ctx: unknown) => {
    if (!hasUI(ctx)) return;
    if ((event as { aborted?: boolean }).aborted !== true) return;
    muted = true;
    const s = sock;
    sock = null;
    turnId = "";
    s?.end("{cancel}\n");
  });
}
