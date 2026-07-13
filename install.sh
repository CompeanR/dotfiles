#!/bin/bash

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "Usage: $(basename "$0") [server]" >&2
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
  ln -sf "$ROOT/ghostty" ~/.config/ghostty

  # Pi agent config
  mkdir -p ~/.pi/agent/npm
  ln -sf "$ROOT/pi/settings.json" ~/.pi/agent/settings.json
  ln -sf "$ROOT/pi/mcp.json" ~/.pi/agent/mcp.json
  ln -sf "$ROOT/pi/subagents.json" ~/.pi/agent/subagents.json
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

  # Herdr config (durable files only; runtime state stays local)
  mkdir -p ~/.config/herdr/agent-detection
  ln -sf "$ROOT/herdr/config.toml" ~/.config/herdr/config.toml
  ln -sf "$ROOT/herdr/.gitignore" ~/.config/herdr/.gitignore
  ln -sf "$ROOT/herdr/agent-detection/pi.toml" ~/.config/herdr/agent-detection/pi.toml

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

  # Pi durable files/dirs (runtime state stays local)
  mkdir -p ~/.pi/agent/npm
  safe_link "$ROOT/pi/settings.json" ~/.pi/agent/settings.json || status=1
  safe_link "$ROOT/pi/mcp.json" ~/.pi/agent/mcp.json || status=1
  safe_link "$ROOT/pi/subagents.json" ~/.pi/agent/subagents.json || status=1
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

  # Herdr durable files only
  mkdir -p ~/.config/herdr/agent-detection
  safe_link "$ROOT/herdr/config.toml" ~/.config/herdr/config.toml || status=1
  safe_link "$ROOT/herdr/.gitignore" ~/.config/herdr/.gitignore || status=1
  safe_link "$ROOT/herdr/agent-detection/pi.toml" ~/.config/herdr/agent-detection/pi.toml || status=1

  if (( status == 0 )); then
    echo "Server dotfiles have been symlinked!"
  fi
  return "$status"
}

case $# in
  0)
    install_desktop
    ;;
  1)
    case "$1" in
      server)
        install_server
        ;;
      *)
        usage
        exit 1
        ;;
    esac
    ;;
  *)
    usage
    exit 1
    ;;
esac
