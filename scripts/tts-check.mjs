#!/usr/bin/env node
// iVox 播报黑盒自检：压真实 daemon，通过 Unix socket + HTTP /health + daemon.log 自动断言。
// 静音不出声（type:tts 只合成不播放拿 PCM 时长；播放链路只看管道收尾与日志），给退出码。
//
// 用法:
//   node scripts/tts-check.mjs                # 跑全部用例（附加到已在跑的 daemon）
//   node scripts/tts-check.mjs -f protocol    # 只跑名字匹配正则的用例
//   node scripts/tts-check.mjs --managed      # 自己 ivox on 重启 daemon（退出时保持运行）
//   node scripts/tts-check.mjs --strict       # advisory 用例也计入失败
//
// 退出码: 0 全过(允许 skip) / 1 有失败或 run 级致命关键字 / 2 预检或用法错误
//
// 只依赖 node: 内置模块，零 npm 依赖。串行执行（暂停/恢复日志无 source，只能靠时间窗关联）。
//
// 日志级别：断言大量依赖 DEBUG 行（如「队列状态: pending=… turn=…」数入队块数），
// 而 daemon 默认只留 INFO 及以上（Logger 的级别门限），不特意放出 DEBUG 就会让断言
// 读不到依据、假红。所以自检一律以 IVOX_LOG_LEVEL=debug 拉起 daemon（见 ensureDebugLogging），
// 跑完把该变量 unset（daemon 仍在 debug，要回 INFO 需再启一次——自检是排障工具，默认留 debug 更利于追）。

import net from "node:net";
import http from "node:http";
import fs from "node:fs/promises";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";

const HOME = homedir();
const SOCKET = join(HOME, ".config", "ivox", "ivox.sock");
const LOG = join(HOME, ".config", "ivox", "daemon.log");
const IVOX = join(HOME, ".local", "bin", "ivox");
const HEALTH_URL = "http://127.0.0.1:8888/health";
const SR = 48000;
const LABEL = "com.ivox.daemon";

// 以 debug 级日志拉起 daemon：断言要读 DEBUG 行（如「队列状态:」数入队块数），而 daemon
// 默认只留 INFO 及以上。环境变量走 `launchctl setenv`——LaunchAgent 跑在 launchd 下，
// 不继承当前 shell 的环境，父进程 execFileSync 传 env 是没用的（曾在这里想当然过）。
// 只设变量不改 daemon 已在跑的进程，必须 kickstart 才生效。
function ensureDebugLogging() {
  try {
    execFileSync("/bin/launchctl", ["setenv", "IVOX_LOG_LEVEL", "debug"]);
    execFileSync("/bin/launchctl", ["kickstart", "-k", `gui/${process.getuid()}/${LABEL}`]);
    console.log("# 日志级别: IVOX_LOG_LEVEL=debug（daemon 已重启）");
  } catch (e) {
    // 设不成不算致命：断言会因读不到 DEBUG 行而失败，但那属于诊断信号、不该让自检无法启动
    console.error(`⚠️ 切 debug 日志失败（断言可能假红）: ${e.message}`);
  }
}

// 跑完撤掉会话级环境变量，否则之后登录/新起的进程都带着 debug。已在跑的 daemon 不受影响
// （它已把级别读进静态常量），要回到 INFO 需再启一次。
function restoreLogEnv() {
  try { execFileSync("/bin/launchctl", ["setenv", "-u", "IVOX_LOG_LEVEL"]); } catch {}
}

// 否定断言：用例窗口内不得出现
const CASE_BAD = [
  /drain 超时强制返回/,
  /AudioEngine 启动失败/,
  /AudioEngine 异常，尝试重建/,
  /CONTINUATION MISUSE/,
  /Fatal error/,
  /non-empty mlx/,
  /TTS 合成失败/,
];
// run 级：任何时刻出现都判整体失败（即使单用例没抓到）
const RUN_FATAL = [/CONTINUATION MISUSE/, /Fatal error/, /non-empty mlx/];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const nowMs = () => Date.now();

// ───────────────────────── 原子能力 ─────────────────────────

function conn() {
  return new Promise((resolve, reject) => {
    const s = net.createConnection(SOCKET);
    s.once("connect", () => resolve(s));
    s.once("error", reject);
  });
}

// 发一帧后保持连接，调用方决定何时 end/destroy
function writeFrame(s, text) {
  const body = Buffer.from(text, "utf8");
  s.write(`L${body.length}\n`);
  s.write(body);
}

// 普通整段播报：{source:x}+正文，EOF 触发
async function speak(source, text) {
  const s = await conn();
  await new Promise((res) => s.write(`{source:${source}}${text}`, res));
  s.end();
}

// 带摞与页的一次性入队（Claude 路径的形态：{source,group,page}正文）。
// group = 摞号（一次输入引发的全部回复），page = 页号（一条 assistant 消息）。
// 不等 write 回调：实测在打断动作刚发生的那一刻，回调可能迟迟不触发，整条请求
// 根本发不出去（曾让 P3 干等 41 秒）。小报文直接 write 后 end，由 socket 自己 flush。
async function speakGrouped(source, group, page, text) {
  const s = await conn();
  s.write(`{source:${source},group:${group},page:${page}}${text}`);
  s.end();
}

// 掐 + 掀某一档：mode=page | stack | all，逐字对应 Ctrl+2 / Ctrl+1 / Ctrl+Esc。
async function skip(mode) {
  const s = await conn();
  s.end(`{type:skip,mode:${mode},tag:${runId}}\n`);
}

// 全场打断：停当前 + 清空排队（同 Ctrl+Esc），命令是 `ivox skip --all`。
// 历史的 `ivox quiet`（发 `{type:stop}`）已随该帧一起退役，改用 `{type:skip,mode:all}`。
async function skipAll() {
  const s = await conn();
  s.end(`{type:skip,mode:all,tag:${runId}}\n`);
}

