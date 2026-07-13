# Portable PATH for interactive and non-interactive Zsh.
# Sourced for all zsh invocations; keep this file minimal.

typeset -U path
path=(
  "$HOME/.local/bin"
  "$HOME/.opencode/bin"
  "$HOME/.local/share/mise/shims"
  /usr/local/sbin
  /usr/local/bin
  /usr/sbin
  /usr/bin
  /sbin
  /bin
  $path
)
export PATH
