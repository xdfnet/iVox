// ivox.ts
// Pi coding agent extension: send final assistant text to iVox via CLI.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

function extractText(messages: any[]): string {
  const last = messages?.filter((m: any) => m.role === "assistant")?.at(-1);
  if (!last) return "";

  const content = last.content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";

  return content
    .filter((b: any) => b.type === "text")
    .map((b: any) => b.text)
    .join("\n");
}

export default function (pi: ExtensionAPI) {
  pi.on("agent_end", async (event) => {
    const text = extractText(event.messages ?? []);
    if (!text) return;
    pi.exec("ivox", ["speak", "--source", "pi", text]);
  });
}
