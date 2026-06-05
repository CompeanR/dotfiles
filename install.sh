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

echo "Dotfiles have been symlinked!"

