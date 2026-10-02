import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFile } from "node:child_process";

/**
 * iVox TTS extension for PI coding agent.
 * Subscribes to agent_settled and speaks the last assistant message via ivox.
 */
export default function (pi: ExtensionAPI) {
  pi.on("agent_settled", async (_event, ctx) => {
    // Get all entries and find the last assistant message with text
    const entries = ctx.sessionManager.getEntries();
    let lastText = "";

    for (let i = entries.length - 1; i >= 0; i--) {
      const entry = entries[i];
      if (entry.type !== "message") continue;
      const msg = entry.message;
      if (msg.role !== "assistant") continue;

      // Concatenate every text block — a single assistant message can carry
      // text on both sides of a tool call, and taking only the first one
      // silently drops the rest.
      let text = "";
      for (const block of msg.content ?? []) {
        if (block.type === "text" && typeof block.text === "string") text += block.text;
      }
      if (text.trim()) {
        lastText = text;
        break;
      }
    }

    if (!lastText) return;

    // Skip very short western-language confirmations
    if (lastText.length <= 5 && !/[一-鿿]/.test(lastText)) return;

    // Spawn ivox speak in background — fire and forget.
    // No truncation here: the socket client loops until the whole payload is
    // written, so long replies survive intact.
    execFile("ivox", ["speak", "--source", "pi", "--", lastText], {
      cwd: process.env.HOME,
      env: { ...process.env, IVOX_SKIP: "" },
      windowsHide: true,
    });
  });
}