// 流式连接句柄。登记到 openSocks，用例结束统一清理，避免连接泄漏压垮 daemon。
const openSocks = new Set();
async function openStream(turn, source) {
  const s = await conn();
  openSocks.add(s);
  s.on("close", () => openSocks.delete(s));
  await new Promise((res) => s.write(`{type:stream,source:${source},turn:${turn}}\n`, res));
  return {
    sendText: (t) => writeFrame(s, t),
    sendRawLine: (line) => s.write(line.endsWith("\n") ? line : line + "\n"),
    endFrame: () => s.end("{end}\n"),
    cancel: () => s.end("{cancel}\n"),
    halfClose: () => s.end(),
    destroy: () => s.destroy(),
    raw: s,
  };
}
async function closeAllStreams() {
  for (const s of openSocks) { try { s.destroy(); } catch {} }
  openSocks.clear();
  await sleep(200);
}

// type:tts：只合成不播放，解析 [4B LE len][PCM]…[0] 帧，返回累计 PCM 秒数。
async function ttsPcm(text, { timeoutMs = 60000 } = {}) {
  const s = await conn();
  s.write(`{type:tts}\n${text}`);
  s.end();
  const chunks = [];
  const done = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("type:tts 读取超时")), timeoutMs);
    s.on("data", (d) => chunks.push(d));
    s.on("end", () => clearTimeout(timer));
    s.on("error", (e) => { clearTimeout(timer); reject(e); });
    s.on("close", () => { clearTimeout(timer); resolve(); });
  });
  await done;
  const buf = Buffer.concat(chunks);
  let off = 0, pcmBytes = 0, frames = 0, badLen = false;
  while (off + 4 <= buf.length) {
    const len = buf.readUInt32LE(off); off += 4;
    if (len === 0) break;
    if (len > 100 * 1024 * 1024) { badLen = true; break; }
    if (off + len > buf.length) { badLen = true; break; }
    pcmBytes += len; frames += 1; off += len;
  }
  return { frames, pcmBytes, seconds: pcmBytes / 2 / SR, badLen, ended: off <= buf.length };
}

function health() {
  return new Promise((resolve) => {
    const req = http.get(HEALTH_URL, { timeout: 3000 }, (res) => {
      let d = "";
      res.on("data", (c) => (d += c));
      res.on("end", () => { try { resolve(JSON.parse(d)); } catch { resolve(null); } });
    });
    req.on("error", () => resolve(null));
    req.on("timeout", () => { req.destroy(); resolve(null); });
  });
}

// daemon 进程 CPU%：紧循环空转的直接表征（macOS 的 %cpu 是近期占用，空闲≈0、合成峰值≈60-90、空转≈100）
function daemonCpu() {
  try {
    const pid = execFileSync("pgrep", ["-f", "bin/ivox serve"]).toString().trim().split("\n")[0];
    return parseFloat(execFileSync("ps", ["-o", "%cpu=", "-p", pid]).toString().trim());
  } catch { return null; }
}

// ───────────────────────── 日志增量采集 ─────────────────────────

class LogTail {
  constructor() { this.lines = []; this.runStart = nowMs(); this.rotated = false; }
  async baseline() {
    try {
      const st = await fs.stat(LOG);
      this.ino = st.ino; this.size = st.size;
    } catch { this.ino = 0; this.size = 0; }
  }
  // 读取基线之后（且时间戳 >= sinceTs）的新行，识别 5MB 轮转
  async poll(sinceTs = 0) {
    let st;
    try { st = await fs.stat(LOG); } catch { return this.lines; }
    if (st.ino !== this.ino || st.size < this.size) {
      this.rotated = true; this.ino = st.ino; this.size = 0; // 从头读
    }
    if (st.size <= this.size) return this.lines;
    const fh = await fs.open(LOG, "r");
    try {
      const len = st.size - this.size;
      const buf = Buffer.allocUnsafe(len);
      await fh.read(buf, 0, len, this.size);
      this.size = st.size;
      const text = buf.toString("utf8");
      for (const raw of text.split("\n")) {
        const m = raw.match(/^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})\.(\d{3}) \[(\w+)\] (.*)$/);
        if (!m) continue;
        const ts = new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6], +m[7]).getTime();
        if (ts >= sinceTs) this.lines.push({ ts, level: m[8], msg: m[9], raw });
      }
    } finally { await fh.close(); }
    return this.lines;
  }
  // sinceTs 之后匹配正则的行
  grep(re, sinceTs = 0) { return this.lines.filter((l) => l.ts >= sinceTs && re.test(l.msg)); }
  // 等到出现匹配（持续 poll 新日志）
  async waitFor(re, { sinceTs = 0, timeout = 30000, interval = 150 } = {}) {
    const deadline = nowMs() + timeout;
    while (nowMs() < deadline) {
      await this.poll(sinceTs);
      const hit = this.lines.find((l) => l.ts >= sinceTs && re.test(l.msg));
      if (hit) return hit;
      await sleep(interval);
    }
    await this.poll(sinceTs);
    return this.lines.find((l) => l.ts >= sinceTs && re.test(l.msg)) || null;
  }
}

// ───────────────────────── runner ─────────────────────────

const args = process.argv.slice(2);
const FILTER = (() => { const i = args.indexOf("-f"); return i >= 0 ? new RegExp(args[i + 1]) : null; })();
const MANAGED = args.includes("--managed");
const STRICT = args.includes("--strict");

const runId = Math.random().toString(16).slice(2, 7);
let seq = 0;
const ids = () => {
  seq += 1;
  const tag = `c${String(seq).padStart(2, "0")}${runId}`;
  return { source: tag, turn: `t${tag}` };
};

const results = [];

// 等模型就绪
async function waitReady(log) {
  const deadline = nowMs() + 120000;
  while (nowMs() < deadline) {
    const h = await health();
    if (h && h.engine === "ready") return h;
    if (h && h.engine === "failed") throw new Error("TTS 引擎 failed");
    await log.poll(0);
    await sleep(1000);
  }
  throw new Error("等待 engine=ready 超时");
}

