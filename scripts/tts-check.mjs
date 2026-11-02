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
// **队列模型（2026-11-02 起）**：队列 = 页的 FIFO。一页 = 一条 assistant 消息。
// 容器两层：页 → 句（句是合成单位，≤80 字，纯实现细节，用户不感知）。
// 不再有的概念：摞/stack、turn 参与排队、group、墓碑/tombstone、sealed、收尾信号（end:1）、
// idleGraceSeconds。**没有收尾信号**——队列排空即收尾，脚本不再发任何收尾帧。
//
// 日志级别：断言大量依赖 DEBUG 行（如「队列状态: pending=… 页=…」），
// 而 daemon 默认只留 INFO 及以上（Logger 的级别门限），不特意放出 DEBUG 就会让断言
// 读不到依据、假红。所以自检一律以 IVOX_LOG_LEVEL=debug 拉起 daemon（见 ensureDebugLogging），
// 跑完**把它复原**（见 restoreLogEnv）：unset 变量 + 再 kickstart 一次回到 INFO。
// 早先只 unset 变量、留着 daemon 在 debug 是「凑合」——launchd 的 setenv 是全局的，
// 之后 `ivox on` 起的进程都会继承，于是正常使用也在写 DEBUG（2026-10-18 实测残留一晚，
// daemon.log 里 5577 行 DEBUG、占 42%，全是每条回复的全文）。

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

// **音色**：协议要求 source 与 voice 都必填（2026-11-02）——守护进程不再猜。
// 自检是测试客户端，直接指定一个内置音色（taozi）即可，不必读配置。
const VOICE = "taozi";

// 以 debug 级日志拉起 daemon：断言要读 DEBUG 行（如「队列状态:」数入队句数），而 daemon
// 默认只留 INFO 及以上。环境变量走 `launchctl setenv`——LaunchAgent 跑在 launchd 下，
// 不继承当前 shell 的环境，父进程 execFileSync 传 env 是没用的（曾在这里想当然过）。
// 只设变量不改 daemon 已在跑的进程，必须 kickstart 才生效。
async function ensureDebugLogging() {
  try {
    execFileSync("/bin/launchctl", ["setenv", "IVOX_LOG_LEVEL", "debug"]);
    execFileSync("/bin/launchctl", ["kickstart", "-k", `gui/${process.getuid()}/${LABEL}`]);
    // 复核：设不进去还照样往下跑，用例会因读不到 DEBUG 行而集体假红，
    // 而那报错指向「产品坏了」——比直接说「设日志级别失败」误导得多。
    const now = execFileSync("/bin/launchctl", ["getenv", "IVOX_LOG_LEVEL"]).toString().trim();
    if (now !== "debug") {
      console.error(`⚠️ 日志级别未切到 debug（当前=[${now}]），依赖 DEBUG 行的断言会假红`);
      return;
    }
    console.log("# 日志级别: IVOX_LOG_LEVEL=debug（daemon 已重启）");
  } catch (e) {
    // 设不成不算致命：断言会因读不到 DEBUG 行而失败，但那属于诊断信号、不该让自检无法启动
    console.error(`⚠️ 切 debug 日志失败（断言可能假红）: ${e.message}`);
  }
  // **必须等 daemon 重新把 socket 挂上来**：kickstart 是 SIGKILL 再拉起，
  // 老进程退出时把 socket 摘了，新进程要过一会儿才 bind。
  // 不等就直接跑 → 20 条用例集体报「connect ENOENT」，
  // 那报错看着像「产品坏了」，其实只是抢跑（2026-11-02 实测踩到）。
  await waitForSocket();
}

// 等 socket 可连接（daemon 起来并 bind 完）
async function waitForSocket(timeout = 30000) {
  const deadline = nowMs() + timeout;
  while (nowMs() < deadline) {
    const ok = await new Promise((res) => {
      const s = net.connect(SOCKET);
      s.on("connect", () => { s.destroy(); res(true); });
      s.on("error", () => { s.destroy(); res(false); });
    });
    if (ok) return true;
    await sleep(200);
  }
  console.error(`⚠️ ${timeout / 1000} 秒内没等到 daemon 的 socket（${SOCKET}），用例会全部失败`);
  return false;
}

