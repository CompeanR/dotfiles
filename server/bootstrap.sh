#!/usr/bin/env bash
# Ubuntu 24.04 amd64 VPS bootstrap / doctor / sandbox.
# Invoked via: ./install.sh server {bootstrap|doctor|sandbox|help} ...
set -euo pipefail

SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SERVER_DIR/.." && pwd)"
# shellcheck source=versions.env
source "$SERVER_DIR/versions.env"

DRY_RUN=0
ASSUME_YES=0
JSON=0
SANDBOX_APPLY=0
SANDBOX_DRY=0

# Test overrides (never set in production).
EUID_EFF="${DOTFILES_TEST_EUID:-$EUID}"
ARCH_EFF="$(uname -m)"
[[ -n "${DOTFILES_TEST_ARCH:-}" ]] && ARCH_EFF="$DOTFILES_TEST_ARCH"
APPARMOR_DST="${DOTFILES_TEST_APPARMOR_DST:-/etc/apparmor.d/bwrap-userns-restrict}"
USERNS_PATH="${DOTFILES_TEST_USERNS_PATH:-/proc/sys/kernel/apparmor_restrict_unprivileged_userns}"
BWRAP_BIN="${DOTFILES_TEST_BWRAP_BIN:-/usr/bin/bwrap}"
NPM_AI_PREFIX="$HOME/.local/opt/npm-ai"

TPM_PLUGINS=(tpm vim-tmux-navigator tmux-resurrect tmux-continuum)

log() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

is_dry() { (( DRY_RUN == 1 )); }

run() {
  if is_dry; then
    log "dry-run: $*"
    return 0
  fi
  "$@"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "refusing: required command missing: $1"
}

load_os() {
  local f="${DOTFILES_OS_RELEASE:-/etc/os-release}"
  # shellcheck disable=SC1090
  source "$f"
  OS_ID="${DOTFILES_TEST_OS_ID:-${ID:-}}"
  OS_VERSION="${DOTFILES_TEST_OS_VERSION:-${VERSION_ID:-}}"
}

guard_platform() {
  if (( EUID_EFF == 0 )); then
    die "refusing: do not run as root (use a sudo-capable user)"
  fi
  load_os
  if [[ "$OS_ID" != "ubuntu" || "$OS_VERSION" != "24.04" ]]; then
    die "refusing: unsupported OS (${OS_ID:-unknown} ${OS_VERSION:-unknown}); need Ubuntu 24.04"
  fi
  if [[ "$ARCH_EFF" != "x86_64" && "$ARCH_EFF" != "amd64" ]]; then
    die "refusing: unsupported arch ($ARCH_EFF); need amd64/x86_64"
  fi
}

print_plan() {
  cat <<EOF
Ubuntu 24.04 amd64 VPS bootstrap plan
=====================================
1. apt install --no-install-recommends: $APT_PACKAGES
2. safe-link server dotfiles (./install.sh server)
3. zsh/bootstrap.sh (Oh My Zsh + Powerlevel10k + autosuggestions)
4. install mise $MISE_VERSION -> ~/.local/bin; mise install node@$NODE_VERSION
5. install pinned tools into ~/.local (or ~/.opencode):
   - neovim $NEOVIM_VERSION (no Lazy sync; first interactive launch is manual)
   - tmux $TMUX_VERSION (build from source into ~/.local)
   - lazygit $LAZYGIT_VERSION
   - engram $ENGRAM_VERSION
   - herdr $HERDR_VERSION
   - opencode $OPENCODE_VERSION
   - gentle-ai $GENTLE_AI_VERSION (+ gentle-ai doctor)
6. install $PI_NPM_PACKAGE and $CODEX_NPM_PACKAGE in owned prefix $NPM_AI_PREFIX
7. TPM + plugins under ~/.tmux/plugins (errors not hidden)
8. npm ci in ~/.pi/agent/npm (legacy-peer-deps via linked .npmrc)

NOT automated (print-only next steps):
- Tailscale enrollment
- UFW / SSH hardening
- OAuth / device pairing
- VerseGuard clone
- Tailscale Serve
- systemd user service enablement
- AppArmor bwrap profile (use: ./install.sh server sandbox --apply)
- Ghostty terminfo (copy the client entry to the server manually)
- First interactive Neovim launch (Lazy/Mason)
EOF
}

