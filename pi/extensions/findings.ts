import { StringEnum } from "@earendil-works/pi-ai";
import { copyToClipboard, type ExtensionAPI, type ExtensionContext, type Theme } from "@earendil-works/pi-coding-agent";
import { matchesKey, Text, truncateToWidth, visibleWidth, wrapTextWithAnsi } from "@earendil-works/pi-tui";
import { Type } from "typebox";

type Kind = "needs-you" | "decision" | "gotcha" | "fact";
type Color = "warning" | "accent" | "error" | "muted";

interface Finding {
  id: string;
  kind: Kind;
  text: string;
}

interface State {
  notes: Finding[];
  nextId: number;
}

const NOTE = "findings_note";
const RESOLVE = "findings_resolve";
const ENTRY = "findings";
const WIDGET = "findings";

const KINDS: { kind: Kind; label: string; mark: string; color: Color }[] = [
  { kind: "needs-you", label: "NEEDS YOU", mark: "!", color: "warning" },
  { kind: "decision", label: "DECISIONS", mark: "◆", color: "accent" },
  { kind: "gotcha", label: "GOTCHAS", mark: "▲", color: "error" },
  { kind: "fact", label: "FACTS", mark: "·", color: "muted" },
];

const PROTOCOL = `For any task that takes more than a few steps, call the ${NOTE} tool the moment you learn something the user must not lose:
- needs-you: something they have to do, decide or provide
- decision: a choice you made or propose, and why
- gotcha: a surprise, a risk or a workaround
- fact: a fact that shapes the work
One short sentence each, written for the user. Skip routine progress.
Each note answers with its id. The moment a finding stops mattering (you did the needs-you item, applied the decision, fixed the gotcha), call ${RESOLVE} with its id so the user's list only shows what is still open.

When such a task ends, answer in this order:
1. The result, in one or two lines.
2. "What you need to know": every finding that still matters, needs-you first.
3. "Details": the technical specifics, kept short.
A short task with no findings keeps a plain short answer.
"What you need to know" is not a recap: the user may not have read the narration, so list each finding there even if you mentioned it earlier.`;

const byKind = (list: Finding[]) =>
  KINDS.map((group) => ({ ...group, items: list.filter((one) => one.kind === group.kind) })).filter(
    (group) => group.items.length > 0,
  );

const toMarkdown = (list: Finding[]) =>
  byKind(list)
    .map((group) => [`**${group.label}**`, ...group.items.map((one) => `${group.mark} ${one.text}`)].join("\n"))
    .join("\n\n");

const bullets = (list: Finding[], kind: Kind) =>
  list
    .filter((one) => one.kind === kind)
    .map((one) => `- ${one.text}`)
    .join("\n");

class FindingsPane {
  public constructor(
    private readonly list: Finding[],
    private readonly theme: Theme,
    private readonly onKey: (key: string) => void,
  ) {}

  public handleInput(data: string): void {
    if (matchesKey(data, "escape") || matchesKey(data, "ctrl+c") || data === "q") {
      this.onKey("close");
      return;
    }
    if (["d", "t", "c", "x"].includes(data)) this.onKey(data);
  }

  public render(width: number): string[] {
    const th = this.theme;
    const inner = Math.max(10, width - 4);
    const border = (text: string) => th.fg("borderMuted", text);
    const lines: string[] = [];
    const push = (text = "") => {
      const cell = truncateToWidth(text, inner);
      lines.push(`${border("│")} ${cell}${" ".repeat(Math.max(0, inner - visibleWidth(cell)))} ${border("│")}`);
    };
    const button = (label: string, key: string) => `${th.fg("accent", `[${label}]`)} ${th.fg("dim", key)}`;

    const title = ` ${th.bold("Findings")} ${th.fg("dim", String(this.list.length))} `;
    lines.push(`${border("╭─")}${title}${border("─".repeat(Math.max(0, width - 3 - visibleWidth(title))) + "╮")}`);
    push();

    if (this.list.length === 0) {
      push(th.fg("dim", "No findings yet. They show up here as the agent notes them."));
    }

    for (const group of byKind(this.list)) {
      push(th.bold(th.fg(group.color, `${group.label} · ${group.items.length}`)));
      for (const one of group.items) {
        const wrapped = wrapTextWithAnsi(one.text, inner - 2);
        wrapped.forEach((line, i) => push(`${i === 0 ? th.fg(group.color, group.mark) : " "} ${line}`));
      }
      if (group.kind === "needs-you") push(`  ${button("Do it", "d")}`);
      if (group.kind === "decision") push(`  ${button("Discuss", "t")}`);
      push();
    }

    push(`${button("Copy", "c")}  ${button("Clear", "x")}  ${th.fg("dim", "esc close")}`);
    lines.push(border(`╰${"─".repeat(Math.max(0, width - 2))}╯`));
    return lines;
  }

  public invalidate(): void {}
}

