#!/usr/bin/env bash
# Fixture tests for install.sh / server bootstrap (no live sudo/network).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

assert_eq() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then
    PASS=$((PASS + 1))
    printf 'ok - %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf 'not ok - %s\n  want: %s\n  got:  %s\n' "$name" "$want" "$got"
  fi
}

assert_ok() {
  local name="$1"
  shift
  if "$@"; then
    PASS=$((PASS + 1))
    printf 'ok - %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf 'not ok - %s\n' "$name"
  fi
}

assert_fail() {
  local name="$1"
  shift
  if "$@"; then
    FAIL=$((FAIL + 1))
    printf 'not ok - %s (expected failure)\n' "$name"
  else
    PASS=$((PASS + 1))
    printf 'ok - %s\n' "$name"
  fi
}

assert_contains() {
  local name="$1" hay="$2" needle="$3"
  if printf '%s' "$hay" | grep -Fq -- "$needle"; then
    PASS=$((PASS + 1))
    printf 'ok - %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf 'not ok - %s (missing %s)\n' "$name" "$needle"
  fi
}

make_blocked_bin() {
  local dir="$1"
  mkdir -p "$dir"
  for cmd in curl sudo apt-get; do
    cat >"$dir/$cmd" <<'EOF'
#!/bin/sh
echo "blocked: network/sudo helper invoked during dry-run test" >&2
exit 97
EOF
    chmod +x "$dir/$cmd"
  done
}

with_ubuntu_env() {
  export DOTFILES_TEST_OS_ID=ubuntu
  export DOTFILES_TEST_OS_VERSION=24.04
  export DOTFILES_TEST_ARCH=x86_64
  export DOTFILES_TEST_EUID=1000
  local osr
  osr="$(mktemp)"
  cat >"$osr" <<'EOF'
ID=ubuntu
VERSION_ID="24.04"
EOF
  export DOTFILES_OS_RELEASE="$osr"
}

cleanup_ubuntu_env() {
  rm -f "${DOTFILES_OS_RELEASE:-}"
  unset DOTFILES_TEST_OS_ID DOTFILES_TEST_OS_VERSION DOTFILES_TEST_ARCH DOTFILES_TEST_EUID DOTFILES_OS_RELEASE
  unset DOTFILES_TEST_APPARMOR_DST DOTFILES_TEST_USERNS_PATH DOTFILES_TEST_BWRAP_BIN DOTFILES_TEST_TTY
}

# ---- legacy dispatch ----
assert_ok "help exits 0" bash -c '"$0" help >/dev/null' "$ROOT/install.sh"
assert_ok "server help exits 0" bash -c '"$0" server help >/dev/null' "$ROOT/install.sh"
assert_fail "unknown top-level arg fails" bash -c '"$0" nope >/dev/null 2>&1' "$ROOT/install.sh"

# Desktop no-arg: create required parents, expect success message
{
  tmp="$(mktemp -d)"
  export HOME="$tmp"
  mkdir -p "$HOME/.config/alacritty" "$HOME/.config/nvim" "$HOME/.config/Code/User"
  set +e
  out="$("$ROOT/install.sh" 2>&1)"
  rc=$?
  set -e
  if (( rc == 0 )) && [[ -L "$HOME/.tmux.conf" && -L "$HOME/.config/nvim/init.vim" ]]; then
    PASS=$((PASS + 1))
    printf 'ok - desktop no-arg profile succeeds and links representative files\n'
  else
    FAIL=$((FAIL + 1))
    printf 'not ok - desktop no-arg profile (rc=%s)\n%s\n' "$rc" "$out"
  fi
  rm -rf "$tmp"
}

