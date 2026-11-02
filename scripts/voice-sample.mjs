#!/usr/bin/env node
// 用 {type:tts} 合成一句话并存成 WAV（**不播放**，只出文件）——用来对比音色。
// 用法: node scripts/voice-sample.mjs <voice> <输出.wav> [文本]
//       node scripts/voice-sample.mjs            # 四个音色各出一份（默认输出到 /tmp）
import net from "node:net";
import fs from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const SOCKET = join(homedir(), ".config", "ivox", "ivox.sock");
const SR = 48000;

const TEXT = process.argv[3] || "这是一段音色对比用的样音，用来听清楚这个声音的质地和语气。";

function wav(pcm) {
  const header = Buffer.alloc(44);
  header.write("RIFF", 0);
  header.writeUInt32LE(36 + pcm.length, 4);
  header.write("WAVE", 8);
  header.write("fmt ", 12);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20);           // PCM
  header.writeUInt16LE(1, 22);           // mono
  header.writeUInt32LE(SR, 24);
  header.writeUInt32LE(SR * 2, 28);
  header.writeUInt16LE(16, 32);
  header.writeUInt16LE(16, 34);
  header.write("data", 36);
  header.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([header, pcm]);
}

async function sample(voice, out) {
  const chunks = [];
  const s = net.createConnection(SOCKET);
  await new Promise((res, rej) => { s.once("connect", res); s.once("error", rej); });
  s.write(`{type:tts,source:sample,voice:${voice}}\n`);
  s.write(Buffer.from(TEXT, "utf8"));
  s.end();

  let buf = Buffer.alloc(0);
  await new Promise((res, rej) => {
    s.on("data", (d) => {
      buf = Buffer.concat([buf, d]);
      while (buf.length >= 4) {
        const n = buf.readUInt32LE(0);
        if (n === 0) { buf = buf.subarray(4); s.destroy(); res(); return; }
        if (buf.length < 4 + n) break;
        chunks.push(buf.subarray(4, 4 + n));
        buf = buf.subarray(4 + n);
      }
    });
    s.on("close", res);
    s.on("error", rej);
    setTimeout(() => { s.destroy(); res(); }, 120000);
  });
  const pcm = Buffer.concat(chunks);
  fs.writeFileSync(out, wav(pcm));
  console.log(`${voice} → ${out}  (${(pcm.length / 2 / SR).toFixed(1)}s)`);
}

const voices = process.argv[2] ? [[process.argv[2], process.argv[3] || `/tmp/ivox-${process.argv[2]}.wav`]]
  : [["taozi", "/tmp/ivox-taozi.wav"], ["wanwan", "/tmp/ivox-wanwan.wav"],
     ["mizai", "/tmp/ivox-mizai.wav"], ["dayi", "/tmp/ivox-dayi.wav"]];
for (const [v, out] of voices) await sample(v, out);