export default function (pi: ExtensionAPI) {
  let state: State = { notes: [], nextId: 1 };
  let isPaneOpen = false;

  const snapshot = (): State => ({ notes: [...state.notes], nextId: state.nextId });

  const reconstruct = (ctx: ExtensionContext) => {
    state = { notes: [], nextId: 1 };
    for (const entry of ctx.sessionManager.getBranch()) {
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
    if (state.notes.length === 0 || isPaneOpen) {
      ctx.ui.setWidget(WIDGET, undefined);
      return;
    }
    const list = state.notes;
    ctx.ui.setWidget(WIDGET, (_tui, theme) => ({
      render(width: number) {
        const needs = list.filter((one) => one.kind === "needs-you").length;
        const latest = list[list.length - 1];
        const line =
          `${theme.fg("accent", "Findings")} ${theme.fg("dim", `${list.length} noted`)}` +
          (needs > 0 ? theme.fg("warning", `  ! ${needs} need you`) : "") +
          theme.fg("dim", `  /findings  latest: ${latest?.text ?? ""}`);
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

  const send = (ctx: ExtensionContext, text: string) => {
    if (ctx.isIdle()) pi.sendUserMessage(text);
    else pi.sendUserMessage(text, { deliverAs: "followUp" });
  };

  const openPane = async (ctx: ExtensionContext) => {
    isPaneOpen = true;
    renderBand(ctx);
    const key = await ctx.ui.custom<string>(
      (_tui, theme, _kb, done) => new FindingsPane(snapshot().notes, theme, done),
      { overlay: true, overlayOptions: { anchor: "top-right", width: "45%", minWidth: 40, maxHeight: "90%", margin: 1 } },
    );
    isPaneOpen = false;

    const list = state.notes;
    if (key === "d" && bullets(list, "needs-you")) {
      send(ctx, `Go ahead and do these yourself:\n${bullets(list, "needs-you")}`);
      save(ctx, list.filter((one) => one.kind !== "needs-you"));
      ctx.ui.notify("Queued: the agent will do them", "info");
    } else if (key === "t" && bullets(list, "decision")) {
      const current = ctx.ui.getEditorText();
      const prompt = `Let's discuss these decisions:\n${bullets(list, "decision")}\n\n`;
      ctx.ui.setEditorText(current ? `${current}\n${prompt}` : prompt);
    } else if (key === "c" && list.length > 0) {
      try {
        await copyToClipboard(toMarkdown(list));
        ctx.ui.notify("Findings copied", "info");
      } catch (error) {
        ctx.ui.notify(`Could not copy: ${(error as Error).message}`, "error");
      }
    } else if (key === "x") {
      save(ctx, []);
      ctx.ui.notify("Findings cleared", "info");
    }
    renderBand(ctx);
  };

  pi.on("session_start", async (_event, ctx) => {
    reconstruct(ctx);
    renderBand(ctx);
  });

  pi.on("session_tree", async (_event, ctx) => {
    reconstruct(ctx);
    renderBand(ctx);
  });

  pi.on("before_agent_start", async (event) => {
    const open = state.notes.map((one) => `- [${one.id}] ${one.kind}: ${one.text}`).join("\n");
    event.systemPromptOptions.sections.findings = open
      ? `${PROTOCOL}\n\nOpen findings so far (still in the user's list):\n${open}`
      : PROTOCOL;
  });

  pi.registerTool({
    name: NOTE,
    label: "Finding",
    description:
      "Record a finding the user must not lose during a multi-step task. It shows in their Findings list right away.",
    parameters: Type.Object({
      kind: StringEnum(["needs-you", "decision", "gotcha", "fact"] as const, {
        description:
          "needs-you: they must act, decide or provide something. decision: a choice made or proposed, and why. gotcha: a surprise, risk or workaround. fact: a fact that shapes the work.",
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
      renderBand(ctx);
      return { content: [{ type: "text", text: `Noted as ${id}.` }], details: snapshot() };
    },

    renderCall(args, theme, context) {
      const group = KINDS.find((one) => one.kind === args.kind) ?? KINDS[3];
      return new Text(`${theme.fg(group.color, `${group.mark} ${group.kind}`)} ${args.text ?? ""}`, context.outputPad, 0);
    },

    renderResult() {
      return new Text("", 0, 0);
    },
  });

  pi.registerTool({
    name: RESOLVE,
    label: "Resolve findings",
    description:
      "Remove findings from the user's Findings list once they no longer matter: the needs-you item is done, the decision applied, the gotcha fixed.",
    parameters: Type.Object({
      ids: Type.Array(Type.String(), { description: "The ids the note tool answered with." }),
    }),
    executionMode: "sequential",
    renderShell: "self",

    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const ids = params.ids.map(String);
      const gone = state.notes.filter((one) => ids.includes(one.id)).length;
      state = { ...state, notes: state.notes.filter((one) => !ids.includes(one.id)) };
      renderBand(ctx);
      return { content: [{ type: "text", text: `Resolved ${gone} of ${ids.length}.` }], details: snapshot() };
    },

    renderCall(args, theme, context) {
      return new Text(theme.fg("dim", `✓ resolved finding ${(args.ids ?? []).join(", ")}`), context.outputPad, 0);
    },

    renderResult() {
      return new Text("", 0, 0);
    },
  });

  pi.registerCommand("findings", {
    description: "Open the Findings pane, or clear it with /findings clear",
    handler: async (args, ctx) => {
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