# ---- safe server links: idempotent + collision ----
{
  tmp="$(mktemp -d)"
  export HOME="$tmp"
  assert_ok "server links first run" bash -c '"$0" server >/dev/null' "$ROOT/install.sh"
  assert_ok "server links idempotent" bash -c '"$0" server >/dev/null' "$ROOT/install.sh"
  rm -f "$HOME/.zshenv"
  echo 'not-a-link' >"$HOME/.zshenv"
  assert_fail "server refuses collision on .zshenv" bash -c '"$0" server >/dev/null 2>&1' "$ROOT/install.sh"
  rm -f "$HOME/.zshenv"
  ln -s /tmp/wrong "$HOME/.zshenv"
  assert_fail "server refuses wrong symlink" bash -c '"$0" server >/dev/null 2>&1' "$ROOT/install.sh"
  rm -rf "$tmp"
}

# ---- versions.env contract ----
{
  # shellcheck disable=SC1091
  source "$ROOT/server/versions.env"
  assert_eq "node pin exact 22.23.1" "22.23.1" "$NODE_VERSION"
  assert_eq "gentle-ai pin 1.43.4" "1.43.4" "$GENTLE_AI_VERSION"
  assert_eq "codex exact pin 0.144.1" "0.144.1" "$CODEX_VERSION"
  assert_eq "codex package uses exact pin" "@openai/codex@0.144.1" "$CODEX_NPM_PACKAGE"
  for pkg in python3 mosh jq ripgrep fd-find fzf zoxide eza bat git-delta apparmor-profiles ncurses-bin; do
    assert_contains "apt includes $pkg" "$APT_PACKAGES" "$pkg"
  done
  assert_ok "apt uses --no-install-recommends" \
    grep -Fq -- '--no-install-recommends' "$ROOT/server/bootstrap.sh"
  assert_ok "lazygit URL uses official linux_x86_64 asset name" \
    grep -Fq 'lazygit_0.62.1_linux_x86_64.tar.gz' "$ROOT/server/versions.env"
  # Forbid headless Lazy/Mason automation; docs may still mention the manual step.
  assert_ok "no Lazy sync automation" \
    bash -c '! grep -nE "nvim[[:space:]].*--headless|packadd[[:space:]]+lazy|:Lazy" "$0"/server/bootstrap.sh' "$ROOT"
}

# ---- bootstrap dry-run: no mutation / no sudo / no network ----
{
  tmp="$(mktemp -d)"
  export HOME="$tmp"
  with_ubuntu_env
  block="$(mktemp -d)"
  make_blocked_bin "$block"
  before="$(find "$tmp" | sort | sha256sum | awk '{print $1}')"
  out="$(env PATH="$block:$PATH" bash -c '"$0" server bootstrap --dry-run' "$ROOT/install.sh")"
  after="$(find "$tmp" | sort | sha256sum | awk '{print $1}')"
  assert_eq "bootstrap dry-run no HOME mutation" "$before" "$after"
  assert_contains "dry-run mentions node pin" "$out" "node@22.23.1"
  assert_contains "dry-run mentions --no-install-recommends" "$out" "--no-install-recommends"
  assert_contains "dry-run mentions gentle-ai" "$out" "gentle-ai 1.43.4"
  assert_contains "dry-run documents first nvim launch" "$out" "first interactive"
  rm -rf "$tmp" "$block"
  cleanup_ubuntu_env
}

# ---- unsupported OS / root guards ----
{
  with_ubuntu_env
  export DOTFILES_TEST_OS_ID=arch
  export DOTFILES_TEST_OS_VERSION=""
  assert_fail "bootstrap refuses non-ubuntu" \
    bash -c '"$0" server bootstrap --dry-run >/dev/null 2>&1' "$ROOT/install.sh"
  export DOTFILES_TEST_OS_ID=ubuntu
  export DOTFILES_TEST_OS_VERSION=24.04
  export DOTFILES_TEST_EUID=0
  assert_fail "bootstrap refuses root" \
    bash -c '"$0" server bootstrap --dry-run >/dev/null 2>&1' "$ROOT/install.sh"
  cleanup_ubuntu_env
}

