import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/**
 * iVox TTS extension for pi coding agent。
 *
 * 只干一件事：**每页搬一次**。一条 assistant message = 一页，
 * 页结束（message_end）时把整页原文交给 `ivox speak`。
 *
 * **播报的唯一入口是 `ivox speak`**（2026-11-02）：本扩展自己拼好命令
 * （来源 pi、音色从配置查、正文整页），自己调它。守护进程照单念，不猜、不管。
 * 不逐字转发、不攒缓冲、不自己切句（切句/清洗/排队/播放都在守护进程那边）。
 *
 * 代价：以前 pi 走流式连接，用户按 Esc 能 `{cancel}` 撤掉这一轮送来的页；
 * 现在没有流，也就撤不回来——已送出的页照念完（要立刻闭嘴用 `ivox skip --all`）。
 */

const IVOX = join(homedir(), ".local", "bin", "ivox");
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
  const hasUI = (ctx: unknown) =>
    (ctx as { hasUI?: boolean } | undefined)?.hasUI !== false;

  /** 把一页交给 `ivox speak`：本端自己拼命令、自己带来源与音色。 */
  function speakPage(page: string) {
    const voice = voiceFor("pi");
    // 查不到音色就不带 --voice（服务端走默认音色）；正文作为独立参数传（不经 shell），不用转义
    const args = ["speak", "--source", "pi"];
    if (voice) args.push("--voice", voice);
    args.push("--", page);
    const child = spawn(IVOX, args, { stdio: "ignore", detached: true });
    // stdio 忽略掉了子进程的报错，spawn 失败会静默无声——播报不出声时毫无线索，
    // 故把失败原因交回 pi（stderr 会进 pi 的输出）。
    child.on("error", (e) => console.error(`[ivox] 派发播报失败: ${String(e)}`));
    child.unref(); // 不等它结束：扩展不该被播报拖住
  }

  // 一页 = 一条 assistant message。message_end 带的是已定稿的完整 message。
  pi.on("message_end", (event: unknown, ctx: unknown) => {
    if (!hasUI(ctx)) return;
    const msg = (event as { message?: { role?: string; content?: Array<{ type: string; text?: string }> } }).message;
    if (msg?.role !== "assistant") return;
    let text = "";
    for (const block of msg.content ?? []) {
      if (block.type === "text" && typeof block.text === "string") text += block.text;
    }
    if (!text.trim()) return;
    speakPage(text);
  });
}
