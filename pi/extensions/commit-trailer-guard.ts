/**
 * AGENTS.md rule: commits never carry a `Co-authored-by` trailer.
 * Blocks any bash `git commit` that includes one, so the model rewrites the message.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function commitTrailerGuard(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return undefined;
    const command = String(event.input.command ?? "");
    if (/\bgit\b[^\n;|&]*\bcommit\b/.test(command) && /co-authored-by\s*:/i.test(command)) {
      return { block: true, reason: "AGENTS.md: do not add a Co-authored-by trailer. Rerun the commit without it." };
    }
    return undefined;
  });
}