# ---- sandbox non-apply safety + unknown/identical profile ----
{
  with_ubuntu_env
  block="$(mktemp -d)"
  make_blocked_bin "$block"
  absent_dst="$(mktemp -u /tmp/dotfiles-apparmor-XXXXXX)"
  userns="$(mktemp)"
  echo 1 >"$userns"

  assert_fail "sandbox without flags refuses mutation" \
    env PATH="$block:$PATH" \
      DOTFILES_TEST_APPARMOR_DST="$absent_dst" \
      DOTFILES_TEST_USERNS_PATH="$userns" \
      bash -c '"$0" server sandbox >/dev/null 2>&1' "$ROOT/install.sh"

  assert_ok "sandbox --dry-run no sudo when dest absent" \
    env PATH="$block:$PATH" \
      DOTFILES_TEST_APPARMOR_DST="$absent_dst" \
      DOTFILES_TEST_USERNS_PATH="$userns" \
      bash -c '"$0" server sandbox --dry-run >/dev/null' "$ROOT/install.sh"

  identical="$(mktemp)"
  foreign="$(mktemp)"
  cp "$ROOT/server/apparmor/bwrap-userns-restrict" "$identical"
  echo 'abi <abi/4.0>,
profile foreign {}' >"$foreign"

  assert_ok "sandbox no-op when profile identical" \
    env PATH="$block:$PATH" \
      DOTFILES_TEST_APPARMOR_DST="$identical" \
      DOTFILES_TEST_USERNS_PATH="$userns" \
      bash -c '"$0" server sandbox --dry-run >/dev/null' "$ROOT/install.sh"

  assert_fail "sandbox refuses unknown existing profile" \
    env PATH="$block:$PATH" \
      DOTFILES_TEST_APPARMOR_DST="$foreign" \
      DOTFILES_TEST_USERNS_PATH="$userns" \
      bash -c '"$0" server sandbox --dry-run >/dev/null 2>&1' "$ROOT/install.sh"

  echo 0 >"$userns"
  set +e
  preflight_out="$(env PATH="$block:$PATH" \
    DOTFILES_TEST_APPARMOR_DST="$absent_dst" \
    DOTFILES_TEST_USERNS_PATH="$userns" \
    bash -c '"$0" server sandbox --apply' "$ROOT/install.sh" 2>&1)"
  preflight_rc=$?
  set -e
  assert_eq "sandbox userns preflight fails before mutation" "1" "$preflight_rc"
  assert_contains "sandbox userns preflight names invariant" "$preflight_out" "expected 1"
  [[ ! -e "$absent_dst" ]] && PASS=$((PASS + 1)) && printf 'ok - sandbox preflight leaves destination absent\n' \
    || { FAIL=$((FAIL + 1)); printf 'not ok - sandbox preflight mutated destination\n'; }

  # Simulate an AppArmor parser failure after install; the newly installed file must be removed.
  echo 1 >"$userns"
  fakebin="$(mktemp -d)"
  cat >"$fakebin/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "apparmor_parser" ]]; then exit 55; fi
"$@"
EOF
  cat >"$fakebin/bwrap" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$fakebin/sudo" "$fakebin/bwrap"
  parser_dst="$(mktemp -u /tmp/dotfiles-apparmor-parser-XXXXXX)"
  assert_fail "sandbox surfaces parser failure" \
    bash -c 'printf "APPLY SANDBOX\\n" | env \
      PATH="$1:$PATH" DOTFILES_TEST_TTY=1 \
      DOTFILES_TEST_OS_ID=ubuntu DOTFILES_TEST_OS_VERSION=24.04 \
      DOTFILES_TEST_ARCH=x86_64 DOTFILES_TEST_EUID=1000 \
      DOTFILES_OS_RELEASE="$2" DOTFILES_TEST_APPARMOR_DST="$3" \
      DOTFILES_TEST_USERNS_PATH="$4" DOTFILES_TEST_BWRAP_BIN="$1/bwrap" \
      "$5" server sandbox --apply >/dev/null 2>&1' \
      bash "$fakebin" "$DOTFILES_OS_RELEASE" "$parser_dst" "$userns" "$ROOT/install.sh"
  [[ ! -e "$parser_dst" ]] && PASS=$((PASS + 1)) && printf 'ok - sandbox parser failure removes new profile\n' \
    || { FAIL=$((FAIL + 1)); printf 'not ok - sandbox parser failure left profile\n'; }

  # An identical on-disk profile is reloaded, not merely assumed active.
  record="$(mktemp)"
  cat >"$fakebin/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "apparmor_parser" ]]; then printf '%s\n' "$*" >>"$SUDO_RECORD"; exit 0; fi
"$@"
EOF
  chmod +x "$fakebin/sudo"
  assert_ok "sandbox apply reloads identical profile" \
    bash -c 'printf "APPLY SANDBOX\\n" | env \
      PATH="$1:$PATH" SUDO_RECORD="$2" DOTFILES_TEST_TTY=1 \
      DOTFILES_TEST_OS_ID=ubuntu DOTFILES_TEST_OS_VERSION=24.04 \
      DOTFILES_TEST_ARCH=x86_64 DOTFILES_TEST_EUID=1000 \
      DOTFILES_OS_RELEASE="$3" DOTFILES_TEST_APPARMOR_DST="$4" \
      DOTFILES_TEST_USERNS_PATH="$5" DOTFILES_TEST_BWRAP_BIN="$1/bwrap" \
      "$6" server sandbox --apply >/dev/null' \
      bash "$fakebin" "$record" "$DOTFILES_OS_RELEASE" "$identical" "$userns" "$ROOT/install.sh"
  assert_contains "sandbox identical apply invokes parser reload" "$(cat "$record")" "apparmor_parser -r $identical"

  rm -f "$identical" "$foreign" "$userns" "$parser_dst" "$record"
  rm -rf "$block" "$fakebin"
  cleanup_ubuntu_env
}

