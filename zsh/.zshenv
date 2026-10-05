# Portable PATH for interactive and non-interactive Zsh.
# Sourced for all zsh invocations; keep this file minimal.

typeset -U path
path=(
  "$HOME/.local/bin"
  "$HOME/.opencode/bin"
  "$HOME/.local/opt/npm-ai/bin"
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
[[ -f "$HOME/.cargo/env" ]] && . "$HOME/.cargo/env"

# pi sends OSC 52 only in SSH/mosh sessions; a herdr client may be on another machine.
if [[ -n $HERDR_PANE_ID ]]; then
  pi() { MOSH_CONNECTION="${MOSH_CONNECTION:-herdr}" command pi "$@" }
fi
