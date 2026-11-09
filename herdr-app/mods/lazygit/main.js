// Alt+G: lazygit in a centered popup, in the focused terminal's folder.
// Opened by mod.open it launches lazygit and closes itself; inside the popup
// (props.terminal) it is the title bar, and gives lazygit the keyboard.

import { View, div } from "gpui-kit";
import { h_flex } from "gpui-base";
import { props, focused, spaces, hc, run, theme, openOverlay, closeOverlay, notify } from "herdr";

export default class Lazygit extends View {
  init(_props, cx) {
    const p = props() ?? {};
    if (p.terminal) {
      for (const ms of [30, 150, 400]) cx.timer.after(ms, () => {
        if (focused()?.terminal !== p.terminal) run("pane.focus", { terminal: p.terminal });
      });
      return;
    }
    cx.spawn(async () => {
      try {
        const f = focused();
        const space = spaces().find((s) => s.id === f?.space);
        const cwd = f?.cwd || space?.folder || null;
        const args = ["run", "--bg", "--json", "--rm", "--no-parent", "--name", `lazygit-${Date.now() % 100000}`];
        if (space?.machine) args.push("--on", space.machine);
        if (cwd) args.push("--cwd", cwd);
        args.push("--", "zsh", "-lc", "lazygit");
        const r = await hc(args);
        if (r.code !== 0) throw new Error(r.stderr || r.stdout);
        const { address } = JSON.parse(r.stdout);
        closeOverlay(p.overlay);
        openOverlay({
          kind: "dialog",
          modal: true,
          width: 0.9,
          height: 0.9,
          layout: {
            type: "column",
            children: [
              { type: "block", size: { px: 26 }, content: { mod: "lazygit", props: { terminal: address } } },
              { type: "block", content: { terminal: address } },
            ],
          },
        });
      } catch (e) {
        closeOverlay(p.overlay);
        notify({ title: "lazygit", body: String(e?.message ?? e), level: "error" });
      }
    });
  }

  render() {
    const p = props() ?? {};
    if (!p.terminal) return div();
    const t = theme();
    const on = focused()?.terminal === p.terminal;
    return h_flex()
      .size_full()
      .px(12)
      .gap(8)
      .items_center()
      .bg(t.surface)
      .border_b(1)
      .border_color(t.border)
      .text_size(12)
      .child(div().size(6).rounded(3).bg(on ? t.accent : t.dim))
      .child(div().font_semibold().text_color(t.foreground).child("lazygit"))
      .child(div().flex_1())
      .child(div().text_color(t.dim).child("q to close"));
  }
}
