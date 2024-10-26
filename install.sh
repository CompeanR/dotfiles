#!/bin/bash

ln -sf ~/.dotfiles/alacritty/alacritty.yml ~/.config/alacritty/alacritty.yml
ln -sf ~/.dotfiles/nvim/init.vim ~/.config/nvim/init.vim
ln -sf ~/.dotfiles/tmux/.tmux.conf ~/.tmux.conf
ln -sf ~/.dotfiles/vscode/settings.json ~/.config/Code/User/settings.json
ln -sf ~/.dotfiles/vscode/keybindings.json ~/.config/Code/User/keybindings.json
ln -sf ~/.dotfiles/ideavimrc ~/.ideavimrc

echo "Dotfiles have been symlinked!"

