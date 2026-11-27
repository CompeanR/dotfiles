import { View, div } from "gpui-kit";
import { panes, run, hc, nextCommand } from "herdr";

// ctrl+h/j/k/l: Vim/Neovim gets the key (it hands back via `herdr-app do pane.go`
// at a split edge); every other pane moves herdr's focus. Mirrors vim-herdr-navigation.
const KEYS = { left: "ctrl+h", down: "ctrl+j", up: "ctrl+k", right: "ctrl+l" };
const VIM = /^g?(view|l?n?vim?x?)(diff)?$/;

export default class SmartNav extends View {
  init(_props, cx) {
    cx.spawn(async () => {
      for (;;) {
        const dir = await nextCommand();
        if (!KEYS[dir]) continue;
        const pane = panes().find((p) => p.focused);
        const program = pane?.program;
        if (pane?.terminal && (program?.key === "nvim" || VIM.test(program?.name?.toLowerCase() ?? ""))) {
          // Not awaited: held/repeated keys (picker ctrl+j/k) would queue behind each hc round trip.
          hc(["keys", pane.terminal, KEYS[dir]]).catch(() => {});
        } else {
          run("pane.go", { direction: dir });
        }
      }
    });
  }

  render() {
    return div();
  }
}
