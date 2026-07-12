#!/usr/bin/env bash
# Idempotent non-interactive install of Oh My Zsh, Powerlevel10k, and zsh-autosuggestions.
# Clones via git only — no upstream installers, no chsh, no root, no overwrite of existing paths.
set -euo pipefail

# Always under $HOME so ambient ZSH/ZSH_CUSTOM from another machine cannot redirect installs.
ZSH_DIR="$HOME/.oh-my-zsh"
CUSTOM_DIR="$ZSH_DIR/custom"

OMZ_URL="https://github.com/ohmyzsh/ohmyzsh.git"
P10K_URL="https://github.com/romkatv/powerlevel10k.git"
AUTOSUGGEST_URL="https://github.com/zsh-users/zsh-autosuggestions.git"

normalize_git_url() {
  local url="$1"
  url="${url%.git}"
  url="${url%/}"
  if [[ "$url" =~ ^git@([^:]+):(.+)$ ]]; then
    url="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  elif [[ "$url" =~ ^ssh://git@([^/]+)/(.+)$ ]]; then
    url="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  fi
  printf '%s\n' "$url"
}

urls_match() {
  [[ "$(normalize_git_url "$1")" == "$(normalize_git_url "$2")" ]]
}

# Clone dest from url when missing; if dest exists, accept only a git repo with matching origin.
ensure_clone() {
  local dest="$1"
  local url="$2"
  local name="$3"
  local origin

  if [[ -e "$dest" || -L "$dest" ]]; then
    if [[ ! -d "$dest/.git" ]]; then
      echo "refusing: $dest exists but is not a git repository ($name)" >&2
      return 1
    fi
    if ! origin="$(git -C "$dest" remote get-url origin 2>/dev/null)"; then
      echo "refusing: $dest has no origin remote ($name)" >&2
      return 1
    fi
    if ! urls_match "$origin" "$url"; then
      echo "refusing: $dest origin is $origin (want $url)" >&2
      return 1
    fi
    echo "ok: $name already present at $dest"
    return 0
  fi

  mkdir -p "$(dirname "$dest")"
  echo "cloning: $name -> $dest"
  git clone --depth 1 "$url" "$dest"
  echo "ok: installed $name at $dest"
}

if ! command -v git >/dev/null 2>&1; then
  echo "refusing: git is required" >&2
  exit 1
fi

status=0

ensure_clone "$ZSH_DIR" "$OMZ_URL" "Oh My Zsh" || status=1

if [[ -d "$ZSH_DIR/.git" ]]; then
  ensure_clone "$CUSTOM_DIR/themes/powerlevel10k" "$P10K_URL" "Powerlevel10k" || status=1
  ensure_clone "$CUSTOM_DIR/plugins/zsh-autosuggestions" "$AUTOSUGGEST_URL" "zsh-autosuggestions" || status=1
else
  echo "refusing: skipping theme/plugins; Oh My Zsh unavailable at $ZSH_DIR" >&2
  status=1
fi

if (( status == 0 )); then
  echo "Zsh dependencies ready under $HOME"
fi
exit "$status"
