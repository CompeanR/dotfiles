/**
 * anthropic/auto: designs on Opus, implements on Sonnet.
 *
 * Every user message starts on claude-opus-5-5 at the selected thinking level. After the first
 * successful edit or write of that turn, the rest of the turn runs on claude-sonnet-5-5 (high),
 * but only while the context is small: the prompt cache is per model, so switching a long
 * session throws away its cache. Above SWITCH_LIMIT tokens the turn stays on Opus.
 * Retries stay on the model that failed; compaction and other direct requests use Sonnet.
 */

import type { Message } from "@earendil-works/pi-ai";
import { estimateTokens } from "@earendil-works/pi-coding-agent";
import type { ExtensionAPI, ExtensionContext, ModelRoute, ModelRouteRequest } from "@earendil-works/pi-coding-agent";

const PROVIDER = "anthropic";
const DESIGN = "claude-opus-5-5";
const IMPLEMENT = "claude-sonnet-5-5";
const SWITCH_LIMIT = 60_000;
const EDIT_TOOLS = new Set(["edit", "write"]);

function routeTo(ctx: ExtensionContext, id: string, thinkingLevel: ModelRoute["thinkingLevel"]): ModelRoute {
  const model = ctx.modelRegistry.find(PROVIDER, id);
  if (!model) throw new Error(`Model ${PROVIDER}/${id} is not in the catalog`);
  return { model, thinkingLevel };
}

function editedThisTurn(messages: readonly Message[]): boolean {
  const lastUser = messages.findLastIndex((message) => message.role === "user");
  return messages.slice(lastUser + 1).some((message) => {
    if (message.role !== "toolResult") return false;
    if (EDIT_TOOLS.has(message.toolName) && !message.isError) return true;
    return (message.nestedCalls?.calls ?? []).some((call) => EDIT_TOOLS.has(call.name) && call.status === "ok");
  });
}

function contextTokens(messages: readonly Message[]): number {
  return messages.reduce((total, message) => total + estimateTokens(message), 0);
}

export default function (pi: ExtensionAPI) {
  pi.registerVirtualModel({
    provider: PROVIDER,
    id: "auto",
    name: "Auto (Opus design, Sonnet implement)",
    thinkingLevels: ["low", "medium", "high", "xhigh"],
    contextWindow: 1_000_000,
    maxTokens: 128_000,
    route(request: ModelRouteRequest, ctx) {
      if (request.reason === "retry" && request.failed) {
        return { model: request.failed.model, thinkingLevel: request.failed.thinkingLevel ?? "high" };
      }
      if (request.reason === "direct") return routeTo(ctx, IMPLEMENT, "high");
      if (editedThisTurn(request.messages) && contextTokens(request.messages) < SWITCH_LIMIT) {
        return routeTo(ctx, IMPLEMENT, "high");
      }
      return routeTo(ctx, DESIGN, request.thinkingLevel);
    },
  });
}
