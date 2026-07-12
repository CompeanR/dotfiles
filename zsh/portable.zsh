# Portable interactive Zsh settings (no desktop/Omarchy coupling).

# Prefer user-local binaries without hard-coding a username.
export PATH="$HOME/.local/bin:$PATH"

# History
setopt appendhistory
setopt hist_ignore_dups
setopt hist_ignore_space
HISTSIZE=32768
SAVEHIST="${HISTSIZE}"
HISTFILE="${HISTFILE:-$HOME/.zsh_history}"

# Editor
export EDITOR="${EDITOR:-nvim}"
export VISUAL="${VISUAL:-$EDITOR}"
export SUDO_EDITOR="${SUDO_EDITOR:-$EDITOR}"

# eza-backed ls aliases when available
if command -v eza >/dev/null 2>&1; then
  alias ls='eza -lh --group-directories-first --icons=auto'
  alias lsa='ls -a'
  alias lt='eza --tree --level=2 --long --icons --git'
  alias lta='lt -a'
fi

# bat / Debian batcat for man-page coloring
_bat=
if command -v bat >/dev/null 2>&1; then
  _bat=bat
elif command -v batcat >/dev/null 2>&1; then
  _bat=batcat
  alias bat=batcat
fi
if [[ -n $_bat ]]; then
  export BAT_THEME="${BAT_THEME:-ansi}"
  export MANROFFOPT="-c"
  export MANPAGER="sh -c 'col -bx | ${_bat} -l man -p'"
fi
unset _bat

# zoxide (optional)
if command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init zsh)"
fi

# fzf (optional): prefer fzf --zsh, else common distro paths
if command -v fzf >/dev/null 2>&1; then
  if fzf --help 2>&1 | grep -q -- '--zsh'; then
    source <(fzf --zsh)
  else
    for _fzf_file in \
      /usr/share/fzf/completion.zsh \
      /usr/share/doc/fzf/examples/completion.zsh \
      /usr/share/zsh/plugins/fzf/completion.zsh
    do
      [[ -f $_fzf_file ]] && source "$_fzf_file"
    done
    for _fzf_file in \
      /usr/share/fzf/key-bindings.zsh \
      /usr/share/doc/fzf/examples/key-bindings.zsh \
      /usr/share/zsh/plugins/fzf/key-bindings.zsh
    do
      [[ -f $_fzf_file ]] && source "$_fzf_file" && break
    done
    unset _fzf_file
  fi
fi
