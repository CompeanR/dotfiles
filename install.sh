#!/bin/bash

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<EOF
Usage: $(basename "$0") [server [bootstrap|doctor|sandbox|help] [options]]

  (no args)                         Desktop force-link profile
  server                            Safe server symlink profile only
  server bootstrap [--dry-run] [--yes]
  server doctor [--json]
  server sandbox [--dry-run|--apply]
  server help
  help
EOF
}

# Claude Code config. Shared by both profiles.
#
# settings.json is COPIED, not symlinked: Claude Code rewrites it at runtime
# (autoMode.environment, theme) and a symlink would push machine-local state
# back into the repo. Everything else is read-only to Claude, so it links.
install_claude() {
  local mode="${1:-force}"   # force (desktop) | safe (server)
  local status=0
  mkdir -p ~/.claude/skills

  if [[ "$mode" == "safe" ]]; then
    safe_link "$ROOT/claude/CLAUDE.md" ~/.claude/CLAUDE.md || status=1
    for skill in "$ROOT"/claude/skills/*/; do
      safe_link "${skill%/}" ~/.claude/skills/"$(basename "$skill")" || status=1
    done
  else
    ln -sf "$ROOT/claude/CLAUDE.md" ~/.claude/CLAUDE.md
    for skill in "$ROOT"/claude/skills/*/; do
      ln -sfn "${skill%/}" ~/.claude/skills/"$(basename "$skill")"
    done
  fi

  # settings.json: copy, backing up anything that differs.
  if ! cmp -s "$ROOT/claude/settings.json" ~/.claude/settings.json; then
    if [[ -e ~/.claude/settings.json ]]; then
      mkdir -p ~/.claude/backups
      cp ~/.claude/settings.json ~/.claude/backups/"settings.json.$(date +%Y%m%d-%H%M%S)"
    fi
    cp "$ROOT/claude/settings.json" ~/.claude/settings.json
    echo "claude: settings.json synced from dotfiles (previous copy in ~/.claude/backups/)"
  fi

  # Pi subagent MCP server (~/.claude.json is not tracked, so register it here).
  if command -v claude >/dev/null 2>&1; then
    if ! claude mcp list 2>/dev/null | grep -q '^pi:'; then
      claude mcp add pi --scope user -- node "$ROOT/claude/mcp/pi-subagent/server.mjs" >/dev/null 2>&1 \
        && echo "claude: registered pi MCP server" \
        || echo "claude: could not register pi MCP server (run: claude mcp add pi --scope user -- node $ROOT/claude/mcp/pi-subagent/server.mjs)" >&2
    fi
  fi

  # herdr owns ~/.claude/hooks/herdr-agent-state.sh; let it install its own hook.
  if command -v herdr >/dev/null 2>&1; then
    herdr integration install claude >/dev/null 2>&1 || true
  fi

  return "$status"
}