confirm_bootstrap() {
  if (( ASSUME_YES == 1 )); then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    die "refusing: non-interactive bootstrap requires --yes"
  fi
  printf 'Type YES to proceed: '
  local ans
  read -r ans
  [[ "$ans" == "YES" ]] || die "aborted"
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

version_of() {
  local bin="$1" exe kind
  exe="$(command -v "$bin" 2>/dev/null)" || { printf ''; return 1; }
  kind="$(basename "$bin")"
  case "$kind" in
    nvim) "$exe" --version 2>/dev/null | head -n1 | awk '{print $2}' | sed 's/^v//' ;;
    tmux) "$exe" -V 2>/dev/null | awk '{print $2}' ;;
    pi) "$exe" --version 2>/dev/null | head -n1 | tr -d '[:space:]' ;;
    opencode) "$exe" --version 2>/dev/null | head -n1 | tr -d '[:space:]' ;;
    herdr) "$exe" --version 2>/dev/null | awk '{print $2}' ;;
    engram) "$exe" --version 2>/dev/null | head -n1 | awk '{print $NF}' | tr -d 'v' ;;
    lazygit) "$exe" --version 2>/dev/null | sed -n 's/.*version=\([^,]*\).*/\1/p' ;;
    codex) "$exe" --version 2>/dev/null | awk '{print $NF}' ;;
    mise) "$exe" --version 2>/dev/null | awk '{print $1}' ;;
    node) "$exe" --version 2>/dev/null | sed 's/^v//' ;;
    gentle-ai) "$exe" --version 2>/dev/null | awk '{print $NF}' ;;
    delta) "$exe" --version 2>/dev/null | awk '{print $2}' ;;
    eza) "$exe" --version 2>/dev/null | head -n1 | awk '{print $2}' ;;
    zoxide) "$exe" --version 2>/dev/null | awk '{print $2}' ;;
    mosh) "$exe" --version 2>/dev/null | head -n1 | awk '{print $2}' ;;
    *) printf '' ;;
  esac
}

have_exact_version() {
  # Dry-run must not execute host tools (nvim/opencode/mise write under $HOME).
  if is_dry; then
    return 1
  fi
  local bin="$1" want="$2" got
  got="$(version_of "$bin" || true)"
  [[ -n "$got" && "$got" == "$want" ]]
}

managed_marker() {
  local dest="$1" key
  key="$(printf '%s' "$dest" | sha256sum | awk '{print $1}')"
  printf '%s/managed/%s\n' "$HOME/.local/state/dotfiles-bootstrap" "$key"
}

is_managed_dest() {
  local dest="$1" marker
  marker="$(managed_marker "$dest")"
  [[ -f "$marker" && "$(cat "$marker")" == "$dest" ]]
}

mark_managed_dest() {
  local dest="$1" marker
  marker="$(managed_marker "$dest")"
  mkdir -p "$(dirname "$marker")"
  printf '%s\n' "$dest" >"$marker"
}

# Refuse every existing destination unless this bootstrap previously marked it.
refuse_or_ok_dest() {
  local dest="$1"
  if [[ ! -e "$dest" && ! -L "$dest" ]]; then
    return 0
  fi
  if [[ -L "$dest" ]]; then
    die "refusing: $dest is an unexpected symlink -> $(readlink "$dest")"
  fi
  if [[ -d "$dest" ]]; then
    die "refusing: $dest is a directory (unknown install)"
  fi
  if [[ ! -f "$dest" ]]; then
    die "refusing: $dest exists and is not a regular file"
  fi
  is_managed_dest "$dest" || die "refusing: $dest is an unowned regular file; move it aside explicitly"
}

download_verify() {
  local url="$1" dest="$2" expect="$3"
  if is_dry; then
    log "dry-run: download $url -> $dest (sha256=$expect)"
    return 0
  fi
  need_cmd curl
  need_cmd sha256sum
  mkdir -p "$(dirname "$dest")"
  if [[ -f "$dest" ]]; then
    local got
    got="$(sha256_file "$dest")"
    if [[ "$got" == "$expect" ]]; then
      log "cache hit (sha256 ok): $dest"
      return 0
    fi
    log "cache stale/mismatch, re-downloading: $dest"
    rm -f "$dest"
  fi
  curl -fsSL "$url" -o "$dest"
  local got
  got="$(sha256_file "$dest")"
  if [[ "$got" != "$expect" ]]; then
    rm -f "$dest"
    die "checksum mismatch for $dest (got $got want $expect)"
  fi
}

install_bin_from_tar() {
  local url="$1" sha="$2" member="$3" dest_name="$4" want_ver="${5:-}"
  local dest="$HOME/.local/bin/$dest_name"
  if ! is_dry; then
    refuse_or_ok_dest "$dest"
    if [[ -n "$want_ver" ]] && have_exact_version "$dest" "$want_ver"; then
      log "skip $dest_name: already $want_ver"
      return 0
    fi
  fi
  if is_dry; then
    log "dry-run: install $dest_name from $url (sha256=$sha)"
    return 0
  fi
  local tmp archive
  tmp="$(mktemp -d)"
  archive="$tmp/asset.tar.gz"
  download_verify "$url" "$archive" "$sha"
  tar -xzf "$archive" -C "$tmp"
  local found
  found="$(find "$tmp" -type f -name "$member" | head -n1)"
  [[ -n "$found" ]] || die "archive missing $member"
  mkdir -p "$HOME/.local/bin"
  install -m 0755 "$found" "$dest"
  mark_managed_dest "$dest"
  rm -rf "$tmp"
}

apt_base() {
  if is_dry; then
    log "dry-run: sudo apt-get update && sudo apt-get install -y --no-install-recommends $APT_PACKAGES"
    return 0
  fi
  need_cmd sudo
  # ponytail: apt noninteractive; ceiling=no pin versions — upgrade path=versions.env apt pins
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
  # shellcheck disable=SC2086
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $APT_PACKAGES
}

link_server() {
  if is_dry; then
    log "dry-run: $ROOT/install.sh server"
    return 0
  fi
  "$ROOT/install.sh" server
}

