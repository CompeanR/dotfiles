import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { existsSync } from "node:fs";

export default function sessionRefresh(pi: ExtensionAPI): void {
  pi.registerCommand("refresh", {
    description: "Reload the current persisted session from disk",
    handler: async (_args, ctx) => {
      await ctx.waitForIdle();

      const sessionFile = ctx.sessionManager.getSessionFile();
      if (!sessionFile) {
        ctx.ui.notify("Cannot refresh an in-memory session", "warning");
        return;
      }

      if (!existsSync(sessionFile)) {
        ctx.ui.notify(
          "Session has not been saved yet; wait for the first assistant response",
          "warning",
        );
        return;
      }

      const result = await ctx.switchSession(sessionFile, {
        withSession: async (freshCtx) => {
          freshCtx.ui.notify("Session refreshed from disk", "info");
        },
      });

      if (result.cancelled) {
        ctx.ui.notify("Session refresh cancelled", "warning");
      }
    },
  });
}