# Desktop: force-link map (unchanged destinations; sources resolved from script location).
install_desktop() {
  ln -sf "$ROOT/alacritty/alacritty.yml" ~/.config/alacritty/alacritty.yml
  ln -sf "$ROOT/nvim/init.vim" ~/.config/nvim/init.vim
  ln -sf "$ROOT/tmux/.tmux.conf" ~/.tmux.conf
  ln -sfn "$ROOT/tmux/.config/tmux" ~/.config/tmux
  ln -sfn "$ROOT/tmux/scripts" ~/scripts
  ln -sf "$ROOT/vscode/settings.json" ~/.config/Code/User/settings.json
  ln -sf "$ROOT/vscode/keybindings.json" ~/.config/Code/User/keybindings.json
  ln -sf "$ROOT/ideavimrc" ~/.ideavimrc
  ln -sfn "$ROOT/ghostty" ~/.config/ghostty
  # Ghostty is split into config-common + a per-host file; pick this machine's.
  case "$(uname -s)" in
    Darwin) ghostty_host="config-macos" ;;
    *) ghostty_host="config-linux" ;;
  esac
  ln -sf "$ROOT/ghostty/$ghostty_host" "$ROOT/ghostty/config-host"

  # Linux only: keep Ghostty's GTK chrome in sync with the Omarchy theme.
  if [[ $ghostty_host == "config-linux" ]] && [[ -d ~/.config/omarchy ]]; then
    mkdir -p ~/.config/omarchy/hooks/theme-set.d
    ln -sf "$ROOT/ghostty/theme-set-hook" ~/.config/omarchy/hooks/theme-set.d/ghostty-gtk-css
    "$ROOT/ghostty/omarchy-gtk-css" || true
  fi

  # Lazygit config
  mkdir -p ~/.config/lazygit
  ln -sf "$ROOT/lazygit/config.yml" ~/.config/lazygit/config.yml

  # Omarchy idle/lock config (30-minute automatic lock)
  mkdir -p ~/.config/hypr
  ln -sf "$ROOT/hypr/hypridle.conf" ~/.config/hypr/hypridle.conf
  if command -v omarchy-restart-hypridle >/dev/null 2>&1; then
    omarchy-restart-hypridle
  fi

  # Pi agent config
  mkdir -p ~/.pi/agent/npm
  ln -sf "$ROOT/pi/AGENTS.md" ~/.pi/agent/AGENTS.md
  ln -sf "$ROOT/pi/subagent-tool-description.md" ~/.pi/agent/subagent-tool-description.md
  ln -sf "$ROOT/pi/settings.json" ~/.pi/agent/settings.json
  ln -sf "$ROOT/pi/mcp.json" ~/.pi/agent/mcp.json
  ln -sf "$ROOT/pi/cursor-sdk.json" ~/.pi/agent/cursor-sdk.json
  ln -sfn "$ROOT/pi/agents" ~/.pi/agent/agents
  ln -sfn "$ROOT/pi/chains" ~/.pi/agent/chains
  ln -sfn "$ROOT/pi/extensions" ~/.pi/agent/extensions
  ln -sfn "$ROOT/pi/themes" ~/.pi/agent/themes
  ln -sfn "$ROOT/pi/skills" ~/.pi/agent/skills
  ln -sfn "$ROOT/pi/gentle-ai" ~/.pi/agent/gentle-ai
  ln -sf "$ROOT/pi/npm/package.json" ~/.pi/agent/npm/package.json
  ln -sf "$ROOT/pi/npm/package-lock.json" ~/.pi/agent/npm/package-lock.json
  ln -sf "$ROOT/pi/npm/.npmrc" ~/.pi/agent/npm/.npmrc

  # Cursor personal skills (Pi MCP playbook)
  mkdir -p ~/.cursor/skills
  ln -sfn "$ROOT/cursor/skills/pi" ~/.cursor/skills/pi

  # Herdr config (durable files only; runtime state stays local)
  mkdir -p ~/.config/herdr/agent-detection
  ln -sf "$ROOT/herdr/config.toml" ~/.config/herdr/config.toml
  ln -sf "$ROOT/herdr/.gitignore" ~/.config/herdr/.gitignore
  ln -sf "$ROOT/herdr/agent-detection/pi.toml" ~/.config/herdr/agent-detection/pi.toml
  # Ctrl-hjkl across herdr panes + nvim splits (idempotent)
  if command -v herdr >/dev/null 2>&1; then
    herdr plugin install paulbkim-dev/vim-herdr-navigation -y >/dev/null 2>&1 || true
    # tmux-floax style persistent floating shell (needs cargo + tmux/dtach/abduco)
    if command -v cargo >/dev/null 2>&1; then
      herdr plugin install Tyru5/herdr-floax -y >/dev/null 2>&1 || true
    fi
    herdr plugin link "$ROOT/herdr/plugins/ram-status" --enabled >/dev/null 2>&1 || true
  fi

  install_claude force

  echo "Dotfiles have been symlinked!"
}

# Server: create parents; accept only the exact intended symlink (no overwrite).
safe_link() {
  local target="$1"
  local link="$2"

  # Require a real source path; -e follows symlinks, -L catches dangling ones.
  if [[ ! -e "$target" && ! -L "$target" ]]; then
    echo "refusing: source missing: $target" >&2
    return 1
  fi

  mkdir -p "$(dirname "$link")"

  if [[ -L "$link" ]]; then
    if [[ "$(readlink "$link")" == "$target" ]]; then
      return 0
    fi
    echo "refusing: $link is a symlink to $(readlink "$link") (want $target)" >&2
    return 1
  fi

  if [[ -e "$link" ]]; then
    echo "refusing: $link exists and is not a symlink" >&2
    return 1
  fi

  ln -s "$target" "$link"
}