zsh_bootstrap() {
  if is_dry; then
    log "dry-run: $ROOT/zsh/bootstrap.sh"
    return 0
  fi
  "$ROOT/zsh/bootstrap.sh"
}

install_mise_node() {
  local archive="$HOME/.cache/dotfiles-bootstrap/mise.tar.gz"
  local mise_bin="$HOME/.local/bin/mise"
  local node_bin="$HOME/.local/share/mise/installs/node/$NODE_VERSION/bin/node"
  if ! is_dry; then
    refuse_or_ok_dest "$mise_bin"
    if have_exact_version "$mise_bin" "$MISE_VERSION" && have_exact_version "$node_bin" "$NODE_VERSION"; then
      log "skip mise/node: already managed mise $MISE_VERSION node $NODE_VERSION"
      return 0
    fi
  fi
  download_verify "$MISE_URL" "$archive" "$MISE_SHA256"
  if is_dry; then
    log "dry-run: extract mise -> ~/.local/bin; mise install node@$NODE_VERSION"
    return 0
  fi
  if ! have_exact_version "$mise_bin" "$MISE_VERSION"; then
    local tmp
    tmp="$(mktemp -d)"
    tar -xzf "$archive" -C "$tmp"
    local bin
    bin="$(find "$tmp" -type f -name mise | head -n1)"
    [[ -n "$bin" ]] || die "mise binary missing from archive"
    mkdir -p "$HOME/.local/bin"
    install -m 0755 "$bin" "$mise_bin"
    mark_managed_dest "$mise_bin"
    rm -rf "$tmp"
  fi
  export PATH="$HOME/.local/bin:$PATH"
  if have_exact_version "$node_bin" "$NODE_VERSION"; then
    log "skip managed node: already $NODE_VERSION"
    return 0
  fi
  "$mise_bin" install "node@$NODE_VERSION"
  "$mise_bin" use -g "node@$NODE_VERSION"
  have_exact_version "$node_bin" "$NODE_VERSION" || die "managed Node $NODE_VERSION missing after mise install"
}

# Managed nvim tree: ~/.local/nvim with bin/nvim (official linux x86_64 layout).
nvim_tree_managed() {
  local root="$1"
  [[ -x "$root/bin/nvim" && -d "$root/share/nvim" ]]
}

install_neovim() {
  local link="$HOME/.local/bin/nvim"
  local tree="$HOME/.local/nvim"
  if ! is_dry; then
    if [[ -e "$tree" || -L "$tree" ]]; then
      nvim_tree_managed "$tree" || die "refusing: $tree exists but is not a valid Neovim tree"
      is_managed_dest "$tree" || die "refusing: $tree is an unowned Neovim tree (no rm -rf of unknown installs)"
    fi
    if [[ -L "$link" ]]; then
      [[ "$(readlink "$link")" == "$tree/bin/nvim" ]] || die "refusing: $link is an unexpected symlink -> $(readlink "$link")"
    elif [[ -e "$link" ]]; then
      die "refusing: $link exists and is not the managed nvim symlink"
    fi
    if have_exact_version "$link" "$NEOVIM_VERSION"; then
      log "skip nvim: already $NEOVIM_VERSION"
      return 0
    fi
  fi
  local archive="$HOME/.cache/dotfiles-bootstrap/nvim.tar.gz"
  download_verify "$NEOVIM_URL" "$archive" "$NEOVIM_SHA256"
  if is_dry; then
    log "dry-run: install nvim $NEOVIM_VERSION under ~/.local"
    return 0
  fi
  local tmp
  tmp="$(mktemp -d)"
  tar -xzf "$archive" -C "$tmp"
  [[ -d "$tmp/nvim-linux-x86_64" ]] || die "nvim archive missing nvim-linux-x86_64/"
  mkdir -p "$HOME/.local"
  # Replace only a verified managed tree (or missing path).
  rm -rf "$tree"
  mv "$tmp/nvim-linux-x86_64" "$tree"
  mark_managed_dest "$tree"
  mkdir -p "$HOME/.local/bin"
  ln -sfn "$tree/bin/nvim" "$link"
  rm -rf "$tmp"
}

install_tmux() {
  local archive="$HOME/.cache/dotfiles-bootstrap/tmux.tar.gz"
  local dest="$HOME/.local/bin/tmux"
  if ! is_dry; then
    refuse_or_ok_dest "$dest"
    if have_exact_version "$dest" "$TMUX_VERSION"; then
      log "skip tmux: already $TMUX_VERSION"
      return 0
    fi
  fi
  download_verify "$TMUX_URL" "$archive" "$TMUX_SHA256"
  if is_dry; then
    log "dry-run: build tmux $TMUX_VERSION -> ~/.local"
    return 0
  fi
  local tmp
  tmp="$(mktemp -d)"
  tar -xzf "$archive" -C "$tmp"
  (
    cd "$tmp/tmux-$TMUX_VERSION"
    ./configure --prefix="$HOME/.local"
    make -j"$(nproc)"
    make install
  )
  mark_managed_dest "$dest"
  rm -rf "$tmp"
}

install_lazygit() {
  install_bin_from_tar "$LAZYGIT_URL" "$LAZYGIT_SHA256" lazygit lazygit "$LAZYGIT_VERSION"
}