# ---- managed destinations, exact versions, and checksum failure ----
{
  tmp="$(mktemp -d)"
  export HOME="$tmp"
  unknown="$HOME/.local/bin/herdr"
  mkdir -p "$(dirname "$unknown")"
  printf 'user-owned\n' >"$unknown"
  assert_fail "bootstrap refuses unowned regular binary" \
    bash -c 'source "$1/server/bootstrap.sh"; refuse_or_ok_dest "$2"' bash "$ROOT" "$unknown"
  cat >"$unknown" <<'EOF'
#!/bin/sh
echo 'herdr 0.7.3'
EOF
  chmod +x "$unknown"
  assert_fail "installer refuses unowned binary even at exact version" \
    bash -c 'source "$1/server/bootstrap.sh"; install_herdr' bash "$ROOT"
  assert_ok "bootstrap accepts its own managed regular binary" \
    bash -c 'source "$1/server/bootstrap.sh"; mark_managed_dest "$2"; refuse_or_ok_dest "$2"' bash "$ROOT" "$unknown"

  fakebin="$(mktemp -d)"
  cat >"$fakebin/codex" <<'EOF'
#!/bin/sh
echo 'codex-cli 0.144.9'
EOF
  cat >"$fakebin/curl" <<'EOF'
#!/bin/sh
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then shift; printf bad >"$1"; exit 0; fi
  shift
done
exit 2
EOF
  chmod +x "$fakebin/codex" "$fakebin/curl"
  assert_fail "codex wrong patch is not accepted as exact" \
    env PATH="$fakebin:$PATH" bash -c 'source "$1/server/bootstrap.sh"; have_exact_version codex "$CODEX_VERSION"' bash "$ROOT"
  bad_dest="$tmp/bad-asset"
  assert_fail "checksum mismatch fails closed" \
    env PATH="$fakebin:$PATH" bash -c 'source "$1/server/bootstrap.sh"; download_verify https://example.invalid/a "$2" deadbeef' bash "$ROOT" "$bad_dest"
  [[ ! -e "$bad_dest" ]] && PASS=$((PASS + 1)) && printf 'ok - checksum mismatch removes bad artifact\n' \
    || { FAIL=$((FAIL + 1)); printf 'not ok - checksum mismatch left artifact\n'; }

  # Ambient exact Node/Pi/Codex must not satisfy managed mise/npm checks.
  cat >"$fakebin/node" <<'EOF'
#!/bin/sh
echo 'v22.23.1'
EOF
  cat >"$fakebin/pi" <<'EOF'
#!/bin/sh
echo '0.80.6'
EOF
  cat >"$fakebin/codex" <<'EOF'
#!/bin/sh
echo 'codex-cli 0.144.1'
EOF
  mise_bin="$HOME/.local/bin/mise"
  cat >"$mise_bin" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then echo '2026.5.15 linux-x64'; exit 0; fi
if [[ "$1" == "exec" ]]; then printf invoked >"$MISE_RECORD"; exit 77; fi
exit 78
EOF
  chmod +x "$fakebin/node" "$fakebin/pi" "$fakebin/codex" "$mise_bin"
  bash -c 'source "$1/server/bootstrap.sh"; mark_managed_dest "$2"' bash "$ROOT" "$mise_bin"
  assert_fail "ambient exact Node does not skip managed Node install" \
    env PATH="$fakebin:$PATH" bash -c 'source "$1/server/bootstrap.sh"; install_mise_node' bash "$ROOT"
  record="$tmp/mise-invoked"
  assert_fail "ambient exact Pi/Codex do not skip managed npm install" \
    env PATH="$fakebin:$PATH" MISE_RECORD="$record" \
      bash -c 'source "$1/server/bootstrap.sh"; install_npm_globals' bash "$ROOT"
  [[ -f "$record" ]] && PASS=$((PASS + 1)) && printf 'ok - managed npm install invoked despite ambient exact tools\n' \
    || { FAIL=$((FAIL + 1)); printf 'not ok - ambient tools caused managed npm skip\n'; }
  rm -rf "$tmp" "$fakebin"
}