install_server() {
  local status=0

  safe_link "$ROOT/zsh/.zshenv" "$HOME/.zshenv" || status=1
  safe_link "$ROOT/zsh/.zshrc" "$HOME/.zshrc" || status=1
  safe_link "$ROOT/nvim" ~/.config/nvim || status=1
  safe_link "$ROOT/opencode" ~/.config/opencode || status=1
  safe_link "$ROOT/tmux/.tmux.conf" ~/.tmux.conf || status=1
  safe_link "$ROOT/tmux/.config/tmux" ~/.config/tmux || status=1
  safe_link "$ROOT/tmux/scripts" ~/scripts || status=1
  safe_link "$ROOT/lazygit/config.yml" ~/.config/lazygit/config.yml || status=1

  # Pi durable files/dirs (runtime state stays local)
  mkdir -p ~/.pi/agent/npm
  safe_link "$ROOT/pi/AGENTS.md" ~/.pi/agent/AGENTS.md || status=1
  safe_link "$ROOT/pi/subagent-tool-description.md" ~/.pi/agent/subagent-tool-description.md || status=1
  safe_link "$ROOT/pi/settings.json" ~/.pi/agent/settings.json || status=1
  safe_link "$ROOT/pi/mcp.json" ~/.pi/agent/mcp.json || status=1
  safe_link "$ROOT/pi/cursor-sdk.json" ~/.pi/agent/cursor-sdk.json || status=1
  safe_link "$ROOT/pi/agents" ~/.pi/agent/agents || status=1
  safe_link "$ROOT/pi/chains" ~/.pi/agent/chains || status=1
  safe_link "$ROOT/pi/extensions" ~/.pi/agent/extensions || status=1
  safe_link "$ROOT/pi/themes" ~/.pi/agent/themes || status=1
  safe_link "$ROOT/pi/skills" ~/.pi/agent/skills || status=1
  safe_link "$ROOT/pi/gentle-ai" ~/.pi/agent/gentle-ai || status=1
  safe_link "$ROOT/pi/npm/package.json" ~/.pi/agent/npm/package.json || status=1
  safe_link "$ROOT/pi/npm/package-lock.json" ~/.pi/agent/npm/package-lock.json || status=1
  safe_link "$ROOT/pi/npm/.npmrc" ~/.pi/agent/npm/.npmrc || status=1

  # Cursor personal skills (Pi MCP playbook)
  mkdir -p ~/.cursor/skills
  safe_link "$ROOT/cursor/skills/pi" ~/.cursor/skills/pi || status=1

  # Herdr durable files only
  mkdir -p ~/.config/herdr/agent-detection
  safe_link "$ROOT/herdr/config.toml" ~/.config/herdr/config.toml || status=1
  safe_link "$ROOT/herdr/.gitignore" ~/.config/herdr/.gitignore || status=1
  safe_link "$ROOT/herdr/agent-detection/pi.toml" ~/.config/herdr/agent-detection/pi.toml || status=1
  if command -v herdr >/dev/null 2>&1; then
    herdr plugin link "$ROOT/herdr/plugins/ram-status" --enabled >/dev/null 2>&1 || true
  fi

  # VerseGuard Metro user unit (link only; do not enable/start)
  safe_link "$ROOT/systemd/user/verseguard-metro.service" "$HOME/.config/systemd/user/verseguard-metro.service" || status=1

  install_claude safe || status=1

  if (( status == 0 )); then
    echo "Server dotfiles have been symlinked!"
  fi
  return "$status"
}

case "${1:-}" in
  "" )
    install_desktop
    ;;
  help|-h|--help)
    usage
    ;;
  server)
    shift
    if (($# == 0)); then
      install_server
    else
      exec "$ROOT/server/bootstrap.sh" "$@"
    fi
    ;;
  *)
    usage
    exit 1
    ;;
esac