// 等播放管道收尾：health 空闲 且 窗口内出现「播报收尾」（双条件）
// 锚点原先是 `媒体控制: 恢复`——播报不再借还背景音乐后那条日志不再出现，
// 改用 PlaybackQueue 显式打的收尾标记（语义更准：它只在"队列真收尾"时打）。
async function waitSettled(log, sinceTs, { timeout = 60000 } = {}) {
  const deadline = nowMs() + timeout;
  let settledAt = 0;
  while (nowMs() < deadline) {
    await log.poll(sinceTs);
    // 取**最新**一条「播报收尾」，不是第一次见到的那条：锁死第一次会算出一个负间隔
    //（用例先探测音频时长会留下一次早收尾，真收尾在几秒后，2026-10-17 `A-tail` 假红）。
    // 健康检查同时要求队列真空着，所以中途那次早收尾不会被误当成「已收尾」返回。
    {
      const r = log.grep(/播报收尾: 队列已空/, sinceTs).at(-1);
      if (r) settledAt = r.ts;
    }
    const h = await health();
    if (settledAt && h && h.queued === 0 && h.playing === false) {
      await sleep(300); // 日志落盘宽限
      return { settledAt, h: await health() };
    }
    await sleep(150);
  }
  return null;
}

async function runCase(c) {
  const { source, turn } = ids();
  const t0 = nowMs();
  const log = runnerLog;
  const ctx = {
    source, turn, log, t0,
    sleep,
    speak: (text) => speak(source, text),
    speakGrouped: (group, page, text) => speakGrouped(source, group, page, text),
    skip,
    skipAll,
    openStream: (t = turn) => openStream(t, source),
    ttsPcm,
    health,
    ids,
    // 断言收集到失败列表，不立即抛
    failures: [],
    check(cond, msg) { if (!cond) this.failures.push(msg); },
    async settled(timeout = 60000) {
      const r = await waitSettled(log, t0, { timeout });
      if (!r) this.failures.push("播放管道未在超时内收尾（无恢复日志或 health 未空闲）");
      return r;
    },
    // 用例窗口内否定断言
    noBad(extra = []) {
      const bads = [...CASE_BAD, ...extra];
      for (const re of bads) {
        const hit = log.grep(re, t0);
        if (hit.length) this.failures.push(`窗口内出现异常「${re.source}」: ${hit.at(-1).msg}`);
      }
    },
    windowLogs() { return log.grep(/.*/, t0).map((l) => "  " + l.raw); },
  };
  try {
    await c.run(ctx);
  } catch (e) {
    ctx.failures.push(`用例抛异常: ${e.message}`);
  } finally {
    await closeAllStreams();
  }
  // 外部播报干扰：run 期间别的 agent（Claude/Codex 的 Stop hook、用户手动 speak）恰好开口，
  // 会插进用例自己的音频窗口，尾音/收尾/时长类断言失真。检测到则把失败降级为 skip 并显式
  // 打出证据——只降级失败，通过的不动；不掩盖，也别把它当产品缺陷。
  //（普通播报已不再 bargeIn，因此不再作废用例的流式轮次；保留此项是因为它仍会插播。）
  const foreign = log.grep(new RegExp(`队列入队: source=(?!c\\d\\d${runId})`), t0);
  // 外部全场打断（别的终端跑 `ivox skip --all` / 手动按 Ctrl+Esc）会在用例播到一半时
  // 掐掉本轮，尾音/收尾/恢复类断言必然失真——同样降级为 skip 并给出证据。
  // 判据是「跳过请求」而非旧的「收到停止播放指令」：那句文案早在停止帧退役时就没了，
  // 旧正则从此永不命中（一条沉默的假绿检测，本次一并修掉）。
  const sentinel = log.grep(new RegExp(`跳过请求: mode=(?!.*tag=${runId})`), t0);
  const hit = foreign[0] ?? sentinel[0];
  return { name: c.name, advisory: !!c.advisory, needsAudio: !!c.needsAudio, failures: ctx.failures,
           interfered: hit ? hit.msg : "", ms: nowMs() - t0,
           window: ctx.failures.length ? ctx.windowLogs() : [] };
}

let runnerLog;