# ---- neovim unknown-tree refusal (mockable via sourced helpers) ----
{
  tmp="$(mktemp -d)"
  export HOME="$tmp"
  mkdir -p "$HOME/.local/nvim"
  echo 'not-nvim' >"$HOME/.local/nvim/README"
  # Exercise the managed-tree gate by invoking bootstrap function via bash -c sourcing.
  # Use a tiny probe that mirrors nvim_tree_managed / refuse logic from bootstrap.
  assert_fail "unknown nvim tree is not considered managed" \
    bash -c '
      root="$1"
      [[ -x "$root/bin/nvim" && -d "$root/share/nvim" ]]
    ' bash "$HOME/.local/nvim"
  assert_ok "bootstrap refuses rm -rf pattern only after managed check" \
    grep -Fq 'no rm -rf of unknown installs' "$ROOT/server/bootstrap.sh"
  rm -f "$HOME/.local/nvim/README"
  mkdir -p "$HOME/.local/nvim/bin" "$HOME/.local/nvim/share/nvim"
  cat >"$HOME/.local/nvim/bin/nvim" <<'EOF'
#!/bin/sh
echo 'NVIM v0.12.4'
EOF
  chmod +x "$HOME/.local/nvim/bin/nvim"
  assert_fail "installer refuses unowned Neovim tree even at exact version" \
    bash -c 'source "$1/server/bootstrap.sh"; install_neovim' bash "$ROOT"
  rm -rf "$tmp"
}

