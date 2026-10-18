import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFile } from "node:child_process";
import { createConnection, type Socket } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";

/**
 * iVox TTS extension for pi coding agent — 第二层逐句流式。
 *
 * 模型边生成边把 text_delta 原文帧转发给守护进程（**一次输入一条长连接**，
 * 跨该次输入里的全部 turn，见 agent_start/agent_end 那段注释），
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
  let muted = false;      // 本轮被手动中断后不再续念，下一轮用户发言/turn_start 解除
  let graceful = false;   // 本轮是否由我们主动 end 半关；false 却收到 close = 异常掉线

  const randomTurn = () =>
    Math.floor(Math.random() * 0xffffffff).toString(16).padStart(8, "0") +
    Date.now().toString(16);

  function startTurn() {
    turnId = randomTurn();
    streamed = false;
    socketDead = false;
    muted = false;
    graceful = false;
    lastContentIndex = -1;
    closeSock();
    const s = createConnection(SOCKET_PATH);
    s.on("error", () => {
      // 守护进程未运行/路径不存在：静默，settled 时退回整段 speak
      socketDead = true;
    });
    s.on("close", () => {
      // 只认当前连接：旧轮残留连接的 close（startTurn 里 closeSock 销毁）在此刻
      // sock 已指向新连接，必须忽略，否则会把新轮误判成掉线。
      if (sock !== s) return;
      sock = null;
      // 非主动 end 却关闭 = 中途静默掉线（守护进程重启/FIN）：标记失活，
      // 让 settled 兜底整段重念，否则 streamed=true 会误判已播报、后半段丢失。
      if (!graceful) socketDead = true;
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

  // 本轮收尾：flush 残尾并优雅半关（end 等内核把尾帧/{end} 发完再 FIN，
  // 不能 destroy——强杀会随 RST 丢掉最后一两个字）。
  function endTurn() {
    const s = sock;
    sock = null;
    turnId = "";
    if (s && !socketDead && !s.destroyed) {
      graceful = true;
      s.end("{end}\n");
    }
  }

  function cancelTurn() {
    muted = true;
    const s = sock;
    sock = null;
    turnId = "";
    if (s && !socketDead && !s.destroyed) {
      graceful = true;   // 主动中断不算掉线，无需 settled 兜底
      s.end("{cancel}\n");
    }
  }

  // 翻页信号：一条 assistant message 开始 = 翻一页（与 Claude 那边「一页 = 一个
  // MessageDisplay」同构）。服务端按 `{page}` 帧自己数页号——它只承担"这一页说完了、
  // 下面是新的一页"，页号本身由服务端生成。Ctrl+2「读下一页」按页翻。
  function markPage() {
    if (sock && !socketDead && !sock.destroyed) sock.write("{page}\n");
  }

  // 数据帧用自描述长度帧 `L<字节数>\n<原文>`：正文可含 \n/{end} 等任意字符，
  // 服务端按字节精确切，杜绝正文恰好为 `{end}` 被误判成控制帧。
  function sendFrame(text: string) {
    if (sock && !socketDead && !sock.destroyed) {
      const body = Buffer.from(text, "utf8");
      sock.write(`L${body.length}\n`);
      sock.write(body);
    }
  }

  // 有交互 UI（tui/rpc）才播报；print/json/后台脚本不打扰
  const hasUI = (ctx: unknown) =>
    (ctx as { hasUI?: boolean } | undefined)?.hasUI !== false;

  // 流的边界 = **一个 agent run**（= 一次输入），不是 turn。
  // pi 的结构（`packages/agent/src/agent-loop.ts`）：`agent_start` 之后是 N 个 turn
  // 循环，每个 turn 恰好一条 assistant 消息，工具调用就再来一轮；
  // 整摞回复全部落在**同一个 agent_start … agent_end** 之间。
  // 早先在 `turn_end` 关流，等于把「一次输入」切成 N 摞——Ctrl+1 掀一次只掀掉其中
  // 一页，后面几页照播（与 codex 那边「多摞被焊成一摞」是同一问题的两面：那边掀过头、
  // 这边掀不到）。2026-10-18 改为 run 级边界。
  pi.on("agent_start", (_e: unknown, ctx: unknown) => {
    if (!hasUI(ctx)) return;
    startTurn();
  });

  // `turn_end` 不关流：它只是「这一页说完了」，run 可能还有下一页（工具调用）。
  // 页的边界由下面 `message_start`(assistant) 的 `{page}` 帧承担。
  //
  // 整个 run 收尾：flush 残尾并优雅半关（end 等内核把尾帧/{end} 发完再 FIN，
  // 不能 destroy——强杀会随 RST 丢掉最后一两个字）。
  pi.on("agent_end", (_e: unknown, ctx: unknown) => {
    if (!hasUI(ctx) || !turnId) return;
    endTurn();
  });

  // 用户发新消息：立即打断上一轮（即使 assistant turn 尚未/未正常开始）。
  // 不另发 `__IVOX_STOP_PLAYBACK__` 哨兵：startTurn 的首帧立刻驱动服务端 beginTurn，
  // 其 bargeIn 就是全场清场；哨兵从另一条短连并发送达反而可能落在首帧之后，
  // 把刚认领的新轮也当「之前的」一起作废（整轮哑巴）——曾实测踩过。
  pi.on("message_start", (event: unknown, ctx: unknown) => {
    if (!hasUI(ctx)) return;
    if ((event as { message?: { role?: string } }).message?.role === "user") {
      // 只打断上一轮，**不开新流**——新流等 `agent_start` 开（没有则 `message_update`
      // 兜底 `if (!turnId) startTurn()`）。若在这里也 startTurn()，会与紧接的
      // agent_start 各开一条流，两条轮次互相顶，正在合成的就被掐 =
      // 播报自己打断自己（曾实测日志出现成对的「流式开始」+ 紧跟 {cancel}）。
      if (turnId) cancelTurn();
    } else if ((event as { message?: { role?: string } }).message?.role === "assistant") {
      // assistant 的一条 message = 一页。**不在这里开流**（turnId 为空就跳过，交给
      // message_update 的兜底去开）——开流必须在 turn_start / message_update 那一处，
      // 两处都开会各开一条、两条轮次互相顶（本文件上方那段注释里踩过）。
      if (turnId) markPage();
    }
  });

  pi.on("message_update", (event: unknown, ctx: unknown) => {
    if (!hasUI(ctx) || muted) return;
    const ev = event as {
      message?: { role?: string };
      assistantMessageEvent?: { type?: string; contentIndex?: number; delta?: string };
    };
    if (ev.message?.role && ev.message.role !== "assistant") return;
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

  pi.on("agent_settled", async (event: unknown, ctx: unknown) => {
    if (!hasUI(ctx)) return;
    const aborted = (event as { aborted?: boolean }).aborted === true;
    if (aborted) {
      if (turnId) cancelTurn();   // 用户中断：丢弃本轮未播内容，且本轮不再续念
      return;
    }
    if (turnId) endTurn();        // 正常收尾（turn_end 已收过则为空操作）
    if (streamed && !socketDead) return; // 已流式播报，不重复

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