install_engram() {
  install_bin_from_tar "$ENGRAM_URL" "$ENGRAM_SHA256" engram engram "$ENGRAM_VERSION"
}

install_herdr() {
  local dest="$HOME/.local/bin/herdr"
  if ! is_dry; then
    refuse_or_ok_dest "$dest"
    if have_exact_version "$dest" "$HERDR_VERSION"; then
      log "skip herdr: already $HERDR_VERSION"
      return 0
    fi
  fi
  local cache="$HOME/.cache/dotfiles-bootstrap/herdr"
  download_verify "$HERDR_URL" "$cache" "$HERDR_SHA256"
  if is_dry; then
    return 0
  fi
  mkdir -p "$HOME/.local/bin"
  install -m 0755 "$cache" "$dest"
  mark_managed_dest "$dest"
}

install_opencode() {
  local dest="$HOME/.opencode/bin/opencode"
  if ! is_dry; then
    refuse_or_ok_dest "$dest"
    if have_exact_version "$dest" "$OPENCODE_VERSION"; then
      log "skip opencode: already $OPENCODE_VERSION"
      return 0
    fi
  fi
  local archive="$HOME/.cache/dotfiles-bootstrap/opencode.tar.gz"
  download_verify "$OPENCODE_URL" "$archive" "$OPENCODE_SHA256"
  if is_dry; then
    log "dry-run: install opencode $OPENCODE_VERSION -> ~/.opencode/bin"
    return 0
  fi
  local tmp
  tmp="$(mktemp -d)"
  tar -xzf "$archive" -C "$tmp"
  local bin
  bin="$(find "$tmp" -type f -name opencode | head -n1)"
  [[ -n "$bin" ]] || die "opencode binary missing"
  mkdir -p "$HOME/.opencode/bin"
  install -m 0755 "$bin" "$dest"
  mark_managed_dest "$dest"
  rm -rf "$tmp"
}

install_gentle_ai() {
  install_bin_from_tar "$GENTLE_AI_URL" "$GENTLE_AI_SHA256" gentle-ai gentle-ai "$GENTLE_AI_VERSION"
  if is_dry; then
    log "dry-run: gentle-ai doctor"
    return 0
  fi
  export PATH="$HOME/.local/bin:$PATH"
  need_cmd gentle-ai
  have_exact_version gentle-ai "$GENTLE_AI_VERSION" || die "gentle-ai version mismatch after install"
  # Doctor may warn (duplicates etc.) but must not hide hard failures.
  gentle-ai doctor
}

install_npm_globals() {
  if is_dry; then
    log "dry-run: managed npm prefix $NPM_AI_PREFIX; install $PI_NPM_PACKAGE $CODEX_NPM_PACKAGE"
    return 0
  fi
  local mise_bin="$HOME/.local/bin/mise"
  local pi_bin="$NPM_AI_PREFIX/bin/pi"
  local codex_bin="$NPM_AI_PREFIX/bin/codex"
  have_exact_version "$mise_bin" "$MISE_VERSION" || die "managed mise is required for npm AI tools"
  if [[ -e "$NPM_AI_PREFIX" || -L "$NPM_AI_PREFIX" ]]; then
    [[ -d "$NPM_AI_PREFIX" ]] || die "refusing: $NPM_AI_PREFIX exists and is not a directory"
    is_managed_dest "$NPM_AI_PREFIX" || die "refusing: $NPM_AI_PREFIX is an unowned npm prefix"
  else
    mkdir -p "$NPM_AI_PREFIX"
    mark_managed_dest "$NPM_AI_PREFIX"
  fi
  local pi_ver codex_ver
  pi_ver="$(version_of "$pi_bin" || true)"
  codex_ver="$(version_of "$codex_bin" || true)"
  if [[ "$pi_ver" == "0.80.6" && "$codex_ver" == "$CODEX_VERSION" ]]; then
    log "skip managed npm tools: pi $pi_ver codex $codex_ver already pinned"
    return 0
  fi
  "$mise_bin" exec "node@$NODE_VERSION" -- npm install -g --prefix "$NPM_AI_PREFIX" \
    "$PI_NPM_PACKAGE" "$CODEX_NPM_PACKAGE"
  have_exact_version "$pi_bin" 0.80.6 || die "managed Pi version mismatch after npm install"
  have_exact_version "$codex_bin" "$CODEX_VERSION" || die "managed Codex version mismatch after npm install"
}

install_tpm() {
  if is_dry; then
    log "dry-run: clone TPM + install plugins"
    return 0
  fi
  need_cmd git
  need_cmd tmux
  local tpm="$HOME/.tmux/plugins/tpm"
  if [[ -d "$tpm/.git" ]]; then
    log "skip tpm clone: already present"
  elif [[ -e "$tpm" || -L "$tpm" ]]; then
    die "refusing: $tpm exists but is not a git checkout"
  else
    mkdir -p "$HOME/.tmux/plugins"
    git clone --depth 1 https://github.com/tmux-plugins/tpm "$tpm"
  fi
  [[ -x "$tpm/bin/install_plugins" ]] || die "TPM install_plugins missing"
  # Do not hide plugin install errors.
  "$tpm/bin/install_plugins"
  local p
  for p in "${TPM_PLUGINS[@]}"; do
    [[ -d "$HOME/.tmux/plugins/$p" ]] || die "TPM plugin missing after install: $p"
  done
}

