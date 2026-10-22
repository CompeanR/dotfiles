import { StringEnum } from "@earendil-works/pi-ai";
import { copyToClipboard, type ExtensionAPI, type ExtensionContext, type Theme } from "@earendil-works/pi-coding-agent";
import { matchesKey, truncateToWidth, type TuiMouseEvent, visibleWidth, wrapTextWithAnsi } from "@earendil-works/pi-tui";
import { Type } from "typebox";

type Kind = "needs-you" | "next" | "decision" | "gotcha" | "fact";
type Color = "warning" | "success" | "accent" | "error" | "muted";

interface Finding {
  id: string;
  kind: Kind;
  text: string;
}

interface State {
  notes: Finding[];
  nextId: number;
}

interface Card {
  ids: string[];
  summary?: string;
}

interface Action {
  verb: "do" | "done" | "discuss";
  finding: Finding;
}

interface Layout {
  lines: string[];
  actions: Action[];
  hits: { row: number; from: number; to: number; index: number }[];
}

const NOTE = "findings_note";
const DIGEST = "findings_digest";
const RESOLVE = "findings_resolve";
const ENTRY = "findings";
const CARD = "findings-card";
const WIDGET = "findings";
const PANE_KEY = "alt+f";
const LONG_ANSWER = 1500;

const KINDS: { kind: Kind; label: string; mark: string; color: Color; button?: { verb: Action["verb"]; label: string } }[] = [
  { kind: "needs-you", label: "NEEDS YOU", mark: "!", color: "warning", button: { verb: "done", label: "Done" } },
  { kind: "next", label: "NEXT STEPS", mark: "→", color: "success", button: { verb: "do", label: "Do it" } },
  { kind: "decision", label: "DECISIONS", mark: "◆", color: "accent", button: { verb: "discuss", label: "Discuss" } },
  { kind: "gotcha", label: "GOTCHAS", mark: "▲", color: "error" },
  { kind: "fact", label: "FACTS", mark: "·", color: "muted" },
];

const PROTOCOL = `Findings digest long runs and complex answers for the user. For any task that takes more than a few steps, or any answer with several moving parts, call the ${NOTE} tool the moment you learn something the user must not lose:
- needs-you: something only the user can do or provide. Its button tells you "Done: <text>" once they have done it, so phrase it as the user's task
- next: an action you propose and can do yourself once the user says go, phrased as that action, e.g. "Add claude_design to ~/.pi/agent/mcp.json". When the user must pick between options, note one next step per option instead of asking a needs-you question.
- decision: a choice you made, and why
- gotcha: a surprise, a risk or a workaround
- fact: a fact that shapes the work
Keep each finding under 15 words, written for the user. Skip routine progress and anything the summary already says. Offer at most 3 next steps at a time.
Before your final answer, make sure every proposal or question in it is a next or needs-you finding, so the user can act on it with one click.
Each note answers with its id. The moment a finding stops mattering (you did it, the user picked another option, the gotcha is fixed), call ${RESOLVE} with its id so the user's list only shows what is still open.
`;

const ANSWER_WITH_CARD = `When a long or complex task ends, call the ${DIGEST} tool right before your final answer with a summary the user can read instead of the answer: 2 to 4 short sentences in plain words covering what you did or found, what it means for them, and what is waiting on them. Someone who reads only the card must understand the outcome.
The card shows that summary and every open finding with its buttons right under your answer, so the answer is for depth: go straight to the specifics and don't restate the summary or the findings.
Skip the digest when the answer is already short and easy to read, even after a long task: a summary of a summary only adds clutter.`;

const ANSWER_PLAIN = `When such a task ends, answer in this order:
1. The result, in one or two lines.
2. "What you need to know": every finding that still matters, needs-you and next first.
3. "Details": the technical specifics, kept short.
A short task with no findings keeps a plain short answer.
"What you need to know" is not a recap: the user may not have read the narration, so list each finding there even if you mentioned it earlier.`;

const byKind = (list: Finding[]) =>
  KINDS.map((group) => ({ ...group, items: list.filter((one) => one.kind === group.kind) })).filter(
    (group) => group.items.length > 0,
  );

const ON_CARD: Kind[] = ["needs-you", "next"];