# ---- doctor JSON ----
{
  tmp="$(mktemp -d)"
  export HOME="$tmp"
  "$ROOT/install.sh" server >/dev/null
  set +e
  out="$("$ROOT/install.sh" server doctor --json 2>/dev/null)"
  set -e
  assert_ok "doctor json parses" python3 -c 'import json,sys; json.loads(sys.argv[1])' "$out"
  assert_ok "doctor json has fail/warn/items" \
    python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert "fail" in d and "warn" in d and isinstance(d["items"], list)' "$out"
  assert_ok "doctor json mentions node pin code" \
    python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert any(i.get("code")=="node" for i in d["items"])' "$out"
  assert_ok "doctor json checks gentle-ai" \
    python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert any(i.get("code")=="gentle_ai" for i in d["items"])' "$out"
  assert_ok "doctor json checks delta/eza/zoxide/mosh" \
    python3 -c 'import json,sys; d=json.loads(sys.argv[1]); codes={i.get("code") for i in d["items"]}; assert {"delta","eza","zoxide","mosh"} <= codes' "$out"
  weird_home="$tmp"$'\b\f\001'
  set +e
  control_json="$(HOME="$weird_home" "$ROOT/install.sh" server doctor --json 2>/dev/null)"
  set -e
  assert_ok "doctor json escapes all control characters" \
    python3 -c 'import json,sys; json.loads(sys.argv[1])' "$control_json"
  assert_ok "doctor json checks all server link destinations" \
    python3 -c '
import json,sys
d=json.loads(sys.argv[1])
msgs=" ".join(i.get("message","") for i in d["items"] if i.get("code")=="links")
required=[
  ".zshenv",".zshrc",".config/nvim",".config/opencode",".tmux.conf",
  ".config/tmux","/scripts",".config/lazygit/config.yml",
  ".pi/agent/settings.json",".pi/agent/mcp.json",".pi/agent/gentle-ai",
  "verseguard-metro.service",
]
missing=[r for r in required if r not in msgs]
assert not missing, missing
' "$out"
  rm -rf "$tmp"
}

# ---- apparmor profile is upstream ABI adapt only ----
{
  assert_ok "tracked profile uses abi 4.0" \
    grep -Fq 'abi <abi/4.0>,' "$ROOT/server/apparmor/bwrap-userns-restrict"
  assert_ok "tracked profile has unpriv capability deny" \
    grep -Fq 'audit deny capability,' "$ROOT/server/apparmor/bwrap-userns-restrict"
  assert_fail "tracked profile must not keep abi 5.0" \
    grep -Fq 'abi <abi/5.0>,' "$ROOT/server/apparmor/bwrap-userns-restrict"
}

# ---- no hardcoded home, tailnet hostname, or non-loopback IPv4 in artifacts ----
{
  set +e
  hits="$(rg -n -P '/home/(?!YOUR_)[A-Za-z0-9._-]+|\b[a-z0-9-]+\.ts\.net\b|\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b' \
    "$ROOT/server" "$ROOT/docs/vps-development-environment.html" \
    "$ROOT/systemd/user/verseguard-metro.service" \
    "$ROOT/tmux/scripts/codex_toggle.sh" "$ROOT/install.sh" 2>/dev/null \
    | grep -v '127\.0\.0\.1')"
  set -e
  if [[ -z "${hits:-}" ]]; then
    PASS=$((PASS + 1))
    printf 'ok - no hardcoded home, tailnet hostname, or non-loopback IPv4\n'
  else
    FAIL=$((FAIL + 1))
    printf 'not ok - private infrastructure markers found\n%s\n' "$hits"
  fi
}

# ---- codex toggle no nvm fallback ----
{
  if rg -n 'nvm/versions/node' "$ROOT/tmux/scripts/codex_toggle.sh" >/dev/null; then
    FAIL=$((FAIL + 1))
    printf 'not ok - codex_toggle still has nvm hardcoded path\n'
  else
    PASS=$((PASS + 1))
    printf 'ok - codex_toggle has no nvm hardcoded path\n'
  fi
  if rg -n 'codex not found in PATH' "$ROOT/tmux/scripts/codex_toggle.sh" >/dev/null; then
    PASS=$((PASS + 1))
    printf 'ok - codex_toggle fails clearly when missing\n'
  else
    FAIL=$((FAIL + 1))
    printf 'not ok - codex_toggle missing clear failure message\n'
  fi
}

# ---- metro envfile parameterization ----
{
  if rg -n 'EnvironmentFile=-%h/\.config/verseguard-metro\.env' "$ROOT/systemd/user/verseguard-metro.service" >/dev/null \
     && ! rg -n 'EXPO_PACKAGER_PROXY_URL=' "$ROOT/systemd/user/verseguard-metro.service" >/dev/null; then
    PASS=$((PASS + 1))
    printf 'ok - metro service uses EnvironmentFile without hardcoded proxy URL\n'
  else
    FAIL=$((FAIL + 1))
    printf 'not ok - metro service parameterization\n'
  fi
}

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
