# Portable Oh My Zsh + Powerlevel10k profile (secret-free).
# Machine-specific overrides belong in ~/.zshrc.local (not tracked).

typeset -g POWERLEVEL9K_INSTANT_PROMPT=off
# Instant prompt stays off for safer remote/SSH startup (console input, MOTD, etc.).
# Re-enable in ~/.zshrc.local if desired after verifying the host is quiet at startup.

# Path to Oh My Zsh.
export ZSH="${ZSH:-$HOME/.oh-my-zsh}"

if [[ ! -r "$ZSH/oh-my-zsh.sh" ]]; then
  print -u2 'Oh My Zsh missing. Run zsh/bootstrap.sh from this repository, then open a new shell.'
  return
fi

ZSH_THEME="powerlevel10k/powerlevel10k"
plugins=(git zsh-autosuggestions)

source "$ZSH/oh-my-zsh.sh"

# Directory of this file (works when ~/.zshrc is a symlink into the repo).
ZSH_DOTFILES="${${(%):-%x}:A:h}"

[[ -f "$ZSH_DOTFILES/portable.zsh" ]] && source "$ZSH_DOTFILES/portable.zsh"
[[ -f "$ZSH_DOTFILES/.p10k.zsh" ]] && source "$ZSH_DOTFILES/.p10k.zsh"
[[ -f "$HOME/.zshrc.local" ]] && source "$HOME/.zshrc.local"