const actionsOf = (list: Finding[]): Action[] =>
  byKind(list).flatMap((group) => (group.button ? group.items.map((finding) => ({ verb: group.button!.verb, finding })) : []));

const cardKey = (card: Card) => `${card.ids.join(",")}|${card.summary ?? ""}`;

const toMarkdown = (list: Finding[]) =>
  byKind(list)
    .map((group) => [`**${group.label}**`, ...group.items.map((one) => `${group.mark} ${one.text}`)].join("\n"))
    .join("\n\n");

function layout(list: Finding[], theme: Theme, width: number, title: string, withKeys: boolean, footer?: string, summary?: string, compact = false): Layout {
  const inner = Math.max(10, width - 4);
  const border = (text: string) => theme.fg("borderMuted", text);
  const out: Layout = { lines: [], actions: [], hits: [] };
  const push = (text = "") => {
    const cell = truncateToWidth(text, inner);
    out.lines.push(`${border("│")} ${cell}${" ".repeat(Math.max(0, inner - visibleWidth(cell)))} ${border("│")}`);
  };

  const head = ` ${theme.bold("Findings")} ${theme.fg("dim", title)} `;
  out.lines.push(`${border("╭─")}${head}${border("─".repeat(Math.max(0, width - 3 - visibleWidth(head))) + "╮")}`);

  const shown = compact ? list.filter((one) => ON_CARD.includes(one.kind)) : list;
  const hidden = byKind(list.filter((one) => !shown.includes(one)));

  if (summary) {
    for (const line of wrapTextWithAnsi(summary, inner)) push(line);
    if (shown.length > 0) push();
  }

  byKind(shown).forEach((group, i) => {
    if (i > 0 && !compact) push();
    if (!compact) push(theme.bold(theme.fg(group.color, group.label)));
    for (const one of group.items) {
      let label = "";
      if (group.button) {
        const index = out.actions.push({ verb: group.button.verb, finding: one }) - 1;
        label = withKeys && index < 9 ? `[${index + 1} ${group.button.label}]` : `[${group.button.label}]`;
        out.hits.push({ row: out.lines.length, from: 4, to: 4 + label.length, index });
      }
      const text = label ? `${theme.fg("accent", label)} ${one.text}` : one.text;
      wrapTextWithAnsi(text, inner - 2).forEach((line, j) => push(`${j === 0 ? theme.fg(group.color, group.mark) : " "} ${line}`));
    }
  });

  const more = hidden
    .map(({ items, label }) => `${items.length} ${items.length === 1 ? label.toLowerCase().replace(/s$/, "") : label.toLowerCase()}`)
    .join(" · ");
  const tail = [more && `+ ${more}`, footer].filter(Boolean).join(theme.fg("dim", "  ·  "));
  if (tail) {
    if (summary || shown.length > 0) push();
    push(theme.fg("dim", tail));
  }
  out.lines.push(border(`╰${"─".repeat(Math.max(0, width - 2))}╯`));
  return out;
}

const NOTHING = { render: () => [], invalidate() {} };

const hitAt = (view: Layout | undefined, event: TuiMouseEvent) =>
  event.button === "left" && (event.type === "press" || event.type === "click")
    ? view?.hits.find((hit) => hit.row === event.y && event.x >= hit.from && event.x < hit.to)
    : undefined;

