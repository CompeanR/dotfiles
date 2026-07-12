#!/bin/bash

ln -sf ~/dotfiles/alacritty/alacritty.yml ~/.config/alacritty/alacritty.yml
ln -sf ~/dotfiles/nvim/init.vim ~/.config/nvim/init.vim
ln -sf ~/dotfiles/tmux/.tmux.conf ~/.tmux.conf
ln -sfn ~/dotfiles/tmux/.config/tmux ~/.config/tmux
ln -sfn ~/dotfiles/tmux/scripts ~/scripts
ln -sf ~/dotfiles/vscode/settings.json ~/.config/Code/User/settings.json
ln -sf ~/dotfiles/vscode/keybindings.json ~/.config/Code/User/keybindings.json
ln -sf ~/dotfiles/ideavimrc ~/.ideavimrc
ln -sf ~/dotfiles/ghostty ~/.config/ghostty

# Pi agent config
mkdir -p ~/.pi/agent/npm
ln -sf ~/dotfiles/pi/settings.json ~/.pi/agent/settings.json
ln -sf ~/dotfiles/pi/mcp.json ~/.pi/agent/mcp.json
ln -sf ~/dotfiles/pi/subagents.json ~/.pi/agent/subagents.json
ln -sf ~/dotfiles/pi/cursor-sdk.json ~/.pi/agent/cursor-sdk.json
ln -sfn ~/dotfiles/pi/agents ~/.pi/agent/agents
ln -sfn ~/dotfiles/pi/chains ~/.pi/agent/chains
ln -sfn ~/dotfiles/pi/extensions ~/.pi/agent/extensions
ln -sfn ~/dotfiles/pi/themes ~/.pi/agent/themes
ln -sfn ~/dotfiles/pi/skills ~/.pi/agent/skills
ln -sfn ~/dotfiles/pi/gentle-ai ~/.pi/agent/gentle-ai
ln -sf ~/dotfiles/pi/npm/package.json ~/.pi/agent/npm/package.json
ln -sf ~/dotfiles/pi/npm/package-lock.json ~/.pi/agent/npm/package-lock.json

# Herdr config (durable files only; runtime state stays local)
mkdir -p ~/.config/herdr/agent-detection
ln -sf ~/dotfiles/herdr/config.toml ~/.config/herdr/config.toml
ln -sf ~/dotfiles/herdr/.gitignore ~/.config/herdr/.gitignore
ln -sf ~/dotfiles/herdr/agent-detection/pi.toml ~/.config/herdr/agent-detection/pi.toml

echo "Dotfiles have been symlinked!"

