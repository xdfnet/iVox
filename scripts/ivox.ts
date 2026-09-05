import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFile } from "node:child_process";

/**
 * iVox TTS extension for PI coding agent.
 * Subscribes to agent_settled and speaks the last assistant message via ivox.
 */
export default function (pi: ExtensionAPI) {
  pi.on("agent_settled", async (_event, ctx) => {
    // Get all entries and find the last assistant message
    const entries = ctx.sessionManager.getEntries();
    let lastText = "";

    for (let i = entries.length - 1; i >= 0; i--) {
      const entry = entries[i];
      if (entry.type !== "message") continue;
      const msg = entry.message;
      if (msg.role !== "assistant") continue;

      // Extract text from content blocks
      const blocks = msg.content ?? [];
      for (const block of blocks) {
        if (block.type === "text") {
          lastText = block.text;
          break;
        }
      }
      if (lastText) break;
    }

    if (!lastText) return;

    // Skip very short western-language confirmations
    if (lastText.length <= 5 && !/[一-鿿]/.test(lastText)) return;

    // Truncate to avoid oversized payloads
    const text = lastText.slice(0, 5000);

    // Spawn ivox speak in background — fire and forget
    execFile("ivox", ["speak", "--source", "pi", "--", text], {
      cwd: process.env.HOME,
      env: { ...process.env, IVOX_SKIP: "" },
      windowsHide: true,
    });
  });
}