pi_npm_ci() {
  if is_dry; then
    log "dry-run: npm ci in ~/.pi/agent/npm"
    return 0
  fi
  local mise_bin="$HOME/.local/bin/mise"
  have_exact_version "$mise_bin" "$MISE_VERSION" || die "managed mise is required for Pi npm dependencies"
  mkdir -p "$HOME/.pi/agent/npm"
  (
    cd "$HOME/.pi/agent/npm"
    "$mise_bin" exec "node@$NODE_VERSION" -- npm ci
  )
}

print_next_steps() {
  cat <<EOF

Manual next steps (not automated)
---------------------------------
1. Tailscale: install + enroll this host; join trusted devices.
2. UFW/SSH: allow SSH/Mosh only on tailscale0; disable root/password login.
3. Auth: OAuth for Pi/OpenCode/Codex (SSH -L tunnel for localhost callbacks).
4. Pairing: Moshi/iPhone or other clients via MagicDNS + SSH keys.
5. VerseGuard: clone under ~/development/VerseGuard; npm/mise project setup.
6. Tailscale Serve: HTTPS front for Metro (dev-client ATS requires HTTPS).
7. Sandbox: ./install.sh server sandbox --apply  (restricted /usr/bin/bwrap AppArmor).
8. Optional Metro: fill ~/.config/verseguard-metro.env then systemctl --user enable --now verseguard-metro.service
9. Neovim: first interactive \`nvim\` launch to finish Lazy/Mason (bootstrap does NOT run Lazy sync; Mason async abort risk).
10. Ghostty: copy xterm-ghostty/ghostty terminfo from the client to the server (warning-only in doctor).
11. Doctor: ./install.sh server doctor
EOF
}

cmd_bootstrap() {
  guard_platform
  print_plan
  if is_dry; then
    log "dry-run mode: zero mutation (no apt/sudo/network/downloads)"
    apt_base
    link_server
    zsh_bootstrap
    install_mise_node
    install_neovim
    install_tmux
    install_lazygit
    install_engram
    install_herdr
    install_opencode
    install_gentle_ai
    install_npm_globals
    install_tpm
    pi_npm_ci
    print_next_steps
    log "dry-run complete"
    return 0
  fi
  confirm_bootstrap
  mkdir -p "$HOME/.cache/dotfiles-bootstrap" "$HOME/.local/bin"
  apt_base
  link_server
  zsh_bootstrap
  install_mise_node
  install_neovim
  install_tmux
  install_lazygit
  install_engram
  install_herdr
  install_opencode
  install_gentle_ai
  install_npm_globals
  install_tpm
  pi_npm_ci
  print_next_steps
  log "bootstrap complete"
}

# ---- doctor ---------------------------------------------------------------

DOC_FAIL=0
DOC_WARN=0
declare -a DOC_ITEMS=()

doc_add() {
  DOC_ITEMS+=("$1|$2|$3")
  case "$1" in
    fail) DOC_FAIL=$((DOC_FAIL + 1)) ;;
    warn) DOC_WARN=$((DOC_WARN + 1)) ;;
  esac
}

link_ok() {
  local want="$1" link="$2"
  if [[ -L "$link" && "$(readlink "$link")" == "$want" ]]; then
    return 0
  fi
  return 1
}

cmd_have() {
  command -v "$1" >/dev/null 2>&1
}

doctor_require_cmd() {
  local code="$1" bin="$2"
  if cmd_have "$bin"; then
    doc_add ok "$code" "$bin present"
  else
    doc_add fail "$code" "$bin missing"
  fi
}

cmd_doctor() {
  export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$NPM_AI_PREFIX/bin:$HOME/.local/share/mise/shims:$PATH"

  # All server profile links (must match install.sh install_server).
  local pairs=(
    "$ROOT/zsh/.zshenv|$HOME/.zshenv"
    "$ROOT/zsh/.zshrc|$HOME/.zshrc"
    "$ROOT/nvim|$HOME/.config/nvim"
    "$ROOT/opencode|$HOME/.config/opencode"
    "$ROOT/tmux/.tmux.conf|$HOME/.tmux.conf"
    "$ROOT/tmux/.config/tmux|$HOME/.config/tmux"
    "$ROOT/tmux/scripts|$HOME/scripts"
    "$ROOT/lazygit/config.yml|$HOME/.config/lazygit/config.yml"
    "$ROOT/pi/settings.json|$HOME/.pi/agent/settings.json"
    "$ROOT/pi/mcp.json|$HOME/.pi/agent/mcp.json"
    "$ROOT/pi/subagents.json|$HOME/.pi/agent/subagents.json"
    "$ROOT/pi/cursor-sdk.json|$HOME/.pi/agent/cursor-sdk.json"
    "$ROOT/pi/agents|$HOME/.pi/agent/agents"
    "$ROOT/pi/chains|$HOME/.pi/agent/chains"
    "$ROOT/pi/extensions|$HOME/.pi/agent/extensions"
    "$ROOT/pi/themes|$HOME/.pi/agent/themes"
    "$ROOT/pi/skills|$HOME/.pi/agent/skills"
    "$ROOT/pi/gentle-ai|$HOME/.pi/agent/gentle-ai"
    "$ROOT/pi/npm/package.json|$HOME/.pi/agent/npm/package.json"
    "$ROOT/pi/npm/package-lock.json|$HOME/.pi/agent/npm/package-lock.json"
    "$ROOT/pi/npm/.npmrc|$HOME/.pi/agent/npm/.npmrc"
    "$ROOT/herdr/config.toml|$HOME/.config/herdr/config.toml"
    "$ROOT/herdr/.gitignore|$HOME/.config/herdr/.gitignore"
    "$ROOT/herdr/agent-detection/pi.toml|$HOME/.config/herdr/agent-detection/pi.toml"
    "$ROOT/systemd/user/verseguard-metro.service|$HOME/.config/systemd/user/verseguard-metro.service"
  )
  local p want link
  for p in "${pairs[@]}"; do
    want="${p%%|*}"
    link="${p#*|}"
    if link_ok "$want" "$link"; then
      doc_add ok links "ok: $link"
    else
      doc_add fail links "missing or wrong link: $link"
    fi
  done

  case ":$PATH:" in
    *":$HOME/.local/bin:"*) doc_add ok path "ok: ~/.local/bin on PATH" ;;
    *) doc_add fail path "PATH missing ~/.local/bin" ;;
  esac

  local ver
  ver="$(version_of nvim || true)"
  if [[ "$ver" == "$NEOVIM_VERSION" ]]; then doc_add ok nvim "nvim $ver"; else doc_add fail nvim "nvim want $NEOVIM_VERSION got ${ver:-missing}"; fi
  ver="$(version_of tmux || true)"
  if [[ "$ver" == "$TMUX_VERSION" ]]; then doc_add ok tmux "tmux $ver"; else doc_add fail tmux "tmux want $TMUX_VERSION got ${ver:-missing}"; fi
  ver="$(version_of "$NPM_AI_PREFIX/bin/pi" || true)"
  if [[ "$ver" == "0.80.6" ]]; then doc_add ok pi "managed pi $ver"; else doc_add fail pi "managed pi want 0.80.6 got ${ver:-missing}"; fi
  ver="$(version_of opencode || true)"
  if [[ "$ver" == "$OPENCODE_VERSION" ]]; then doc_add ok opencode "opencode $ver"; else doc_add fail opencode "opencode want $OPENCODE_VERSION got ${ver:-missing}"; fi
  ver="$(version_of herdr || true)"
  if [[ "$ver" == "$HERDR_VERSION" ]]; then doc_add ok herdr "herdr $ver"; else doc_add fail herdr "herdr want $HERDR_VERSION got ${ver:-missing}"; fi
  ver="$(version_of engram || true)"
  if [[ "$ver" == "$ENGRAM_VERSION" ]]; then doc_add ok engram "engram $ver"; else doc_add fail engram "engram want $ENGRAM_VERSION got ${ver:-missing}"; fi
  ver="$(version_of lazygit || true)"
  if [[ "$ver" == "$LAZYGIT_VERSION" ]]; then doc_add ok lazygit "lazygit $ver"; else doc_add fail lazygit "lazygit want $LAZYGIT_VERSION got ${ver:-missing}"; fi
  ver="$(version_of gentle-ai || true)"
  if [[ "$ver" == "$GENTLE_AI_VERSION" ]]; then doc_add ok gentle_ai "gentle-ai $ver"; else doc_add fail gentle_ai "gentle-ai want $GENTLE_AI_VERSION got ${ver:-missing}"; fi
  ver="$(version_of "$NPM_AI_PREFIX/bin/codex" || true)"
  if [[ "$ver" == "$CODEX_VERSION" ]]; then doc_add ok codex "managed codex $ver"; else doc_add fail codex "managed codex want $CODEX_VERSION got ${ver:-missing}"; fi
  ver="$(version_of "$HOME/.local/share/mise/installs/node/$NODE_VERSION/bin/node" || true)"
  if [[ "$ver" == "$NODE_VERSION" ]]; then doc_add ok node "managed node $ver"; else doc_add fail node "managed node want $NODE_VERSION got ${ver:-missing}"; fi
  ver="$(version_of mise || true)"
  if [[ "$ver" == "$MISE_VERSION" ]]; then doc_add ok mise "mise $ver"; else doc_add fail mise "mise want $MISE_VERSION got ${ver:-missing}"; fi

  # Core apt / PATH tools
  doctor_require_cmd mosh mosh
  doctor_require_cmd jq jq
  doctor_require_cmd python3 python3
  doctor_require_cmd ripgrep rg
  if cmd_have fd || cmd_have fdfind; then
    doc_add ok fd "fd/fdfind present"
  else
    doc_add fail fd "fd/fdfind missing"
  fi
  doctor_require_cmd fzf fzf
  doctor_require_cmd zoxide zoxide
  doctor_require_cmd eza eza
  if cmd_have bat || cmd_have batcat; then
    doc_add ok bat "bat/batcat present"
  else
    doc_add fail bat "bat/batcat missing"
  fi
  doctor_require_cmd delta delta

  # TPM + plugins + tmux-256color
  local plugin
  for plugin in "${TPM_PLUGINS[@]}"; do
    if [[ -d "$HOME/.tmux/plugins/$plugin" ]]; then
      doc_add ok "tpm_$plugin" "plugin $plugin present"
    else
      doc_add fail "tpm_$plugin" "plugin $plugin missing"
    fi
  done
  if infocmp tmux-256color >/dev/null 2>&1; then
    doc_add ok terminfo_tmux "tmux-256color present"
  else
    doc_add fail terminfo_tmux "tmux-256color terminfo missing"
  fi

  # bwrap / AppArmor
  if [[ -x /usr/bin/bwrap ]]; then
    doc_add ok bwrap "bwrap present"
  else
    doc_add fail bwrap "/usr/bin/bwrap missing"
  fi
  if [[ -f "$APPARMOR_DST" ]]; then
    if cmp -s "$SERVER_DIR/apparmor/bwrap-userns-restrict" "$APPARMOR_DST"; then
      doc_add ok apparmor "bwrap-userns-restrict profile matches tracked"
    else
      doc_add warn apparmor "bwrap profile present but differs from tracked"
    fi
  else
    doc_add warn apparmor "bwrap AppArmor profile not installed (run server sandbox --apply)"
  fi
  local userns
  userns="$(cat "$USERNS_PATH" 2>/dev/null || echo missing)"
  if [[ "$userns" == "1" ]]; then
    doc_add ok userns "apparmor_restrict_unprivileged_userns=1"
  else
    doc_add warn userns "apparmor_restrict_unprivileged_userns=$userns (expected 1)"
  fi

  # Tailscale (presence only)
  if cmd_have tailscale; then
    if tailscale status >/dev/null 2>&1; then
      doc_add ok tailscale "tailscale up"
    else
      doc_add warn tailscale "tailscale installed but not up"
    fi
  else
    doc_add warn tailscale "tailscale not installed"
  fi

  # Ghostty terminfo — warning/manual client recipe only
  if infocmp xterm-ghostty >/dev/null 2>&1 || infocmp ghostty >/dev/null 2>&1; then
    doc_add ok terminfo_ghostty "ghostty terminfo present"
  else
    doc_add warn terminfo_ghostty "ghostty/xterm-ghostty terminfo missing (copy client entry to server)"
  fi

  # Auth indicators without secrets
  if [[ -d "$HOME/.pi/agent" ]]; then
    if find "$HOME/.pi/agent" -maxdepth 3 \( -name 'auth.json' -o -name 'auth.json.bak' -o -name '.auth*' \) 2>/dev/null | grep -q .; then
      doc_add ok auth_pi "pi auth material present (paths only)"
    else
      doc_add warn auth_pi "no pi auth files detected"
    fi
  else
    doc_add warn auth_pi "~/.pi/agent missing"
  fi
  if [[ -f "$HOME/.codex/auth.json" || -f "$HOME/.codex/config.toml" ]]; then
    doc_add ok auth_codex "codex config/auth present (paths only)"
  else
    doc_add warn auth_codex "codex auth/config not detected"
  fi

  if [[ -d "$HOME/development/VerseGuard" ]]; then
    doc_add ok verseguard "VerseGuard checkout present"
  else
    doc_add warn verseguard "VerseGuard checkout missing"
  fi
  if [[ -f "$HOME/.config/verseguard-metro.env" ]]; then
    doc_add ok metro_env "verseguard-metro.env present"
  else
    doc_add warn metro_env "verseguard-metro.env missing (optional)"
  fi
  if systemctl --user is-enabled verseguard-metro.service >/dev/null 2>&1; then
    doc_add warn metro_unit "verseguard-metro.service is enabled (bootstrap never enables it)"
  else
    doc_add ok metro_unit "verseguard-metro.service not enabled"
  fi

  if (( JSON == 1 )); then
    need_cmd python3
    printf '{\n  "fail": %s,\n  "warn": %s,\n  "items": [\n' "$DOC_FAIL" "$DOC_WARN"
    local level code msg rest first=1
    for item in "${DOC_ITEMS[@]}"; do
      level="${item%%|*}"
      rest="${item#*|}"
      code="${rest%%|*}"
      msg="${rest#*|}"
      if (( first )); then first=0; else printf ',\n'; fi
      printf '    {"level":"%s","code":"%s","message":' "$level" "$code"
      python3 -c 'import json,sys; print(json.dumps(sys.argv[1]), end="")' "$msg"
      printf '}'
    done
    printf '\n  ]\n}\n'
  else
    local item level code msg rest
    for item in "${DOC_ITEMS[@]}"; do
      level="${item%%|*}"
      rest="${item#*|}"
      code="${rest%%|*}"
      msg="${rest#*|}"
      printf '[%s] %s: %s\n' "$level" "$code" "$msg"
    done
    printf 'summary: fail=%s warn=%s\n' "$DOC_FAIL" "$DOC_WARN"
  fi

  (( DOC_FAIL == 0 ))
}

# ---- sandbox --------------------------------------------------------------

sandbox_smoke() {
  if is_dry || (( SANDBOX_DRY == 1 )); then
    log "dry-run: bwrap smoke-test skipped"
    return 0
  fi
  "$BWRAP_BIN" --unshare-user --uid 65534 --gid 65534 --ro-bind / / --dev /dev --proc /proc -- /bin/true
}

cmd_sandbox() {
  guard_platform
  local profile_src="$SERVER_DIR/apparmor/bwrap-userns-restrict"
  local profile_dst="$APPARMOR_DST"
  local identical=0

  if (( SANDBOX_APPLY == 0 && SANDBOX_DRY == 0 )); then
    cat <<EOF
Sandbox (AppArmor bwrap) — separate from bootstrap
==================================================
Would install reviewed restricted profile:
  $profile_src -> $profile_dst
Then: sudo apparmor_parser -r $profile_dst
Smoke-test /usr/bin/bwrap while keeping kernel.apparmor_restrict_unprivileged_userns=1

Dry-run is a no-op when the destination already matches. Apply reloads an
identical profile so a prior parser failure can be repaired.
Refuses when the destination exists and differs (unknown/foreign profile).

Refusing to mutate. Pass --dry-run or --apply.
For --apply, you must type: APPLY SANDBOX
EOF
    return 1
  fi

  [[ -f "$profile_src" ]] || die "missing profile: $profile_src"
  if [[ -f "$profile_dst" ]] && cmp -s "$profile_src" "$profile_dst"; then
    identical=1
  elif [[ -e "$profile_dst" || -L "$profile_dst" ]]; then
    die "refusing: $profile_dst exists and differs from tracked restricted profile (will not overwrite unknown profile)"
  fi

  if (( SANDBOX_DRY == 1 )); then
    if (( identical == 1 )); then
      log "sandbox: profile already identical at $profile_dst (dry-run no-op)"
    else
      log "dry-run: sudo install -m 0644 $profile_src $profile_dst"
    fi
    log "dry-run: verify apparmor_restrict_unprivileged_userns=1"
    log "dry-run: sudo apparmor_parser -r $profile_dst"
    log "dry-run: bwrap smoke-test"
    return 0
  fi

  # Check the safety invariant before any profile mutation or reload.
  local userns
  userns="$(cat "$USERNS_PATH" 2>/dev/null || echo missing)"
  if [[ "$userns" != "1" ]]; then
    die "refusing: apparmor_restrict_unprivileged_userns=$userns (expected 1); will not mutate AppArmor state"
  fi
  [[ -x "$BWRAP_BIN" ]] || die "refusing: /usr/bin/bwrap is missing; run bootstrap first"

  if [[ "${DOTFILES_TEST_TTY:-0}" != "1" && ! -t 0 ]]; then
    die "refusing: sandbox --apply requires an interactive TTY for confirmation"
  fi
  printf 'Type APPLY SANDBOX to continue: '
  local ans
  read -r ans
  [[ "$ans" == "APPLY SANDBOX" ]] || die "aborted"

  need_cmd sudo
  if (( identical == 0 )); then
    sudo install -m 0644 "$profile_src" "$profile_dst"
    if ! sudo apparmor_parser -r "$profile_dst"; then
      sudo rm -f "$profile_dst" || true
      die "AppArmor parser failed; removed the newly installed profile"
    fi
  else
    log "sandbox: profile already identical; reloading to verify it is active"
    sudo apparmor_parser -r "$profile_dst" || die "AppArmor parser failed while reloading the existing profile"
  fi

  sandbox_smoke
  log "sandbox profile loaded; bwrap smoke-test ok; userns restriction still enabled"
}

usage_server() {
  cat <<EOF
Usage: $(basename "$0") server <command> [options]
       ./install.sh server <command> [options]

Commands:
  bootstrap [--dry-run] [--yes]   Explicit Ubuntu 24.04 amd64 bootstrap
  doctor [--json]                 Read-only health checks
  sandbox [--dry-run|--apply]     Restricted /usr/bin/bwrap AppArmor profile
  help                            Show this help

Legacy:
  (no args)        Desktop force-link profile
  server           Safe server symlink profile only
EOF
}

# ---- argv ---------------------------------------------------------------

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    bootstrap)
      while (($#)); do
        case "$1" in
          --dry-run) DRY_RUN=1 ;;
          --yes) ASSUME_YES=1 ;;
          -h|--help) usage_server; return 0 ;;
          *) die "unknown bootstrap flag: $1" ;;
        esac
        shift
      done
      cmd_bootstrap
      ;;
    doctor)
      while (($#)); do
        case "$1" in
          --json) JSON=1 ;;
          -h|--help) usage_server; return 0 ;;
          *) die "unknown doctor flag: $1" ;;
        esac
        shift
      done
      cmd_doctor
      ;;
    sandbox)
      while (($#)); do
        case "$1" in
          --dry-run) SANDBOX_DRY=1 ;;
          --apply) SANDBOX_APPLY=1 ;;
          -h|--help) usage_server; return 0 ;;
          *) die "unknown sandbox flag: $1" ;;
        esac
        shift
      done
      if (( SANDBOX_APPLY == 1 && SANDBOX_DRY == 1 )); then
        die "refusing: pass only one of --dry-run or --apply"
      fi
      cmd_sandbox
      ;;
    help|-h|--help|"")
      usage_server
      ;;
    *)
      usage_server
      die "unknown server command: $cmd"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
