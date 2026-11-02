import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createConnection, type Socket } from "node:net";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/**
 * iVox TTS extension for pi coding agent。
 *
 * 只干一件事：每页搬一次。一条 assistant message = 一页，
 * 页结束（message_end）时把整页原文装进一个长度帧发给守护进程。
 * 页号由守护进程自己数，扩展不给 id。切句/清洗/排队/播放全在守护进程那边。
 *
 * 不逐字转发、不攒缓冲、不兜底重念。守护进程没开就闭嘴。
 *
 * **音色由客户端自己取**（2026-11-02）：协议要求 source 与 voice 都必填，
 * 守护进程不再猜「pi 该用什么音色」。映射表仍是 config.toml 的
 * `[playback.sourceVoices]`（唯一真源），这里自己读它：
 * 先取 `pi` 自己的键，取不到退回 `default` 键；两处都没有 → 不出声。
 */

const SOCKET_PATH = join(homedir(), ".config", "ivox", "ivox.sock");
const CONFIG_PATH = join(homedir(), ".config", "ivox", "config.toml");

/** 从 config.toml 的 [playback.sourceVoices] 里取某个来源的音色 id。 */
export function voiceFor(source: string): string {
  let text = "";
  try {
    text = readFileSync(CONFIG_PATH, "utf8");
  } catch {
    return "";
  }
  const table: Record<string, string> = {};
  let inSection = false;
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (line.startsWith("[") && line.endsWith("]")) {
      inSection = line === "[playback.sourceVoices]";
      continue;
    }
    if (!inSection || !line || line.startsWith("#")) continue;
    const m = /^([A-Za-z0-9_.-]+)\s*=\s*"([^"]*)"/.exec(line);
    if (m) table[m[1]] = m[2];
  }
  return table[source] || table["default"] || "";
}

export default function (pi: ExtensionAPI) {
  let sock: Socket | null = null;
  let turnId = "";
  let muted = false; // 用户中断后，本 run 剩余的页不搬

  const hasUI = (ctx: unknown) =>
    (ctx as { hasUI?: boolean } | undefined)?.hasUI !== false;

  function connect() {
    muted = false;
    turnId =
      Math.floor(Math.random() * 0xffffffff).toString(16).padStart(8, "0") +
      Date.now().toString(16);
    sock?.destroy();
    // 取不到音色 → 干脆不开这条连接：没有音色就没法念（协议要求 voice 必填）。
    const voice = voiceFor("pi");
    if (!voice) return;
    const s = createConnection(SOCKET_PATH);
    s.on("error", () => { sock = null; }); // 守护进程没开：闭嘴，不出声
    // turn 只进日志：不参与排队、不落库（队列是页的 FIFO，先来先进）。
    s.write(`{type:stream,source:pi,voice:${voice},turn:${turnId}}\n`);
    sock = s;
  }

  // 长度帧 L<字节数>\n<正文>：正文可含换行、{end} 等任意字符，守护进程按字节精确切。
  // **一帧 = 一页**（一条 assistant 消息的全文）。
  function send(text: string) {
    if (!sock) return;
    const body = Buffer.from(text, "utf8");
    sock.write(`L${body.length}\n`);
    sock.write(body);
  }

  pi.on("agent_start", (_e: unknown, ctx: unknown) => {
    if (!hasUI(ctx)) return;
    connect();
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
    send(text);
  });

  pi.on("agent_end", (_e: unknown, ctx: unknown) => {
    if (!hasUI(ctx)) return;
    const s = sock;
    sock = null;
    turnId = "";
    s?.end("{end}\n");
  });

  // 用户按 Esc 中断：撤掉这一轮送来的页
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