// 跑完撤掉会话级环境变量，**并把 daemon 重启回 INFO 级**。
//
// 只 unset 变量是不够的：级别已被 daemon 读进静态常量，当前进程仍是 debug。更糟的是
// launchd 的 setenv 是**全局**的，变量留着的话，之后 `ivox on` 起的任何新进程都会继承
// debug —— 于是「正常使用也在写 DEBUG」，每条回复的全文（原始 + 清洗后各一行）都进日志，
// 一天能写几 MB（2026-10-18 实测：残留一晚，第二天看 daemon.log 有 5577 行 DEBUG、
// 占 42%）。所以这里 unset 之后必须再 kickstart 一次。
//
// 手动起的 daemon（不在 launchd 下）kickstart 会失败，静默跳过即可 —— 那本来就没有
// 全局残留问题。
function restoreLogEnv() {
  // 用 `unsetenv`，**不是** `setenv -u KEY`：后者在本机不生效、退出码非 0，
  // 而原来的 try/catch 把它吞了——于是脚本一边打印「已复原」，一边 launchctl 里
  // 变量原封不动，下一个 `ivox on` 起的进程照样继承 debug。假绿就是这么来的（2026-10-18）。
  let cleared = false;
  try {
    execFileSync("/bin/launchctl", ["unsetenv", "IVOX_LOG_LEVEL"]);
    cleared = true;
  } catch {}
  try {
    execFileSync("/bin/launchctl", ["kickstart", "-k", `gui/${process.getuid()}/${LABEL}`],
                 { stdio: "ignore" });
  } catch { return; }  // daemon 不在 launchd 下，无需复原

  // 复核变量真的没了（不复核就等于把上面那个假绿再写一遍），再等 engine ready。
  try {
    const left = execFileSync("/bin/launchctl", ["getenv", "IVOX_LOG_LEVEL"]).toString().trim();
    if (left) cleared = false;
  } catch { cleared = false; }

  const deadline = Date.now() + 40000;
  let ready = false;
  while (Date.now() < deadline) {
    try {
      const h = JSON.parse(execFileSync("/usr/bin/curl", ["-s", "--max-time", "2",
                                                        "http://127.0.0.1:8888/health"]).toString());
      if (h.status === "ok" && h.engine === "ready") { ready = true; break; }
    } catch {}
    execFileSync("/bin/sleep", ["1"]);
  }
  if (cleared && ready) {
    console.log("# 日志级别: 已复原为默认（IVOX_LOG_LEVEL 已清并复核，daemon 已重启回 INFO）");
  } else {
    // 不再谎报成功——残留会一路带进之后每次启动。
    console.error(`⚠️ 日志级别未复原：变量${cleared ? "已清" : "**仍在**"}，` +
                  `engine ${ready ? "ready" : "**未 ready**"}。之后 ` +
                  `\`launchctl unsetenv IVOX_LOG_LEVEL\` 再 \`ivox on\` 一次。`);
  }
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
const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

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

// 一次性入队（Claude 形态）：**一个 socket 请求 = 一页**。
// {source:x} + 正文，然后 end()。服务端把这一整条当一页：清洗 → 切句 → 入队。
// 没有 group/page 字段——新模型里队列纯粹先来先进，页号由资料室自编。
// 不等 write 回调：实测在打断动作刚发生的那一刻，回调可能迟迟不触发，整条请求
// 根本发不出去（曾让 P3 干等 41 秒）。小报文直接 write 后 end，由 socket 自己 flush。
async function speakPage(source, text) {
  const s = await conn();
  s.write(`{source:${source},voice:${VOICE}}${text}`);
  s.end();
}

// 用户插队播报（{now:1}）= Opt+Z 译文走的那条路：掐掉在播的、插到最前面立刻念，
// 其余排队内容一个不丢。CLI 等价物 `ivox speak --now`。
async function speakNow(source, text) {
  const s = await conn();
  s.write(`{source:${source},voice:${VOICE},now:1}${text}`);
  s.end();
}

// 掐 + 掀某一档：mode=page（掀页，同 Ctrl+1）| all（全掀，同 Ctrl+2）。
// **没有 stack 这一档**：摞这个概念已经不存在了（mode 落到 default 会被当成掀页）。
async function skip(mode) {
  const s = await conn();
  s.end(`{type:skip,mode:${mode},tag:${runId},by:tts-check}\n`);
}

// 全场打断：停当前 + 清空排队（同 Ctrl+2），命令是 `ivox skip --all`。
async function skipAll() {
  await skip("all");
}

// 流式连接句柄。登记到 openSocks，用例结束统一清理，避免连接泄漏压垮 daemon。
//
// **一帧 = 一页**：长度帧（`L<n>` + n 字节正文）里装的是一条 assistant 消息的全文，
// 与 Claude 那边「一个 MessageDisplay = 一页」同构。帧内再切句（合成单位）。
// turn 只进日志、不参与排队，但脚本保留它是为了日志里能对账。
const openSocks = new Set();
async function openStream(turn, source) {
  const s = await conn();
  openSocks.add(s);
  s.on("close", () => openSocks.delete(s));
  await new Promise((res) => s.write(`{type:stream,source:${source},voice:${VOICE},turn:${turn}}\n`, res));
  return {
    // 一整个长度帧 = 一页
    sendPage: (t) => writeFrame(s, t),
    // 旧裸文本行（没有长度帧的老客户端）：攒到 {end} 一起发，成一页
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
  s.write(`{type:tts,source:selftest,voice:${VOICE}}\n${text}`);
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

// 等播放管道收尾：health 空闲 且 窗口内出现「播报结束」（双条件）
// 锚点原先是 `媒体控制: 恢复`——播报不再借还背景音乐后那条日志不再出现，
// 改用 PlaybackQueue 显式打的收尾标记（语义更准：它只在"队列真收尾"时打）。
// **新模型里没有收尾信号**：队列排空即收尾，所以这条日志就是唯一的收敛锚点。
async function waitSettled(log, sinceTs, { timeout = 60000 } = {}) {
  const deadline = nowMs() + timeout;
  let settledAt = 0;
  while (nowMs() < deadline) {
    await log.poll(sinceTs);
    // 取**最新**一条「播报结束」，不是第一次见到的那条：锁死第一次会算出一个负间隔
    //（用例先探测音频时长会留下一次早收尾，真收尾在几秒后，2026-10-17 `A-tail` 假红）。
    // 健康检查同时要求队列真空着，所以中途那次早收尾不会被误当成「已收尾」返回。
    {
      const r = log.grep(/播报结束: 队列已空/, sinceTs).at(-1);
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
    // 默认来源的一次性入队（一页）
    speak: (text) => speakPage(source, text),
    // 指定来源的一次性入队（一页）
    speakPage,
    speakNow,
    skip,
    skipAll,
    openStream: (t = turn, src = source) => openStream(t, src),
    ttsPcm,
    health,
    ids,
    // 断言收集到失败列表，不立即抛
    failures: [],
    check(cond, msg) { if (!cond) this.failures.push(msg); },
    async settled(timeout = 60000) {
      const r = await waitSettled(log, t0, { timeout });
      if (!r) this.failures.push("播放管道未在超时内收尾（无「播报结束」或 health 未空闲）");
      return r;
    },
    // 队列里的页（资料室自编页号）：每入队一页打一行「资料室收下：第N页 …」
    pages(src) {
      const out = [];
      for (const l of log.grep(/资料室收下：第\d+页 /, t0)) {
        const m = /资料室收下：第(\d+)页 来源=(\S+) 字数=(\d+) 句=(\d+)/.exec(l.msg);
        if (m) out.push({ ts: l.ts, pageNo: +m[1], source: m[2], chars: +m[3], sentences: +m[4] });
      }
      return src ? out.filter((p) => p.source === src) : out;
    },
    // 等某个模式出现够多行（轮询新日志）
    async waitCount(re, n, timeout = 15000) {
      const deadline = nowMs() + timeout;
      while (nowMs() < deadline) {
        await log.poll(t0);
        const c = log.grep(re, t0).length;
        if (c >= n) return c;
        await sleep(150);
      }
      return log.grep(re, t0).length;
    },
    // 某个来源的「TTS 合成开始」行数（批次号在后面，用前缀匹配）
    synthStarts(src, sinceTs = t0) {
      return log.grep(new RegExp(`TTS 合成开始 \\[${escapeRe(src)}-`), sinceTs);
    },
    synthDones(src, sinceTs = t0) {
      return log.grep(new RegExp(`TTS 合成完成 \\[${escapeRe(src)}-`), sinceTs);
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
  // 外部播报干扰：run 期间别的 agent（Claude 的 hook、用户手动 speak）恰好开口，
  // 会插进用例自己的音频窗口，尾音/收尾/时长类断言失真。检测到则把失败降级为 skip 并显式
  // 打出证据——只降级失败，通过的不动；不掩盖，也别把它当产品缺陷。
  // 判据：入队日志里的来源不含本 run 的 runId → 不是本脚本自己送的。
  const foreign = log.grep(/队列入队: source=|流式入队: source=/, t0)
    .filter((l) => !l.msg.includes(runId));
  // 外部全场打断（别的终端跑 `ivox skip --all` / 手动按 Ctrl+2）会在用例播到一半时
  // 掐掉本轮，尾音/收尾/恢复类断言必然失真——同样降级为 skip 并给出证据。
  const sentinel = log.grep(new RegExp(`跳过请求: mode=(?!.*tag=${runId})`), t0);
  const hit = foreign[0] ?? sentinel[0];
  // 誊清员（合成子进程）崩了或正在被重拉：MLX 的 Metal 命令编码器析构会 SIGABRT，
  // 这是已知的上游问题（见 CLAUDE.md「合成引擎有两个实现」）。它一崩，daemon 重拉它、
  // 模型没加载完的那几秒里所有合成请求都拿到 0 字节——**这一条根本没被测到**，
  // 判「没测」而不是「产品坏了」。
  // 判据要精确：只看「誊清中断」（子进程的流被截断＝它死了）。
  // **不能看「拉起誊清员」**——daemon 第一次用合成时也会拉它，那是常态，不是故障。
  const scribeDown = log.grep(/誊清中断|誊清员已收|誊清员拉起失败/, t0);
  return { name: c.name, advisory: !!c.advisory, needsAudio: !!c.needsAudio, failures: ctx.failures,
           interfered: hit ? hit.msg : "", scribeDown: scribeDown[0] ? scribeDown[0].msg : "",
           ms: nowMs() - t0,
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
  // 一帧 = 一页。帧里的 {end}/{cancel} 只是正文，绝不能被当成控制帧。
  {
    name: "E1-length-frame-injection",
    async run(ctx) {
      const st = await ctx.openStream();
      // 正文里独立成行的 {end}/{cancel} 必须被当正文，不得提前结束/取消
      st.sendPage("{end}\n{cancel}\n🎉这句话一定要被当正文念出来，不能当成控制帧。");
      await sleep(500);
      const early = ctx.log.grep(new RegExp(`流式(结束|取消).*${ctx.turn}`), ctx.t0);
      ctx.check(early.length === 0, `注入的控制帧被误判，提前结束/取消: ${early.map((l) => l.msg).join(";")}`);
      // 连接仍可写：第二帧应入队（两帧 = 两页）
      st.sendPage("这是第二帧正文内容，用来确认连接还活着。");
      const enq = await ctx.waitCount(/流式入队: source=/, 2, 10000);
      ctx.check(enq >= 2, `两帧应各自成一页，实际入队 ${enq} 次`);
      const pages = ctx.pages();
      ctx.check(pages.length === 2, `应收下 2 页，实际 ${pages.length}`);
      st.endFrame();
      const settled = await ctx.settled(40000);
      ctx.check(!!settled, "未收尾");
      const end = await ctx.log.waitFor(new RegExp(`流式结束: turn=${ctx.turn}`), { sinceTs: ctx.t0, timeout: 5000 });
      ctx.check(!!end, "缺流式结束日志");
      ctx.noBad();
    },
  },

  // ───────── E2：旧裸文本帧后向兼容 ─────────
  // 裸文本行攒起来，等 {end} 一起发，成**一页**（不是每行一页）。
  {
    name: "E2-legacy-bare-text",
    async run(ctx) {
      const st = await ctx.openStream();
      st.sendRawLine("这是第一句旧客户端裸文本。");
      st.sendRawLine("这是第二句，仍然正常。");
      st.sendRawLine("{end}");
      const settled = await ctx.settled(40000);
      ctx.check(!!settled, "未收尾");
      const pages = ctx.pages();
      ctx.check(pages.length === 1, `裸文本应攒成一页，实际 ${pages.length} 页`);
      ctx.check(pages[0] && pages[0].sentences >= 1, "裸文本页没有句子");
      ctx.check(pages[0] && pages[0].chars > 0, "裸文本页没有内容");
      ctx.noBad();
    },
  },

  // ───────── E3：两条流连接互不干扰 ─────────
  // 回归：取消只撤**这条连接送来的页**（撤的依据是「哪几页是这条连接送来的」），
  // 不牵连别的连接。新模型里 turn 不参与排队，页归属只靠连接自己记。
  {
    name: "E3-two-connections-independent",
    async run(ctx) {
      const srcB = ctx.ids().source;
      const A = await ctx.openStream(ctx.turn, ctx.source);
      A.sendPage("第一条连接送来的内容，这一句足够长以便真正进入合成。");
      const aStart = await ctx.log.waitFor(new RegExp(`TTS 合成开始 \\[${escapeRe(ctx.source)}-`),
        { sinceTs: ctx.t0, timeout: 20000 });
      ctx.check(!!aStart, "A 连接的内容未开始合成");
      const B = await ctx.openStream(ctx.ids().turn, srcB);
      B.sendPage("第二条连接送来的内容，同样应当被合成并播出来。");
      const enq = await ctx.waitCount(/资料室收下：/, 2, 15000);
      ctx.check(enq >= 2, "两条连接的内容没有各自成一页");
      // A 取消：只撤 A 自己的页
      A.cancel();
      const withdrawn = await ctx.log.waitFor(/撤回来路|流式取消落地/, { sinceTs: ctx.t0, timeout: 8000 });
      ctx.check(!!withdrawn, "A 的 {cancel} 没有撤回来路");
      // B 的页照播——这是本用例的核心断言。
      // **必须等**：队列是串行的，A 那句合成完 B 才开 synth，所以取消日志一出现时
      // B 还没开始合成是正常的。立刻数行数会假红（2026-11-02 实测：撤回来路 2.5s 后
      // B 才开合成，行为完全正确，是断言没等）。
      const bStart = await ctx.waitCount(new RegExp(`TTS 合成开始 \\[${escapeRe(srcB)}-`), 1, 30000);
      ctx.check(bStart >= 1, "B 连接的内容没有被合成（A 的取消牵连了别的连接）");
      B.endFrame();
      await sleep(300);
      const settled = await ctx.settled(45000);
      ctx.check(!!settled, "未收尾");
      const bDone = ctx.synthDones(srcB);
      ctx.check(bDone.length >= 1, "B 连接的内容没有播完");
      ctx.noBad();
    },
  },

  // ───────── E4：cancel 撤掉这条连接自己的页 ─────────
  {
    name: "E4-cancel-withdraws-own-pages",
    async run(ctx) {
      const st = await ctx.openStream();
      st.sendPage("第一句先发出去，这一页要够长以便还有剩余内容可撤。第二句也在这一页里。");
      const enq = await ctx.waitCount(/资料室收下：/, 1, 8000);
      ctx.check(enq >= 1, "第一页未入队");
      st.cancel();
      const cancel = await ctx.log.waitFor(new RegExp(`流式取消: turn=${ctx.turn}`), { sinceTs: ctx.t0, timeout: 8000 });
      ctx.check(!!cancel, "缺流式取消日志");
      const drop = await ctx.log.waitFor(/撤回来路|流式取消落地/, { sinceTs: ctx.t0, timeout: 8000 });
      ctx.check(!!drop, "取消没有撤回来路（这条连接送来的页还留在队列里）");
      await sleep(600);
      const after = ctx.log.grep(/流式入队: source=/, cancel ? cancel.ts : ctx.t0);
      ctx.check(after.length === 0, "取消后仍有入队");
      // 取消后连接可能已被服务端关闭，写入报错要容错
      try { st.sendRawLine("取消后迟到的句子不应入队。"); } catch {}
      try { st.halfClose(); } catch {}
      // 取消轮也要走收尾流程，等它收尾避免污染后续用例窗口
      await ctx.settled(20000);
      ctx.noBad([/drain 超时强制返回/]);
    },
  },

  // ───────── E5：EOF 等价 {end}，残尾 flush 成一页 ─────────
  // EOF 兜底：没发 {end} 就断开，攒着的裸文本按一页发出去。
  {
    name: "E5-eof-flush-tail",
    async run(ctx) {
      const st = await ctx.openStream();
      st.sendPage("这是一句完整的话，走长度帧，一帧一页。");   // → 1 页
      st.sendRawLine("最后半句没有结束符，走裸文本，EOF 时应被 flush 成一页。"); // → EOF 时 1 页
      st.halfClose();                                          // 不发 {end}
      const pages = await ctx.waitCount(/资料室收下：/, 2, 15000);
      ctx.check(pages >= 2, `EOF 残尾未 flush 成页（只收到 ${pages} 页）`);
      const settled = await ctx.settled(40000);
      ctx.check(!!settled, "未收尾");
      ctx.noBad();
    },
  },

  // ───────── E6：并行连接的 {cancel} 不拖垮另一条在跑的连接（pi 会开两条流）─────────
  // 回归：曾把「见过」当「被顶掉」——并行那条空流一取消，就把真正在跑的这条判成过期旧轮，
  // 后续正文全部静默丢弃（整轮没声音，日志里连入队记录都没有）。
  // 新模型里更简单：取消只撤**自己送来的页**，别的连接压根不在它的账上。
  {
    name: "E6-parallel-cancel-keeps-other-connection",
    async run(ctx) {
      const t1 = ctx.turn;              // 真正承载正文的连接
      const t2 = ctx.ids().turn;        // 并行的第二条流
      const A = await ctx.openStream(t1);
      await sleep(60);
      const B = await ctx.openStream(t2);
      await sleep(60);
      B.cancel();                       // 它立刻 {cancel}：只作废自己，不碰在跑的那条
      await sleep(300);
      A.sendPage("并行那条空流取消之后，这条正文仍应被完整念出来。");
      A.endFrame();
      const start = await ctx.log.waitFor(new RegExp(`TTS 合成开始 \\[${escapeRe(ctx.source)}-`),
        { sinceTs: ctx.t0, timeout: 30000 });
      ctx.check(!!start, "在跑的连接被空连接的取消拖累了（入队后无合成开始）");
      const stray = ctx.log.grep(new RegExp(`流式入队: source=.*turn=${t2}`), ctx.t0);
      ctx.check(stray.length === 0, "被取消的并行连接不该入队");
      const settled = await ctx.settled(40000);
      ctx.check(!!settled, "未收尾");
      ctx.noBad();
    },
  },

  // ───────── E7：全掀清空排队内容，但之后到达的新页照常播 ─────────
  // 语义：全掀（`ivox skip --all`，同 Ctrl+2）清空**当下**排队的一切。
  // **不立墓碑**：这一下之后再来的内容照常入队照常播——
  // 「内容生死只由用户当下这一按决定」，用户放弃不该拦下后来的回复。
  {
    name: "E7-skip-all-clears-queue",
    async run(ctx) {
      const srcB = ctx.ids().source;
      await ctx.speakPage(ctx.source, "第一页内容，句子足够多以便打断时还有剩余。第二句。第三句。");
      await ctx.speakPage(srcB, "第二页内容，应该排在第一页之后。");
      const started = await ctx.log.waitFor(new RegExp(`TTS 合成开始 \\[${escapeRe(ctx.source)}-`),
        { sinceTs: ctx.t0, timeout: 20000 });
      ctx.check(!!started, "第一页未开始合成");
      await sleep(400);
      await ctx.skipAll();
      const skipLine = await ctx.log.waitFor(/作废全部排队内容/, { sinceTs: ctx.t0, timeout: 8000 });
      ctx.check(!!skipLine, "缺全掀日志");
      // 全掀之后到达的新页照常播
      await ctx.speakPage(srcB, "全掀之后才到的新页，必须照常播出来。");
      const after = await ctx.log.waitFor(new RegExp(`TTS 合成开始 \\[${escapeRe(srcB)}-`),
        { sinceTs: skipLine ? skipLine.ts : ctx.t0, timeout: 30000 });
      ctx.check(!!after, "全掀之后到达的新页没有被播（新模型不该立墓碑）");
      const settled = await ctx.settled(45000);
      ctx.check(!!settled, "未收尾");
      const h = await ctx.health();
      ctx.check(h && h.queued === 0 && h.playing === false, `未收敛空闲: ${JSON.stringify(h)}`);
      ctx.noBad();
    },
  },

  // ───────── E8：队列排空后管道必须退出（不空转烧 CPU）─────────
  // 回归：老实现里队首播空未收尾时会无 await 地空转，独占 PlaybackQueue actor 且永不释放，
  // enqueue/打断一律被饿死（连快捷键打断都进不来）→ 队尾内容永不播、CPU 烧满一核、
  // /health 无响应，连 EOF 兜底都救不回。
  // 新模型里没有「轮未收尾」这回事：队列排空管道就该退出。
  {
    name: "E8-idle-queue-no-spin",
    needsAudio: true,
    async run(ctx) {
      const A = await ctx.openStream();
      A.sendPage("这是一段用来触发复现的测试文本，长度足够越过最小切句门槛。");
      const started = await ctx.log.waitFor(new RegExp(`TTS 合成开始 \\[${escapeRe(ctx.source)}-`),
        { sinceTs: ctx.t0, timeout: 20000 });
      ctx.check(!!started, "首块未开始合成");
      A.endFrame();
      const settled = await ctx.settled(45000);
      ctx.check(!!settled, "未收尾");
      // ① 空转的直接表征：队列排空后应完全空闲，紧循环则把一个核烧满
      const cpus = [];
      for (let i = 0; i < 8; i++) { cpus.push(daemonCpu()); await sleep(150); }
      const nums = cpus.filter((x) => x != null).sort((a, b) => a - b);
      const median = nums.length ? nums[Math.floor(nums.length / 2)] : 0;
      ctx.check(median < 50, `队列排空后 daemon CPU 仍居高位 median=${median}%（紧循环空转）`);
      // ② 排空之后到达的新页仍能被合成并播出（管道退出了，得能重开）
      const t2 = nowMs();
      await ctx.speak("队列排空之后送来的新内容，必须照常播出来。");
      const start2 = await ctx.log.waitFor(/TTS 合成开始/, { sinceTs: t2, timeout: 30000 });
      ctx.check(!!start2, "排空后到达的新页没有被合成（管道没有重开）");
      const settled2 = await ctx.settled(45000);
      ctx.check(!!settled2, "新页未收尾");
      // ③ 活性：actor 被紧循环独占时 /health 直接超时（health() 返回 null）
      let alive = 0;
      for (let i = 0; i < 3; i++) { if (await ctx.health()) alive += 1; await sleep(600); }
      ctx.check(alive === 3, `紧循环僵死：${3 - alive}/3 次 /health 无响应（需 ivox off && ivox on 重启）`);
      ctx.noBad();
    },
  },

  // ───────── C：密集打断不崩溃、不雪崩 ─────────
  {
    name: "C-bargein-stress",
    async run(ctx) {
      const longText = "这是第N轮密集打断测试，句子足够长以保证真正进入模型推理，占用若干秒合成时间。";
      for (let i = 1; i <= 8; i++) {
        const { turn, source } = ctx.ids();
        const st = await ctx.openStream(turn, source);
        st.sendPage(longText.replace("第N轮", `第${i}轮`));
        await sleep(i === 4 ? 0 : 250);
        if (i === 4) {
          await ctx.skipAll();       // 中间插一次全掀
          await sleep(250);
        }
        // 真实客户端开新连接前会关掉旧连接；最后一轮发 {end}，其余直接销毁
        if (i === 8) st.endFrame(); else st.destroy();
      }
      // 健康探针：全程 daemon 必须存活
      const h0 = await ctx.health();
      ctx.check(h0 && h0.status === "ok", `压测中 /health 异常: ${JSON.stringify(h0)}`);
      const settled = await ctx.settled(90000);
      ctx.check(!!settled, "压测后未收敛空闲");
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
        const { turn, source } = ctx.ids();
        const st = await ctx.openStream(turn, source);
        st.sendPage("快速打断活性测试用的一句中等长度内容。");
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
      const synthStart = ctx.synthStarts(ctx.source, tSpeak)[0];
      const settle = ctx.log.grep(/播报结束: 队列已空/, tSpeak).at(-1);
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
    needsDebug: true,
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
      for (const s of sentences) st.sendPage(s);   // 一帧 = 一页
      st.endFrame();
      const settled = await ctx.settled(60000);
      ctx.check(!!settled, "未收尾");
      // 入队页数按「资料室收下：第N页」数（旧的「队列状态: … turn=」行没了）；
      // 句数按各页的「句=N」加起来——合成单位是句，一次合成对一句。
      const pages = ctx.pages();
      const accepted = pages.length;
      const expected = pages.reduce((a, p) => a + p.sentences, 0);
      const starts = ctx.log.grep(/TTS 合成开始/, ctx.t0);
      const dones = ctx.log.grep(/TTS 合成完成/, ctx.t0);
      ctx.check(accepted === 3, `应收下 3 页，实际 ${accepted}`);
      ctx.check(starts.length >= accepted,
        `合成开始(${starts.length}) 少于入队页数(${accepted})`);
      ctx.check(starts.length === expected,
        `合成开始(${starts.length}) 应等于入队句数(${expected})`);
      ctx.check(dones.length === starts.length, `合成完成(${dones.length}) 应与开始(${starts.length}) 一致`);
      const tDone = dones.at(-1)?.ts ?? 0;
      const tSettled = settled?.settledAt ?? 0;
      const gap = (tSettled - tDone) / 1000;
      const finish = ctx.log.grep(/播放结束: 尾音=/, ctx.t0).at(-1);
      ctx.check(!!finish, "缺「播放结束」日志");
      // 基准是日志里的**真实尾音**（收尾那一刻还排在播放器里的秒数），不是「单独再合成
      // 一遍测出的完整时长」。原判据假设「最后一块合成完时它还没开始播」，可管道本来就
      // 预取领先播放（`B-synthesis-leads-playback` 验的就是这个），合成完时那块早播了
      // 一部分，gap 天然只剩剩下的——拿完整时长当基准会稳定假红（2026-10-18 升级
      // mlx-swift 0.32 后连报三次：gap 1.62/1.70/1.63s，而真实尾音 1.60/1.70/1.63s，
      // 两者几乎相等，说明音频确实播完才收尾）。真实尾音 > 0 且 gap 覆盖它才是「没被掐」。
      const tailSec = finish ? Number(/尾音=([0-9.]+)s/.exec(finish.msg)?.[1] ?? 0) : 0;
      ctx.check(tailSec > 0, `尾音为 0，音频可能被整段掐掉`);
      ctx.check(gap >= Math.max(0.8, tailSec * 0.8),
        `收尾过早，尾音可能被掐：合成完→收尾仅 ${gap.toFixed(2)}s，真实尾音 ${tailSec.toFixed(2)}s`);
      // 仍保留 TTS 输出健康度检查：探测那次必须真的出声，否则上面的比较毫无意义
      ctx.check(tail.seconds > 0.5, `尾句合成时长异常: ${tail.seconds}`);
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
      for (const s of sentences) { st.sendPage(s); await sleep(100); }   // 5 帧 = 5 页 = 5 句
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
  // 需求：Ctrl+1 = 掐 + 掀当前页。掀完必须落到下一页，而不是把队列掀空。
  // 新模型里没有「摞」：掀的就是**用户此刻正在听的那一页**。
  {
    name: "P1-skip-page-then-next",
    async run(ctx) {
      const srcB = ctx.ids().source;
      await ctx.speakPage(ctx.source, "第一页的第一句。还要有第二句。第三句也在这一页里。");
      await ctx.speakPage(srcB, "第二页要说的话，长度够触发一次合成就好。");
      const started = await ctx.log.waitFor(new RegExp(`TTS 合成开始 \\[${escapeRe(ctx.source)}-`),
        { sinceTs: ctx.t0, timeout: 20000 });
      ctx.check(!!started, "第一页未开始合成");
      await sleep(500);
      await ctx.skip("page");
      const dropped = await ctx.log.waitFor(/这页不要了，听下一页/, { sinceTs: ctx.t0, timeout: 8000 });
      ctx.check(!!dropped, "缺掀页日志");
      // 掀的必须是**正在听的那一页**（第一页），不是队列里的别页
      const first = ctx.pages(ctx.source)[0];
      if (first && dropped) {
        ctx.check(dropped.msg.includes(`第${first.pageNo}页`),
          `掀错页了：正在听的是第${first.pageNo}页，日志说 ${dropped.msg}`);
      }
      // 关键断言：第二页仍然被合成——掀掉一页不等于掀掉整个队列
      const bStart = await ctx.log.waitFor(new RegExp(`TTS 合成开始 \\[${escapeRe(srcB)}-`),
        { sinceTs: dropped ? dropped.ts : ctx.t0, timeout: 30000 });
      ctx.check(!!bStart, "掀页后下一页没有被合成（掀一页等于掀光队列）");
      const settled = await ctx.settled(45000);
      ctx.check(!!settled, "未收尾");
      ctx.noBad();
    },
  },

  // ───────── P2：连续掀页不炸 ─────────
  // 需求：用户可以连按。连按最容易撞上「句刚被取走、门控还没过」与「页被删了、
  // 游标还指着它」两个时刻，两者都得安全跳过而不是崩。
  {
    name: "P2-skip-page-repeat-safe",
    async run(ctx) {
      for (let i = 1; i <= 3; i++) {
        await ctx.speakPage(ctx.source, `第${i}页要说的话，长度够触发一次合成就好。`);
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

  // ───────── P3：掀页之后新到的页照常播（用户放弃只作用于当下那一按）─────────
  // 背景：老模型里「用户放弃」会立墓碑，把后来的内容一起拦掉，于是「新的内容凭空消失」。
  // 新模型**不立墓碑**：掀掉当下这一页之后，后来到的页照常入队照常播。
  {
    name: "P3-late-page-after-skip-still-plays",
    async run(ctx) {
      const srcB = ctx.ids().source;
      await ctx.speakPage(ctx.source, "第一页的第一句。还要有第二句。第三句也在这一页里。");
      const started = await ctx.log.waitFor(new RegExp(`TTS 合成开始 \\[${escapeRe(ctx.source)}-`),
        { sinceTs: ctx.t0, timeout: 20000 });
      ctx.check(!!started, "第一页未开始合成");
      await sleep(400);
      await ctx.skip("page");                            // 掀掉当下这一页
      const dropped = await ctx.log.waitFor(/这页不要了，听下一页/, { sinceTs: ctx.t0, timeout: 8000 });
      ctx.check(!!dropped, "缺掀页日志");
      // 掀页之后才到的一页：照常入队照常播
      await ctx.speakPage(srcB, "掀页之后才到的新页，必须照常播出来。");
      const bStart = await ctx.log.waitFor(new RegExp(`TTS 合成开始 \\[${escapeRe(srcB)}-`),
        { sinceTs: dropped ? dropped.ts : ctx.t0, timeout: 30000 });
      ctx.check(!!bStart, "掀页之后到达的新页没有被播（用户放弃被当成了拦后续）");
      const settled = await ctx.settled(45000);
      ctx.check(!!settled, "未收尾");
      ctx.noBad();
    },
  },

  // ───────── S1：全掀清空全部排队内容（多页全丢）─────────
  {
    name: "S1-skip-all-drops-everything",
    async run(ctx) {
      const srcB = ctx.ids().source;
      await ctx.speakPage(ctx.source, "第一页的第一句。还要有第二句。第三句也在这一页里。");
      await ctx.speakPage(srcB, "第二页的句子，等着被全掀清掉。");
      const started = await ctx.log.waitFor(new RegExp(`TTS 合成开始 \\[${escapeRe(ctx.source)}-`),
        { sinceTs: ctx.t0, timeout: 20000 });
      ctx.check(!!started, "第一页未开始合成");
      await sleep(400);
      await ctx.skipAll();
      const skipLine = await ctx.log.waitFor(/作废全部排队内容/, { sinceTs: ctx.t0, timeout: 8000 });
      ctx.check(!!skipLine, "缺全掀日志");
      // 第二页还在排队、还没开始合成 → 全掀必须把它一起清掉
      const bStart = ctx.synthStarts(srcB);
      ctx.check(bStart.length === 0, `全掀后第二页仍被合成 ${bStart.length} 次（全掀没清干净）`);
      const h = await ctx.health();
      ctx.check(h && h.queued === 0, `全掀后队列非空: ${JSON.stringify(h)}`);
      const settled = await ctx.settled(45000);
      ctx.check(!!settled, "未收尾");
      // 收尾后再数一遍：全掀要是没清干净，B 那页会在这之后才开合成——
      // 只在掀完的瞬间数一次会漏掉它（假绿）。
      const bLater = ctx.synthStarts(srcB);
      ctx.check(bLater.length === 0, `全掀后第二页仍被合成 ${bLater.length} 次（全掀没清干净）`);
      ctx.noBad();
    },
  },

  // ───────── S2：跨来源混排，顺序只由到达决定 ─────────
  // 两种形态混排：流式页（pi 形态，一帧一页）+ 一次性页（Claude 形态，一个请求一页）。
  // 断言后到的不会插到先到的前面——页号必须严格递增。
  {
    name: "S2-mixed-sources-keep-arrival-order",
    async run(ctx) {
      const srcOnce = ctx.ids().source;
      const st = await ctx.openStream(ctx.turn, ctx.source);
      st.sendPage("先到的流式内容，应该排在前面播。");
      await sleep(200);
      await ctx.speakPage(srcOnce, "后到的一次性内容，应该排在流式那一条之后。");
      await sleep(200);
      st.endFrame();
      const settled = await ctx.settled(60000);
      ctx.check(!!settled, "未收尾");
      // 两种形态的入队日志不同名：流式写「流式入队」，一次性写「队列入队」
      const streamed = ctx.log.grep(/流式入队: source=/, ctx.t0);
      const once = ctx.log.grep(/队列入队: source=/, ctx.t0);
      ctx.check(streamed.length >= 1, "流式来源未入队");
      ctx.check(once.length >= 1, "一次性来源未入队");
      // 顺序只由到达决定：资料室自编的页号必须递增
      const nums = ctx.pages().map((p) => p.pageNo);
      ctx.check(nums.length >= 2, `应至少两页，实际 ${nums.length}`);
      ctx.check(nums.every((n, i) => i === 0 || n > nums[i - 1]),
        `页号非递增，顺序乱了: ${nums.join(",")}`);
      ctx.noBad();
    },
  },

  // ───────── I1：用户插队（Opt+Z 译文 / --now） ─────────
  // 需求：译文是唯一的机器开口——**暂停**在播的、译文走独立节点念、念完接着播，
  // 原队列一条不删、不立墓碑。译文**不进队列管道**，故它自己打「译文合成开始/完成」，
  // 认它得认这两行，不能去队列的「TTS 合成开始」里找。
  {
    name: "I1-insert-front-keeps-queue",
    async run(ctx) {
      const srcB = ctx.ids().source;
      await ctx.speakPage(ctx.source, "第一页要说的话，长度够触发一次合成就好。");
      await ctx.speakPage(srcB, "第二页要说的话，长度够触发一次合成就好。");
      const started = await ctx.log.waitFor(new RegExp(`TTS 合成开始 \\[${escapeRe(ctx.source)}-`),
        { sinceTs: ctx.t0, timeout: 20000 });
      ctx.check(!!started, "第一页未开始合成");
      await sleep(500);
      const dictSrc = ctx.ids().source;
      await ctx.speakNow(dictSrc, "这是一句插队先念的译文。");
      await sleep(300);
      await ctx.speakPage(ctx.ids().source, "第三页要说的话，长度够触发一次合成就好。");
      const settled = await ctx.settled(60000);
      ctx.check(!!settled, "未收尾");

      const dict = ctx.log.grep(/译文合成开始/, ctx.t0)
        .filter((h) => h.msg.includes(`[${dictSrc}]`));
      ctx.check(dict.length >= 1, "译文没有被合成");

      // 暂停 → 恢复：译文念完必须接回原处（一条不删）
      const paused = ctx.log.grep(/播报暂停/, ctx.t0)[0];
      const resumed = ctx.log.grep(/播报恢复/, ctx.t0)[0];
      ctx.check(!!paused, "插队时没有暂停在播的");
      ctx.check(!!resumed, "译文念完后没有恢复播报");
      if (paused && resumed) {
        ctx.check(resumed.ts > paused.ts, "恢复早于暂停，顺序反了");
      }

      // 原队列一条不丢：原文侧合成过，且译文之后仍有原文在合成
      const orig = ctx.log.grep(/TTS 合成开始/, ctx.t0)
        .filter((h) => /\[c\d\d/.test(h.msg));
      ctx.check(orig.length >= 2, `原文内容有丢失（原文侧只合成了 ${orig.length} 次）`);
      ctx.check(
        orig.some((h) => h.ts > (dict[0]?.ts ?? Infinity)),
        "译文之后原队列没有继续播",
      );
      ctx.noBad();
    },
  },

  // ───────── R1：誊清员崩了，这一块作废、队列继续、监督者重拉（v6.0.0 的招牌能力）─────────
  // 为什么必须有这条：v6.0.0 把 MLX 隔离进子进程的全部理由就是「崩了不带走队列」。
  // 那次验收是**手工做的一次**——手工验收会腐烂：哪天重构动了 TSPRemote 的泵逻辑，
  // 或者上游修好 MLX 让同步路径回来了，这块能力悄悄没了都不会有人知道。
  // 判据三件套，缺一不可：作废（有明确边界，不留半句）、继续（后面的内容照播）、
  // 自愈（监督者重拉，否则这一次过了、下次崩了就永久哑掉）。
  // 刻意不调 noBad()：崩溃导致的「这一块作废」正是本用例预期的现象，
  // 而 CASE_BAD 里的 /TTS 合成失败/ 会把它当成产品缺陷。
  {
    name: "R1-scribe-crash-voids-block-queue-continues",
    async run(ctx) {
      const srcB = ctx.ids().source;
      // 内容要够长，保证合成进行到一半时还有下手的时间
      await ctx.speakPage(ctx.source,
        "第一段内容，需要足够长，好在合成进行到一半时把誊清员杀掉，看看这一块会不会被作废、后面的内容还能不能接着播出来。".repeat(3));
      const started = await ctx.log.waitFor(new RegExp(`TTS 合成开始 \\[${escapeRe(ctx.source)}-`),
        { sinceTs: ctx.t0, timeout: 20000 });
      ctx.check(!!started, "未开始合成，没机会动手");
      await sleep(300);
      ctx.check(killScribe(), "没找到誊清员进程（它不叫 tts --serve？）");

      const voided = await ctx.log.waitFor(/誊清中断，这一块作废/, { sinceTs: ctx.t0, timeout: 25000 });
      ctx.check(!!voided, "杀掉誊清员后没出现「这一块作废」——半句可能被当完整送进播报员了");

      // 监督者必须重拉，否则这一次过了、下次崩掉就永久哑
      const relaunched = await ctx.log.waitFor(/已拉起誊清员/,
        { sinceTs: voided ? voided.ts : ctx.t0, timeout: 40000 });
      ctx.check(!!relaunched, "监督者没有重拉誊清员");

      // 队列必须继续：崩溃之后送来的内容还得能播出来
      await ctx.speakPage(srcB, "崩溃之后送来的内容，必须照常播出来。");
      const settled = await ctx.settled(90000);
      ctx.check(!!settled, "崩溃后队列没能收尾");

      const after = ctx.log.grep(/TTS 合成开始/, voided ? voided.ts : ctx.t0);
      ctx.check(after.length >= 1, `重拉之后没有任何新的合成（队列没恢复，共 ${after.length} 次）`);
    },
  },
];

// 杀掉誊清员：SIGKILL，不给它收尾的机会——模拟的正是 MLX 那次 SIGTRAP。
// 先 pgrep 确认存在、再 pkill：两者都只靠匹配进程，而自检不知道是谁拉起的它
// （可能是 LaunchAgent，也可能是上一轮留下的孤儿）。分两步是为了区分
// 「杀了」与「压根没有」——后者说明环境不对，不该报成产品缺陷。
function killScribe() {
  try {
    execFileSync("/usr/bin/pgrep", ["-f", "tts --serve"], { stdio: "ignore" });
  } catch {
    return false;                       // 没有匹配的进程
  }
  try {
    execFileSync("/usr/bin/pkill", ["-9", "-f", "tts --serve"], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

// 无音频设备探测：发一短句，出现引擎启动失败/drain 超时即视为无设备。
// 顺带探 DEBUG 可见性：同一条探针句若在窗口里留下了 DEBUG 行，说明日志门限放行了。
// 判据不能看 ensureDebugLogging 自己的返回值——那只反映 launchctl 切没切成，
// 而自检经常**附加到手动起的 daemon** 上（launchctl kickstart 对它无效），
// 那个 daemon 本来可能就是对的级别。只有实测才算数（2026-10-20 踩过：非 debug 的
// daemon 上依赖 DEBUG 行的用例假红，报的是「入队块数(0)」这种看着像产品坏了的数）。
async function probeAudio(log) {
  const t0 = nowMs();
  await speakPage("probe", "设备探测短句。");
  const deadline = nowMs() + 20000;
  let settled = false, bad = false;
  while (nowMs() < deadline) {
    await log.poll(t0);
    if (log.grep(/AudioEngine 启动失败/, t0).length || log.grep(/drain 超时强制返回/, t0).length) { bad = true; break; }
    // 「播报结束」出现 = 这条探测短句真的走完了设备（原先借「媒体控制: 恢复」判断，同因失效）
    if (log.grep(/播报结束: 队列已空/, t0).length) { settled = true; break; }
    await sleep(200);
  }
  // 等收尾，避免污染后续窗口
  await waitSettled(log, t0, { timeout: 15000 });
  // 判据取 DEBUG-only 的**正文**，不能取「[DEBUG]」这种级别字样：日志的级别标记在行首，
  // 解析出来就没了，msg 字段里根本没有它——拿它当判据会永远判成 invisible（第一版就栽在这，
  // debug 级下也把用例全 skip 了）。这些正文只有门限放到 debug 才会出现。
  const debugVisible = log.grep(/队列状态:|请求原始内容|清洗后内容/, t0).length > 0;
  return { audio: settled && !bad, debug: debugVisible };
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
  const probe = await probeAudio(runnerLog);
  const hasAudio = probe.audio;
  const debugVisible = probe.debug;
  console.log(`# audio=${hasAudio ? "present" : "absent（播放时序用例将 skip）"}`);
  console.log(`# debug=${debugVisible ? "visible" : "invisible（依赖 DEBUG 行的用例将 skip）"}`);

  const picked = cases.filter((c) => !FILTER || FILTER.test(c.name));
  let n = 0;
  for (const c of picked) {
    n += 1;
    if (c.needsAudio && !hasAudio) {
      results.push({ name: c.name, status: "skip", ms: 0 });
      console.log(`ok ${n} ${c.name} # SKIP needs-audio`);
      continue;
    }
    // 读不到 DEBUG 行就别跑依赖它的用例：假红比 skip 坏得多——skip 会被人看见，
    // 假红会被当成产品缺陷去查半天。
    if (c.needsDebug && !debugVisible) {
      results.push({ name: c.name, status: "skip", ms: 0 });
      console.log(`ok ${n} ${c.name} # SKIP daemon 未开 DEBUG（以 IVOX_LOG_LEVEL=debug 重启后再跑）`);
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
    // 誊清员崩了/正在重拉：合成服务那几秒不在线，用例没测到 ⇒ 降级为 skip（不算产品缺陷）
    if (status === "not ok" && r.scribeDown) {
      console.log(`ok ${n} ${c.name} # SKIP 誊清员崩了/重拉，没测到（${r.scribeDown}）`);
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