export default function (pi: ExtensionAPI) {
  let state: State = { notes: [], nextId: 1 };
  let isPaneOpen = false;
  let changedThisRun = false;
  let answerThisRun = "";
  let lastSummary: string | undefined;
  let digestThisRun: string | undefined;
  let hasAskedForDigest = false;
  let latestCard: Card | undefined;
  let armedCard: Card | undefined;
  let lastCtx: ExtensionContext | undefined;

  const snapshot = (): State => ({ notes: [...state.notes], nextId: state.nextId });

  const reconstruct = (ctx: ExtensionContext) => {
    state = { notes: [], nextId: 1 };
    latestCard = undefined;
    lastSummary = undefined;
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type === "custom" && entry.customType === CARD) {
        latestCard = entry.data as Card;
        lastSummary = latestCard?.summary ?? lastSummary;
      }
      if (entry.type === "message" && entry.message.role === "user") latestCard = undefined;
      if (entry.type === "custom" && entry.customType === ENTRY && entry.data) {
        state = entry.data as unknown as State;
      }
      if (entry.type === "message" && entry.message.role === "toolResult") {
        const { toolName, details } = entry.message;
        if ((toolName === NOTE || toolName === RESOLVE) && details) state = details as unknown as State;
      }
    }
  };

  const renderBand = (ctx: ExtensionContext) => {
    if (!ctx.hasUI) return;
    if (state.notes.length === 0 || isPaneOpen || latestCard) {
      ctx.ui.setWidget(WIDGET, undefined);
      return;
    }
    ctx.ui.setWidget(WIDGET, (_tui, theme) => ({
      render(width: number) {
        const list = state.notes;
        const asks = list.filter((one) => one.kind === "needs-you" || one.kind === "next").length;
        const latest = list[list.length - 1];
        const line =
          `${theme.fg("accent", "Findings")} ${theme.fg("dim", `${list.length} open`)}` +
          (asks > 0 ? theme.fg("warning", `  ${asks} waiting on you`) : "") +
          theme.fg("dim", `  ${PANE_KEY} or /findings  latest: ${latest?.text ?? ""}`);
        return [truncateToWidth(line, width)];
      },
      invalidate() {},
    }));
  };

  const save = (ctx: ExtensionContext, next: Finding[]) => {
    state = { ...state, notes: next };
    pi.appendEntry(ENTRY, snapshot());
    renderBand(ctx);
  };

  const run = (ctx: ExtensionContext, action: Action) => {
    const { finding } = action;
    if (action.verb === "discuss") {
      const current = ctx.ui.getEditorText();
      const prompt = `Let's discuss this decision: ${finding.text}\n\n`;
      ctx.ui.setEditorText(current ? `${current}\n${prompt}` : prompt);
      return;
    }
    const text = action.verb === "done" ? `Done: ${finding.text}` : `Go ahead: ${finding.text}`;
    save(ctx, state.notes.filter((one) => one.id !== finding.id));
    if (ctx.isIdle()) {
      pi.sendUserMessage(text);
    } else {
      pi.sendUserMessage(text, { deliverAs: "followUp" });
      ctx.ui.notify("Queued after the current run", "info");
    }
  };

  pi.registerEntryRenderer<Card>(CARD, (entry, _options, theme) => {
    let view: Layout | undefined;
    return {
      render(width: number) {
        const ids = entry.data?.ids ?? [];
        const summary = entry.data?.summary;
        const open = state.notes.filter((one) => ids.includes(one.id));
        const actionable = open.filter((one) => ON_CARD.includes(one.kind));
        if (open.length === 0 && !summary) {
          view = undefined;
          return [theme.fg("dim", `✓ Findings from this answer are handled`)];
        }
        const title = open.length > 0 ? `${open.length} open` : ids.length > 0 ? "all handled" : "";
        const isArmed = armedCard !== undefined && entry.data !== undefined && cardKey(armedCard) === cardKey(entry.data);
        const hint = open.length > 0 && !isArmed ? `${PANE_KEY} ${actionable.length > 0 ? "to act" : "to see all"}` : undefined;
        view = layout(open, theme, Math.min(width, 110), title, isArmed, hint, summary, true);
        return view.lines;
      },
      handleMouse(event: TuiMouseEvent) {
        const hit = hitAt(view, event);
        if (!hit || !view || !lastCtx) return undefined;
        if (event.type === "click") run(lastCtx, view.actions[hit.index]);
        return { handled: true };
      },
      invalidate() {},
    };
  });

  const openPane = async (ctx: ExtensionContext) => {
    isPaneOpen = true;
    renderBand(ctx);
    const picked = await ctx.ui.custom<Action | string>(
      (_tui, theme, _kb, done) => {
        let view: Layout | undefined;
        const footer = `${theme.fg("accent", "[Copy]")} ${theme.fg("dim", "c")}  ${theme.fg("accent", "[Clear]")} ${theme.fg("dim", "x")}  ${theme.fg("dim", "esc close")}`;
        return {
          render(width: number) {
            view = layout(state.notes, theme, width, String(state.notes.length), true, footer, lastSummary);
            if (state.notes.length === 0 && !lastSummary) view.lines.splice(1, 0, theme.fg("dim", "  No findings yet."));
            return view.lines;
          },
          handleInput(data: string) {
            if (matchesKey(data, "escape") || matchesKey(data, "ctrl+c") || data === "q") return done("close");
            if (data === "c" || data === "x") return done(data);
            const action = /^[1-9]$/.test(data) ? view?.actions[Number(data) - 1] : undefined;
            if (action) done(action);
          },
          handleMouse(event: TuiMouseEvent) {
            const hit = hitAt(view, event);
            if (!hit || !view) return undefined;
            if (event.type === "click") done(view.actions[hit.index]);
            return { handled: true };
          },
          invalidate() {},
        };
      },
      { overlay: true, overlayOptions: { anchor: "top-right", width: "45%", minWidth: 40, maxHeight: "90%", margin: 1 } },
    );
    isPaneOpen = false;

    if (typeof picked === "object") {
      run(ctx, picked);
    } else if (picked === "c" && state.notes.length > 0) {
      try {
        await copyToClipboard(toMarkdown(state.notes));
        ctx.ui.notify("Findings copied", "info");
      } catch (error) {
        ctx.ui.notify(`Could not copy: ${(error as Error).message}`, "error");
      }
    } else if (picked === "x") {
      save(ctx, []);
      ctx.ui.notify("Findings cleared", "info");
    }
    renderBand(ctx);
  };

  const refresh = async (_event: unknown, ctx: ExtensionContext) => {
    lastCtx = ctx;
    reconstruct(ctx);
    renderBand(ctx);
  };
  pi.on("session_start", refresh);
  pi.on("session_tree", refresh);

  pi.on("before_agent_start", async (event, ctx) => {
    lastCtx = ctx;
    changedThisRun = false;
    answerThisRun = "";
    digestThisRun = undefined;
    hasAskedForDigest = false;
    latestCard = undefined;
    renderBand(ctx);
    const open = state.notes.map((one) => `- [${one.id}] ${one.kind}: ${one.text}`).join("\n");
    const protocol = `${PROTOCOL}\n\n${ctx.mode === "tui" ? ANSWER_WITH_CARD : ANSWER_PLAIN}`;
    event.systemPromptOptions.sections.findings = open
      ? `${protocol}\n\nOpen findings so far (still in the user's list):\n${open}`
      : protocol;
  });

  pi.on("agent_before_settle", async (event, ctx) => {
    const isLong = answerThisRun.length >= LONG_ANSWER;
    const needsDigest = ctx.mode === "tui" && isLong && !digestThisRun && !hasAskedForDigest;
    if (!needsDigest || event.outcome !== "completed") return;
    hasAskedForDigest = true;
    return {
      entries: [
        {
          type: "custom_message",
          customType: "findings-digest-request",
          content: `Call ${DIGEST} now with the summary of your answer above. Write no other text.`,
          display: false,
        },
      ],
      continue: true,
    };
  });

  pi.on("message_end", async (event) => {
    const { message } = event;
    if (message.role !== "assistant" || !Array.isArray(message.content)) return;
    const text = message.content
      .map((part) => (part.type === "text" ? part.text : ""))
      .join("")
      .trim();
    if (text) answerThisRun = text;
  });

  pi.on("agent_settled", async (_event, ctx) => {
    lastCtx = ctx;
    const summary = answerThisRun.length >= LONG_ANSWER ? digestThisRun : undefined;
    if (summary) lastSummary = summary;
    const hasFindings = changedThisRun && state.notes.length > 0;
    changedThisRun = false;
    digestThisRun = undefined;
    if (!ctx.hasUI || (!summary && !hasFindings)) return;
    latestCard = { ids: state.notes.map((one) => one.id), summary };
    pi.appendEntry<Card>(CARD, latestCard);
    renderBand(ctx);
  });

  pi.registerTool({
    name: DIGEST,
    label: "Digest",
    description:
      "Give the user a short plain summary of a long or complex answer. It shows at the top of the findings card under your answer. Call it right before the final answer.",
    parameters: Type.Object({
      summary: Type.String({ description: "2 to 4 short sentences in plain words: what you did or found, what it means, what is waiting on the user." }),
    }),
    renderShell: "self",

    async execute(_toolCallId, params) {
      digestThisRun = params.summary.trim();
      return { content: [{ type: "text", text: "Saved. It shows at the top of the card under your answer." }], details: undefined, terminate: hasAskedForDigest };
    },

    renderCall: () => NOTHING,
    renderResult: () => NOTHING,
  });

  pi.registerTool({
    name: NOTE,
    label: "Finding",
    description:
      "Record a finding the user must not lose during a multi-step task or a complex answer. It shows in their Findings list right away and in the card under your answer.",
    parameters: Type.Object({
      kind: StringEnum(["needs-you", "next", "decision", "gotcha", "fact"] as const, {
        description:
          "needs-you: only the user can do or provide it. next: an action you propose and can do once the user says go, phrased as that action; one per option when they must choose. decision: a choice made, and why. gotcha: a surprise, risk or workaround. fact: a fact that shapes the work.",
      }),
      text: Type.String({ description: "One short sentence, written for the user." }),
    }),
    executionMode: "sequential",
    renderShell: "self",

    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const text = params.text.trim();
      if (!text) throw new Error("Give text as one short sentence.");
      const id = String(state.nextId);
      state = { notes: [...state.notes, { id, kind: params.kind, text }], nextId: state.nextId + 1 };
      changedThisRun = true;
      renderBand(ctx);
      return { content: [{ type: "text", text: `Noted as ${id}.` }], details: snapshot() };
    },

    renderCall: () => NOTHING,
    renderResult: () => NOTHING,
  });

  pi.registerTool({
    name: RESOLVE,
    label: "Resolve findings",
    description:
      "Remove findings from the user's Findings list once they no longer matter: the item is done, the user picked another option, the gotcha is fixed.",
    parameters: Type.Object({
      ids: Type.Array(Type.String(), { description: "The ids the note tool answered with." }),
    }),
    executionMode: "sequential",
    renderShell: "self",

    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const ids = params.ids.map(String);
      const gone = ids.filter((id) => state.notes.some((one) => one.id === id));
      const already = ids.filter((id) => !gone.includes(id));
      state = { ...state, notes: state.notes.filter((one) => !ids.includes(one.id)) };
      changedThisRun = true;
      renderBand(ctx);
      const text =
        `Resolved ${gone.length}.` +
        (already.length ? ` ${already.join(", ")} already left the list (the user handled them), so nothing is left to do for those.` : "");
      return { content: [{ type: "text", text }], details: snapshot() };
    },

    renderCall: () => NOTHING,
    renderResult: () => NOTHING,
  });

  pi.registerShortcut(PANE_KEY, {
    description: "Act on the latest Findings card, or open the Findings pane",
    handler: async (ctx) => {
      lastCtx = ctx;
      if (isPaneOpen || armedCard) return;
      const card = latestCard;
      const actions = card ? actionsOf(state.notes.filter((one) => card.ids.includes(one.id) && ON_CARD.includes(one.kind))) : [];
      if (!card || actions.length === 0) return openPane(ctx);

      armedCard = card;
      const picked = await ctx.ui.custom<Action | "all" | undefined>((_tui, theme, _kb, done) => ({
        render: (width: number) => [
          truncateToWidth(
            `${theme.fg("accent", "Findings")} ${theme.fg("dim", `press ${actions.length === 1 ? "1" : `1-${Math.min(actions.length, 9)}`} on the card above · a all findings · esc cancel`)}`,
            width,
          ),
        ],
        handleInput(data: string) {
          if (matchesKey(data, "escape") || matchesKey(data, "ctrl+c") || data === "q") return done(undefined);
          if (data === "a") return done("all");
          const action = /^[1-9]$/.test(data) ? actions[Number(data) - 1] : undefined;
          if (action) done(action);
        },
        invalidate() {},
      }));
      armedCard = undefined;
      if (picked === "all") return openPane(ctx);
      if (picked) run(ctx, picked);
    },
  });

  pi.registerCommand("findings", {
    description: "Open the Findings pane, or clear it with /findings clear",
    handler: async (args, ctx) => {
      lastCtx = ctx;
      if (args.trim() === "clear") {
        save(ctx, []);
        ctx.ui.notify("Findings cleared", "info");
        return;
      }
      if (ctx.mode !== "tui") {
        ctx.ui.notify(state.notes.length ? toMarkdown(state.notes) : "No findings yet.", "info");
        return;
      }
      await openPane(ctx);
    },
  });
}
