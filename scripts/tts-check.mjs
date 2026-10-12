#!/usr/bin/env node
// iVox 播报黑盒自检：压真实 daemon，通过 Unix socket + HTTP /health + daemon.log 自动断言。
// 静音不出声（type:tts 只合成不播放拿 PCM 时长；播放链路只看管道收尾与日志），给退出码。
//
// 用法:
//   node scripts/tts-check.mjs                # 跑全部用例（附加到已在跑的 daemon）
//   node scripts/tts-check.mjs -f protocol    # 只跑名字匹配正则的用例
//   node scripts/tts-check.mjs --managed      # 自己 ivox off/on 起 daemon（退出时保持运行）
//   node scripts/tts-check.mjs --strict       # advisory 用例也计入失败
//
// 退出码: 0 全过(允许 skip) / 1 有失败或 run 级致命关键字 / 2 预检或用法错误
//
// 只依赖 node: 内置模块，零 npm 依赖。串行执行（暂停/恢复日志无 source，只能靠时间窗关联）。

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

async function quiet() {
  const s = await conn();
  s.end("__IVOX_STOP_PLAYBACK__");
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

// 等播放管道收尾：health 空闲 且 窗口内出现「媒体控制: 恢复」（双条件）
async function waitSettled(log, sinceTs, { timeout = 60000 } = {}) {
  const deadline = nowMs() + timeout;
  let resumedAt = 0;
  while (nowMs() < deadline) {
    await log.poll(sinceTs);
    if (!resumedAt) {
      const r = log.grep(/媒体控制: 恢复/, sinceTs).at(-1);
      if (r) resumedAt = r.ts;
    }
    const h = await health();
    if (resumedAt && h && h.queued === 0 && h.playing === false) {
      await sleep(300); // 日志落盘宽限
      return { resumedAt, h: await health() };
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
    quiet,
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
  return { name: c.name, advisory: !!c.advisory, needsAudio: !!c.needsAudio, failures: ctx.failures,
           window: ctx.failures.length ? ctx.windowLogs() : [], ms: nowMs() - t0 };
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
      const enq = ctx.log.grep(new RegExp(`流式入队: turn=${ctx.turn}`), ctx.t0);
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
      const after = ctx.log.grep(new RegExp(`流式入队: turn=${ctx.turn}`), cancel ? cancel.ts : ctx.t0);
      ctx.check(after.length === 0, "取消后仍有入队");
      // 取消轮会恢复音乐，等其收尾避免污染后续用例窗口
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
      const enq = ctx.log.grep(new RegExp(`流式入队: turn=${ctx.turn}`), ctx.t0);
      ctx.check(enq.length >= 1, "残尾未 flush 入队");
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
          await ctx.quiet();       // 中间插一次全局停止
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
      await ctx.quiet();
      await sleep(500);
      const tSpeak = nowMs();
      await ctx.speak("打断已结束，现在验证队列还能正常播报这一整句话。");
      const settled = await ctx.settled(60000);
      ctx.check(!!settled, "普通 speak 未收尾");
      // 完整生命周期有序：暂停 → 该 source 合成开始/完成 → 恢复
      const pause = ctx.log.grep(/媒体控制: 暂停/, tSpeak)[0];
      const synthStart = ctx.log.grep(new RegExp(`TTS 合成开始 \\[${ctx.source}`), tSpeak)[0];
      const resume = ctx.log.grep(/媒体控制: 恢复/, tSpeak).at(-1);
      ctx.check(pause && synthStart, "缺暂停或合成开始");
      ctx.check(resume && (!synthStart || resume.ts >= synthStart.ts), "恢复早于合成开始（生命周期错乱）");
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
      const tResume = settled?.resumedAt ?? 0;
      const gap = (tResume - tDone) / 1000;
      ctx.check(gap >= Math.max(0.8, tail.seconds * 0.5),
        `恢复过早，尾音可能被掐：合成完→恢复仅 ${gap.toFixed(2)}s，尾句音频 ${tail.seconds.toFixed(2)}s`);
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
];

// 无音频设备探测：发一短句，出现引擎启动失败/drain 超时即视为无设备
async function probeAudio(log) {
  const t0 = nowMs();
  await speak("probe", "设备探测短句。");
  const deadline = nowMs() + 20000;
  let resumed = false, bad = false;
  while (nowMs() < deadline) {
    await log.poll(t0);
    if (log.grep(/AudioEngine 启动失败/, t0).length || log.grep(/drain 超时强制返回/, t0).length) { bad = true; break; }
    if (log.grep(/媒体控制: 恢复/, t0).length) { resumed = true; break; }
    await sleep(200);
  }
  // 等收尾，避免污染后续窗口
  await waitSettled(log, t0, { timeout: 15000 });
  return resumed && !bad;
}

async function main() {
  // 预检
  if (!existsSync(SOCKET)) {
    console.error(`✗ 找不到 socket ${SOCKET}，daemon 未运行？先 \`ivox on\``);
    process.exit(2);
  }
  if (MANAGED) {
    console.log("# --managed: 重启 daemon ...");
    execFileSync(IVOX, ["restart"], { stdio: "inherit" });
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

main().catch((e) => { console.error("✗ runner 崩溃:", e); process.exit(2); });