const cases = [
  // ───────── F：合成确定性/时长（不碰设备）─────────
  {
    name: "F-pcm-duration",
    async run(ctx) {
      const samples = [
        { text: "这是两句正常的中文文本，用来验证合成时长。第二句紧跟着也合成出来。", min: 1, max: 12 },
        { text: "长文本".repeat(60), min: 8, max: 60 },
        { text: "看这个链接 https://a.b/path?x=1&y=2 和表格符号，代码 `const x=1`，还有 emoji 🎉，都要能合成。", min: 1, max: 15 },
        { text: "超" + "长".repeat(180) + "无标点连续文本不应挂死，应正常返回 PCM 并以零帧结束。", min: 8, max: 60 },
      ];
      const secs = [];
      for (const s of samples) {
        const r = await ctx.ttsPcm(s.text);
        ctx.check(!r.badLen, `帧长度解析错误/截断: ${JSON.stringify(r)}`);
        ctx.check(r.frames > 0 && r.pcmBytes > 0, `空 PCM: 「${s.text.slice(0, 12)}」 frames=${r.frames}`);
        ctx.check(r.seconds >= s.min && r.seconds <= s.max,
          `秒数 ${r.seconds.toFixed(2)} 超出宽松区间 [${s.min},${s.max}]：「${s.text.slice(0, 10)}」`);
        secs.push(r.seconds);
      }
      ctx.check(secs[1] > secs[0], `长文时长(${secs[1]?.toFixed(1)}) 应大于短句(${secs[0]?.toFixed(1)})`);
      // 纯 URL / 纯符号（不含允许的语气标点 . ! ? 等，那些会被保留给 TTS 停顿）：
      // cleanText 后为空 → 立即 0 帧、0 PCM
      for (const empty of ["https://a.b/c?x=1&y=2", "*** ### +++ &&&"]) {
        const r = await ctx.ttsPcm(empty);
        ctx.check(r.frames === 0 && r.pcmBytes === 0, `纯噪音文本应清空为 0 PCM，实际 ${r.pcmBytes}：${empty}`);
      }
      ctx.noBad();
    },
  },

  // ───────── E1：长度帧防控制帧注入 ─────────
  {
    name: "E1-length-frame-injection",
    async run(ctx) {
      const st = await ctx.openStream();
      // 正文里独立成行的 {end}/{cancel} 必须被当正文，不得提前结束/取消
      st.sendText("{end}\n{cancel}\n🎉你好，世界🇨🇳");
      await sleep(400);
      let lines = ctx.log.grep(new RegExp(`流式(结束|取消).*${ctx.turn}`), ctx.t0);
      ctx.check(lines.length === 0, `注入的控制帧被误判，提前结束/取消: ${lines.map((l) => l.msg).join(";")}`);
      // 连接仍可写：第二帧应入队
      st.sendText("这是第二帧正文内容，用来确认连接还活着。");
      await sleep(400);
      st.endFrame();
      const settled = await ctx.settled(40000);
      ctx.check(!!settled, "未收尾");
      const end = await ctx.log.waitFor(new RegExp(`流式结束: turn=${ctx.turn}`), { sinceTs: ctx.t0, timeout: 5000 });
      ctx.check(!!end, "缺流式结束日志");
      ctx.noBad();
    },
  },

  // ───────── E2：旧裸文本帧后向兼容 ─────────
  {
    name: "E2-legacy-bare-text",
    async run(ctx) {
      const st = await ctx.openStream();
      st.sendRawLine("这是第一句旧客户端裸文本。");
      st.sendRawLine("这是第二句，仍然正常。");
      st.sendRawLine("{end}");
      const settled = await ctx.settled(40000);
      ctx.check(!!settled, "未收尾");
      const enq = ctx.log.grep(new RegExp(`流式入队: .*turn=${ctx.turn}`), ctx.t0);
      ctx.check(enq.length >= 1, "裸文本帧未入队");
      ctx.noBad();
    },
  },

  // ───────── E3：轮次隔离，旧轮迟到帧不反杀 ─────────
  {
    name: "E3-turn-isolation",
    async run(ctx) {
      const tA = ctx.turn;
      const A = await ctx.openStream(tA);
      A.sendText("这是第一轮的一句比较长的播报内容，确保它真正进入模型开始合成。");
      // 等 A 真正开始合成再开 B，消除竞态
      const aStart = await ctx.log.waitFor(/TTS 合成开始/, { sinceTs: ctx.t0, timeout: 20000 });
      ctx.check(!!aStart, "A 轮未开始合成");
      await sleep(800);
      const { turn: tB } = ctx.ids();
      const B = await ctx.openStream(tB);
      const tBstart = nowMs();
      B.sendText("这是第二轮的新内容，应该接管播报。");
      // 等 B 真正被队列接受（成为当前轮）再发 A 的迟到帧：否则「B 尚未接管」时 A 帧合法，
      // 断言会随 beginTurn/enqueue 的 Task 调度时序抖动。
      const bAccepted = await ctx.log.waitFor(new RegExp(`队列状态: .*turn=${tB}`), { sinceTs: tBstart, timeout: 15000 });
      ctx.check(!!bAccepted, "B 轮未被队列接受");
      // 给旧连接 A 发迟到正文 + {end}，必须被静默丢弃
      A.sendText("第一轮迟到的残句不应该被念出来。");
      A.endFrame();
      await sleep(600);
      B.endFrame();
      await sleep(200);
      try { A.destroy(); B.destroy(); } catch {}
      const settled = await ctx.settled(45000);
      ctx.check(!!settled, "未收尾");
      // tB 开始后，tA 的迟到帧不得被队列接受（handler 的「流式入队」只是收到帧，无条件打印，不作数）
      const aLateAcc = ctx.log.grep(new RegExp(`队列状态: .*turn=${tA}`), tBstart);
      ctx.check(aLateAcc.length === 0, `旧轮 A 在 B 开始后仍被队列接受 ${aLateAcc.length} 条`);
      ctx.noBad();
    },
  },

  // ───────── E4：cancel 后迟到帧丢弃 ─────────
  {
    name: "E4-cancel-drops-late",
    async run(ctx) {
      const st = await ctx.openStream();
      st.sendText("第一句先发出去。");
      await sleep(300);
      st.cancel();
      await sleep(300);
      // 取消后连接可能已被服务端关闭，写入报错要容错
      try { st.sendRawLine("取消后迟到的句子不应入队。"); } catch {}
      try { st.halfClose(); } catch {}
      const cancel = await ctx.log.waitFor(new RegExp(`流式取消: turn=${ctx.turn}`), { sinceTs: ctx.t0, timeout: 8000 });
      ctx.check(!!cancel, "缺流式取消日志");
      await sleep(800);
      const after = ctx.log.grep(new RegExp(`流式入队: .*turn=${ctx.turn}`), cancel ? cancel.ts : ctx.t0);
      ctx.check(after.length === 0, "取消后仍有入队");
      // 取消轮也要走收尾流程，等它收尾避免污染后续用例窗口
      await ctx.settled(20000);
      ctx.noBad([/drain 超时强制返回/]);
    },
  },

  // ───────── E5：EOF 等价 {end}，残尾 flush ─────────
  {
    name: "E5-eof-flush-tail",
    async run(ctx) {
      const st = await ctx.openStream();
      st.sendText("这是一句完整的话。");
      st.sendText("最后半句没有结束符");
      st.halfClose(); // 不发 {end}
      const end = await ctx.log.waitFor(new RegExp(`流式结束: turn=${ctx.turn}`), { sinceTs: ctx.t0, timeout: 10000 });
      ctx.check(!!end, "EOF 未触发流式结束");
      const settled = await ctx.settled(40000);
      ctx.check(!!settled, "未收尾");
      const enq = ctx.log.grep(new RegExp(`流式入队: .*turn=${ctx.turn}`), ctx.t0);
      ctx.check(enq.length >= 1, "残尾未 flush 入队");
      ctx.noBad();
    },
  },

  // ───────── E6：并行流的 {cancel} 不拖垮真正在跑的轮（pi 会开两条流，其中一条刚开就被 {cancel}）─────────
  // 回归：曾把「见过」当「被顶掉」——并行那条空流一取消，就把真正在跑的这条判成过期旧轮，
  // 后续正文全部静默丢弃（整轮没声音，日志里连「队列状态」都没有）。
  // 注：客户端不再在同一步发全场打断（pi 开新轮前的清场改由首帧 beginTurn 的 bargeIn 承担）——
  // 全场打断如今是「你开口 = 全场作废」，会连在跑的轮一起作废，故不适用于本用例（见 E7）。
  {
    name: "E6-parallel-cancel-keeps-live-turn",
    async run(ctx) {
      const t1 = ctx.turn;              // 真正承载正文的连接
      const t2 = ctx.ids().turn;        // 并行的第二条流
      const A = await ctx.openStream(t1);
      await sleep(60);
      const B = await ctx.openStream(t2);
      await sleep(60);
      B.cancel();                       // 它立刻 {cancel}：只作废自己，不碰在跑的 t1
      await sleep(260);
      A.sendText("并行那条空流取消之后，这条正文仍应被完整念出来。");
      A.endFrame();
      const start = await ctx.log.waitFor(new RegExp(`合成开始 \\[${ctx.source}-`), { sinceTs: ctx.t0, timeout: 30000 });
      ctx.check(!!start, "新轮正文被静默丢弃（入队后无合成开始）：并行取消把在跑的轮次一起作废了");
      await sleep(500);
      const stray = ctx.log.grep(new RegExp(`流式入队: turn=${t2}`), ctx.t0);
      ctx.check(stray.length === 0, "被取消的并行轮次不该入队");
      const settled = await ctx.settled(40000);
      ctx.check(!!settled, "未收尾");
      ctx.noBad();
    },
  },

  // ───────── E7：全场打断作废全部流式轮（你开口 = 全场闭嘴）─────────
  // 语义：全场打断（`ivox skip --all`，同 Ctrl+Esc）不只停当场，还作废此前所有流式轮。
  // 场景：在 Claude 里提交 prompt 时，pi 手里正在生成的那一轮后续增量不该再开口
  //（否则「我说话电脑就不说了」不成立——当场静音了，下一句生成出来照样念）。
  {
    name: "E7-stop-sentinel-buries-live-turn",
    async run(ctx) {
      const st = await ctx.openStream(ctx.turn);
      st.sendText("全场打断之前这句照常开始合成，用作对照。");
      await sleep(1200);                 // 让对照句确实已进模型（其「合成开始」落在打断之前）
      await ctx.skipAll();                 // 你开口
      await sleep(200);
      const tAfter = nowMs();
      st.sendText("全场打断之后这整句都不该被念出来：它属于已被作废的那一轮。");
      st.endFrame();                     // 正常收尾（{end} 对已作废轮是空操作）
      const settled = await ctx.settled(40000);
      ctx.check(!!settled, "未收尾");
      const late = ctx.log.grep(new RegExp(`TTS 合成开始 \\[${ctx.source}-`), tAfter);
      ctx.check(late.length === 0, `全场打断后该轮不该再有合成开始，实得 ${late.length} 条`);
      const h = await ctx.health();
      ctx.check(h && h.queued === 0 && h.playing === false, `未收敛空闲: ${JSON.stringify(h)}`);
      ctx.noBad();
    },
  },

  // ───────── E8：队首轮播空等下一批块时不得紧循环（曾独占总 actor → 播报永久瘫痪）─────────
  // 回归：`guard let job = frontBucket?.jobs.first else { continue }` 没有挂起点——队首桶已播空
  //（它那句 job 已被 claim 走）、该轮尚未 endTurn（还在等下一批块），而其后已排了别的桶时，
  // 上面 `!hasPendingBuckets` 分支进不去，于是无 await 地空转：独占 PlaybackQueue actor 且永不
  // 释放，enqueue/endTurn/cancelAll 一律被饿死（连快捷键打断都进不来）→ 队尾内容永不播、
  // CPU 烧满一核、/health 无响应，连 10s 读超时的 EOF 兜底也救不回（endTurn 进不了僵死的 actor）。
  // 场景用「流式轮已播空未收尾 + 队尾排一条普通播报」精确压出来（多 agent 交错即此形态）。
  {
    name: "E8-head-bucket-wait-no-spin",
    needsAudio: true,
    async run(ctx) {
      const tail = ctx.ids();          // 队尾那条：普通播报（无 turn）
      const A = await ctx.openStream();
      A.sendText("这是一段用来触发复现的测试文本，长度足够越过最小切句门槛。");
      const started = await ctx.log.waitFor(new RegExp(`TTS 合成开始 \\[${ctx.source}-`),
        { sinceTs: ctx.t0, timeout: 20000 });
      ctx.check(!!started, "首块未开始合成");
      // 队尾排一条别的播报：此刻本轮 job 已被 claim（桶空、轮未收尾）→ 正是触发条件
      await speak(tail.source, "这条排在队尾，应该等前一轮收尾之后才播出来。");
      await sleep(3500);               // 越过首块合成（≈2.5s），让 producer 回到循环顶部
      A.endFrame();
      // ① 活性：actor 被紧循环独占时 /health 直接超时（health() 返回 null）
      let alive = 0;
      for (let i = 0; i < 3; i++) { if (await ctx.health()) alive += 1; await sleep(600); }
      ctx.check(alive === 3, `紧循环僵死：${3 - alive}/3 次 /health 无响应（需 ivox off && ivox on 重启）`);
      // ② 队尾那条最终必须被合成（旧实现永不播）
      const tailStart = await ctx.log.waitFor(new RegExp(`TTS 合成开始 \\[${tail.source}-`),
        { sinceTs: ctx.t0, timeout: 30000 });
      ctx.check(!!tailStart, "队首轮收尾后，队尾播报仍未被合成（管道被卡死）");
      const settled = await ctx.settled(45000);
      ctx.check(!!settled, "未收尾");
      // ③ 空转的直接表征：收尾后应完全空闲，紧循环则把一个核烧满
      const cpus = [];
      for (let i = 0; i < 8; i++) { cpus.push(daemonCpu()); await sleep(150); }
      const nums = cpus.filter((x) => x != null).sort((a, b) => a - b);
      const median = nums.length ? nums[Math.floor(nums.length / 2)] : 0;
      ctx.check(median < 50, `收尾后 daemon CPU 仍居高位 median=${median}%（紧循环空转）`);
      ctx.noBad();
    },
  },

  // ───────── C：密集打断不崩溃、不雪崩 ─────────
  {
    name: "C-bargein-stress",
    async run(ctx) {
      const longText = "这是第N轮密集打断测试，句子足够长以保证真正进入模型推理，占用若干秒合成时间。";
      for (let i = 1; i <= 8; i++) {
        const { turn } = ctx.ids();
        const st = await ctx.openStream(turn);
        st.sendText(longText.replace("第N轮", `第${i}轮`));
        await sleep(i === 4 ? 0 : 250);
        if (i === 4) {
          await ctx.skipAll();       // 中间插一次全局停止
          await sleep(250);
        }
        // 真实客户端开新轮前会关掉旧连接；最后一轮发 {end}，其余直接销毁
        if (i === 8) st.endFrame(); else st.destroy();
      }
      // 健康探针：全程 daemon 必须存活
      const h0 = await ctx.health();
      ctx.check(h0 && h0.status === "ok", `压测中 /health 异常: ${JSON.stringify(h0)}`);
      const settled = await ctx.settled(90000);
      ctx.check(!!settled, "压测后未收敛空闲");
      // 不允许旧轮残句在被顶掉后「合成完成」之外又开口：检查最后一轮之外没有迟到入队（宽松：只查致命）
      const h1 = await ctx.health();
      ctx.check(h1 && h1.queued === 0 && h1.playing === false, "收敛后非空闲");
      ctx.noBad(); // 含 Fatal/non-empty/CONTINUATION MISUSE/合成失败
    },
  },

  // ───────── D：打断后活性（队列+模型都活着）─────────
  {
    name: "D-liveness-after-burst",
    async run(ctx) {
      // 5 轮快速打断，每轮开新连接前销毁旧连接（贴近真实客户端）
      for (let i = 0; i < 5; i++) {
        const { turn } = ctx.ids();
        const st = await ctx.openStream(turn);
        st.sendText("快速打断活性测试用的一句中等长度内容。");
        await sleep(180);
        st.destroy();
      }
      await ctx.skipAll();
      await sleep(500);
      const tSpeak = nowMs();
      await ctx.speak("打断已结束，现在验证队列还能正常播报这一整句话。");
      const settled = await ctx.settled(60000);
      ctx.check(!!settled, "普通 speak 未收尾");
      // 播报生命周期仍在：该 source 有新的合成开始 → 之后队列收尾。
      // （原先还断言「媒体控制: 暂停 → 恢复」这对音乐动作；播报不再借还背景音乐，那对已不存在。）
      const synthStart = ctx.log.grep(new RegExp(`TTS 合成开始 \\[${ctx.source}`), tSpeak)[0];
      const settle = ctx.log.grep(/播报收尾: 队列已空/, tSpeak).at(-1);
      ctx.check(!!synthStart, "打断后没有新的合成开始（队列死了）");
      ctx.check(!!settle && (!synthStart || settle.ts >= synthStart.ts), "收尾早于合成开始（生命周期错乱）");
      // 模型通道也活着
      const r = await ctx.ttsPcm("模型通道活性确认，应该能正常合成出声音。");
      ctx.check(r.pcmBytes > 0 && !r.badLen, "打断后 type:tts 无响应");
      ctx.noBad();
    },
  },

  // ───────── A：尾音不被提前掐（需音频设备）─────────
  {
    name: "A-tail-audio-not-cut",
    needsAudio: true,
    async run(ctx) {
      const sentences = [
        "第一句话用来建立连续播放的节奏和铺垫。",
        "第二句话紧跟其后，验证句间没有空隙和吞字。",
        "最后是尾部这句稍长一些的收尾内容，专门用来检验尾音是否被完整播放。",
      ];
      // 用 type:tts 预估最后一句真实音频时长
      const tail = await ctx.ttsPcm(sentences[2]);
      ctx.check(tail.seconds > 0.5, `尾句合成时长异常: ${tail.seconds}`);
      const st = await ctx.openStream();
      for (const s of sentences) st.sendText(s);
      st.endFrame();
      const settled = await ctx.settled(60000);
      ctx.check(!!settled, "未收尾");
      // StreamBuffer 会按 ≥24 字合并句块，1 句 ≠ 1 个 job；断言「每个入队块都被完整合成」即可
      const accepted = ctx.log.grep(new RegExp(`队列状态: .*turn=${ctx.turn}`), ctx.t0).length;
      const starts = ctx.log.grep(/TTS 合成开始/, ctx.t0);
      const dones = ctx.log.grep(/TTS 合成完成/, ctx.t0);
      ctx.check(starts.length >= 1 && starts.length === accepted,
        `合成开始(${starts.length}) 应等于入队块数(${accepted})`);
      ctx.check(dones.length === starts.length, `合成完成(${dones.length}) 应与开始(${starts.length}) 一致`);
      const tDone = dones.at(-1)?.ts ?? 0;
      const tSettled = settled?.settledAt ?? 0;
      const gap = (tSettled - tDone) / 1000;
      ctx.check(gap >= Math.max(0.8, tail.seconds * 0.5),
        `收尾过早，尾音可能被掐：合成完→收尾仅 ${gap.toFixed(2)}s，尾句音频 ${tail.seconds.toFixed(2)}s`);
      const finish = ctx.log.grep(/播放收尾完成/, ctx.t0).at(-1);
      ctx.check(!!finish, "缺「播放收尾完成」日志");
      ctx.noBad();
    },
  },

  // ───────── B：合成领先播放（advisory，需音频）─────────
  {
    name: "B-synthesis-leads-playback",
    needsAudio: true,
    advisory: true,
    async run(ctx) {
      const sentences = Array.from({ length: 5 }, (_, i) =>
        `这是第${i + 1}句用来观测合成是否领先播放的中等长度播报内容。`);
      const totalPcm = await ctx.ttsPcm(sentences.join(""));
      const st = await ctx.openStream();
      for (const s of sentences) { st.sendText(s); await sleep(100); }
      st.endFrame();
      const settled = await ctx.settled(60000);
      ctx.check(!!settled, "未收尾");
      const starts = ctx.log.grep(/TTS 合成开始/, ctx.t0);
      ctx.check(starts.length === 5, `合成开始应为5，实际 ${starts.length}`);
      const span = ((starts.at(-1)?.ts ?? 0) - (starts[0]?.ts ?? 0)) / 1000;
      // producer 应领先播放：5 句合成的发起时间跨度显著小于总音频秒数（很松的单向代理指标）
      ctx.check(span < totalPcm.seconds * 0.8,
        `合成发起跨度 ${span.toFixed(1)}s 未明显领先总音频 ${totalPcm.seconds.toFixed(1)}s（可能欠载）`);
      ctx.noBad();
    },
  },

  // ───────── P1：掀页后接着播下一页 ─────────
  // 需求：Ctrl+2 = 掐 + 掀当前页。掀完必须落到下一页，而不是把队列掀空。
  {
    name: "P1-skip-page-then-next",
    async run(ctx) {
      const g = `pg${ctx.turn}`;
      await ctx.speakGrouped(g, "P1", "第一页要说的话，长度够触发一次合成就好。");
      await ctx.speakGrouped(g, "P2", "第二页要说的话，长度够触发一次合成就好。");
      const started = await ctx.log.waitFor(/TTS 合成开始/, { sinceTs: ctx.t0, timeout: 20000 });
      ctx.check(!!started, "第一页未开始合成");
      await sleep(500);
      await ctx.skip("page");
      const dropped = await ctx.log.waitFor(/本页剩余块已丢/, { sinceTs: ctx.t0, timeout: 8000 });
      ctx.check(!!dropped, "缺掀页日志");
      const settled = await ctx.settled(45000);
      ctx.check(!!settled, "未收尾");
      // 关键断言：第二页仍然被合成——掀掉一页不等于掀掉整摞
      const starts = ctx.log.grep(/TTS 合成开始/, ctx.t0);
      ctx.check(starts.length >= 2, `掀页后下一页没有被合成（合成开始仅 ${starts.length} 次）`);
      ctx.noBad();
    },
  },

  // ───────── P2：连续掀页不炸 ─────────
  // 需求：用户可以连按。连按最容易撞上「块刚被弹出、门控还没过」与「页被删了、
  // 游标还指着它」两个时刻，两者都得安全跳过而不是崩。
  {
    name: "P2-skip-page-repeat-safe",
    async run(ctx) {
      const g = `pr${ctx.turn}`;
      for (let i = 1; i <= 3; i++) {
        await ctx.speakGrouped(g, `Q${i}`, `第${i}页要说的话，长度够触发一次合成就好。`);
      }
      const started = await ctx.log.waitFor(/TTS 合成开始/, { sinceTs: ctx.t0, timeout: 20000 });
      ctx.check(!!started, "第一页未开始合成");
      for (let i = 0; i < 3; i++) { await ctx.skip("page"); await sleep(120); }
      const h = await ctx.health();                       // 连掀之后 daemon 必须还活着
      ctx.check(!!h, "连掀三次后 daemon 不再响应");
      await ctx.settled(30000);
      ctx.noBad([/EXC_BREAKPOINT/, /removeFirst from empty/, /Index out of range/]);
    },
  },

  // ───────── P3：连按两下不误删后到的页（陈旧靶心回归）─────────
  // 背景：2026-10-17 实测 bug。用户按第一下掀页后，这一摞的后续页才陆续到达；
  // 用户以为已经跳完、没有东西可跳，又按一下——若此时仍持着上一页的页号当靶心，
  // 刚到的新页就被误删，表现为「新的内容凭空消失」。这条钉死它不再回归。
  {
    name: "P3-same-page-continues-after-skip",
    async run(ctx) {
      const g = `pl${ctx.turn}`;
      // 同一页 A 分两批到（Claude 的真实行为：一条 assistant 消息按行批增量送来）
      await ctx.speakGrouped(g, "A", "第一页的第一部分内容，长度够触发一次合成就好。");
      const started = await ctx.log.waitFor(/TTS 合成开始/, { sinceTs: ctx.t0, timeout: 20000 });
      ctx.check(!!started, "第一部分未开始合成");
      await sleep(400);
      await ctx.skip("page");                            // 第一下：掀掉页 A 当时的块
      const dropped = await ctx.log.waitFor(/本页剩余块已丢/, { sinceTs: ctx.t0, timeout: 8000 });
      ctx.check(!!dropped, "缺第一下掀页日志");
      // 页 A 的续段这时才到。按需求层「掀页掀不彻底，没来的部分等它来了照样播」，
      // 它必须照常入队并播出来——这条钉的是能力边界不被误当成 bug 修掉。
      await ctx.speakGrouped(g, "A", "同一页后到的续段内容，按需求应当照样播出来。");
      const resumed = await ctx.log.waitFor(/队列入队（摞）/, { sinceTs: dropped.ts, timeout: 10000 });
      ctx.check(!!resumed, "同页续段没有入队");
      const t2 = nowMs();
      await ctx.skip("page");                            // 第二下：掀当前正在播的那一页
      const settled = await ctx.settled(45000);
      ctx.check(!!settled, "未收尾");
      // 第二下按在续段开播之后 → 它就是「当前页」，按需求该被掀掉。
      // 若按在开播之前，则当时没有页可掀，只掐不掀（targeting 空靶心）。
      const after2 = ctx.log.grep(/TTS 合成开始/, t2);
      ctx.check(after2.length === 0,
        `第二下掀页后仍在合成 ${after2.length} 次（掀页应掐住当前页）`);
      ctx.noBad();
    },
  },

  // ───────── S1：掀摞（Ctrl+1）并由墓碑拦住该摞后续增量（场景 6 + 2）─────────
  {
    name: "S1-skip-stack-and-tombstone",
    async run(ctx) {
      const gA = `sa${ctx.turn}`;
      const gB = `sb${ctx.turn}`;
      await ctx.speakGrouped(gA, "V1", "第一摞的内容，长度够触发一次合成就好。");
      await ctx.speakGrouped(gB, "V2", "第二摞的内容，应该在第一摞掀完之后接着播。");
      const started = await ctx.log.waitFor(/TTS 合成开始/, { sinceTs: ctx.t0, timeout: 20000 });
      ctx.check(!!started, "第一摞未开始合成");
      await sleep(400);
      await ctx.skip("stack");                           // 掀掉第一摞整摞
      // 该摞的后续增量必须被墓碑静默丢弃（场景 2）
      await ctx.speakGrouped(gA, "V1", "被掀掉那一摞的后续增量，不该再开口。");
      await sleep(600);
      const dead = ctx.log.grep(/队列入队（摞）/ , ctx.t0).filter((h) => /page=V1/.test(h.msg));
      ctx.check(dead.length === 1,
        `被掀摞的后续增量被重新入队 ${dead.length} 次（墓碑没拦住）`);
      const settled = await ctx.settled(45000);
      ctx.check(!!settled, "未收尾");
      // 下一摞必须照播
      const starts = ctx.log.grep(/TTS 合成开始/, ctx.t0);
      ctx.check(starts.length >= 2, `掀摞后下一摞没有被播（合成开始仅 ${starts.length} 次）`);
      ctx.noBad();
    },
  },

  // ───────── S2：跨来源混排，顺序只由到达决定（场景 9）─────────
  // 两种形态混排：带摞页的一次性入队（Claude 形态）+ 流式轮（pi 形态）。
  // 断言后到的不会插到先到的前面。
  {
    name: "S2-mixed-sources-keep-arrival-order",
    async run(ctx) {
      const g = `sx${ctx.turn}`;
      const first = ctx.ids().turn;                      // 流式轮（pi 形态）
      const st = await ctx.openStream(first);
      st.sendText("先到的流式内容，应该排在前面播。");
      await sleep(200);
      await ctx.speakGrouped(g, "M2", "后到的一次性内容，应该排在流式那一条之后。");
      await sleep(200);
      st.endFrame();
      const settled = await ctx.settled(60000);
      ctx.check(!!settled, "未收尾");
      // 两种形态的入队日志不同名：流式写「流式入队」，带摞页的一次性写「队列入队（摞）」
      const streamed = ctx.log.grep(/流式入队/, ctx.t0).filter((h) => /turn=/.test(h.msg));
      const grouped = ctx.log.grep(/队列入队（摞）/, ctx.t0);
      ctx.check(streamed.length >= 1, "流式来源未入队");
      ctx.check(grouped.length >= 1, "带摞页的一次性来源未入队");
      ctx.noBad();
    },
  },
];

// 无音频设备探测：发一短句，出现引擎启动失败/drain 超时即视为无设备
async function probeAudio(log) {
  const t0 = nowMs();
  await speak("probe", "设备探测短句。");
  const deadline = nowMs() + 20000;
  let settled = false, bad = false;
  while (nowMs() < deadline) {
    await log.poll(t0);
    if (log.grep(/AudioEngine 启动失败/, t0).length || log.grep(/drain 超时强制返回/, t0).length) { bad = true; break; }
    // 「播报收尾」出现 = 这条探测短句真的走完了设备（原先借「媒体控制: 恢复」判断，同因失效）
    if (log.grep(/播报收尾: 队列已空/, t0).length) { settled = true; break; }
    await sleep(200);
  }
  // 等收尾，避免污染后续窗口
  await waitSettled(log, t0, { timeout: 15000 });
  return settled && !bad;
}

async function main() {
  // 预检
  if (!existsSync(SOCKET)) {
    console.error(`✗ 找不到 socket ${SOCKET}，daemon 未运行？先 \`ivox on\``);
    process.exit(2);
  }
  await ensureDebugLogging();
  if (MANAGED) {
    console.log("# --managed: 重启 daemon ...");
    execFileSync(IVOX, ["on"], { stdio: "inherit" });
  }
  runnerLog = new LogTail();
  await runnerLog.baseline();

  let h;
  try { h = await waitReady(runnerLog); }
  catch (e) { console.error(`✗ 预检失败: ${e.message}`); process.exit(2); }

  const tRun = nowMs();
  console.log(`# iVox tts-check  run=${runId} daemon=${h.version} engine=${h.engine} model=${h.model}`);

  console.log("# 探测音频设备 ...");
  const hasAudio = await probeAudio(runnerLog);
  console.log(`# audio=${hasAudio ? "present" : "absent（播放时序用例将 skip）"}`);

  const picked = cases.filter((c) => !FILTER || FILTER.test(c.name));
  let n = 0;
  for (const c of picked) {
    n += 1;
    if (c.needsAudio && !hasAudio) {
      results.push({ name: c.name, status: "skip", ms: 0 });
      console.log(`ok ${n} ${c.name} # SKIP needs-audio`);
      continue;
    }
    const r = await runCase(c);
    let status = "ok";
    if (r.failures.length) status = r.advisory && !STRICT ? "advisory" : "not ok";
    if (status === "advisory" && r.interfered) status = "skip";
    // 外部播报干扰导致的失败降级为 skip（显式列出证据，仍算非产品问题）
    if (status === "not ok" && r.interfered) {
      console.log(`ok ${n} ${c.name} # SKIP 外部播报干扰（${r.interfered}）`);
      results.push({ name: c.name, status: "skip", ms: r.ms });
      continue;
    }
    r.status = status;
    results.push(r);
    if (status === "ok") {
      console.log(`ok ${n} ${c.name} (${(r.ms / 1000).toFixed(1)}s)`);
    } else if (status === "advisory") {
      console.log(`# advisory ${n} ${c.name} — ${r.failures.join("；")}`);
    } else {
      console.log(`not ok ${n} ${c.name} — ${r.failures.join("；")}`);
      if (r.window.length) console.log(r.window.slice(-25).join("\n"));
    }
  }

  // run 级致命扫描
  await runnerLog.poll(tRun);
  const fatalHits = RUN_FATAL.flatMap((re) => runnerLog.grep(re, tRun).map((l) => l.raw));
  if (fatalHits.length) {
    console.log(`# run 级致命日志 ${fatalHits.length} 条:\n${[...new Set(fatalHits)].slice(-10).join("\n")}`);
  }

  const pass = results.filter((r) => r.status === "ok").length;
  const fail = results.filter((r) => r.status === "not ok").length;
  const skip = results.filter((r) => r.status === "skip").length;
  const adv = results.filter((r) => r.status === "advisory").length;
  console.log(`# pass=${pass} fail=${fail} skip=${skip} advisory=${adv} duration=${((nowMs() - tRun) / 1000).toFixed(0)}s`);
  process.exit(fail > 0 || fatalHits.length > 0 ? 1 : 0);
}

// main 里用 process.exit 收尾，finally 不会执行，故挂在 exit 钩子上（同步清理）
process.on("exit", restoreLogEnv);

main().catch((e) => { console.error("✗ runner 崩溃:", e); process.exit(2); });
