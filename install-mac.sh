#!/usr/bin/env bash
# install-mac.sh — macOS dotfiles & dev environment bootstrap
#
# Usage:
#   ./install-mac.sh              # full silent/unattended install
#   DOTFILES_DIR=~/code/dotfiles ./install-mac.sh
#   SKIP_XCODE=1 ./install-mac.sh # skip CLT step (assume already there)
#
# Idempotent: safe to re-run. Mirrors `cargo make init` for macOS.

set -uo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$HOME/.dotfiles}"
ZSH_CUSTOM_DIR="${ZSH:-$HOME/.config/zsh/ohmyzsh}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; }

if [[ "$(uname -s)" != "Darwin" ]]; then
  err "macOS only. Detected: $(uname -s)"
  exit 1
fi

# ---------------------------------------------------------------------------
# 1) Xcode Command Line Tools (git, cc, headers — required for everything)
# ---------------------------------------------------------------------------
if [[ "${SKIP_XCODE:-0}" != "1" ]] && ! xcode-select -p >/dev/null 2>&1; then
  log "Installing Xcode Command Line Tools (silent via softwareupdate)"
  touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  CLT_LABEL=$(softwareupdate -l 2>/dev/null \
    | grep -E '\* (Label: )?Command Line Tools' \
    | sed -E 's/^.*Label: //; s/^\* //' \
    | sort -V | tail -n1)
  if [[ -n "${CLT_LABEL:-}" ]]; then
    sudo softwareupdate -i "$CLT_LABEL" --verbose
  else
    warn "softwareupdate had no CLT label; falling back to GUI installer"
    xcode-select --install || true
    warn "Finish the GUI installer, then re-run this script."
    exit 1
  fi
  rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
else
  log "Xcode Command Line Tools present."
fi

# ---------------------------------------------------------------------------
# 2) Homebrew
# ---------------------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  log "Installing Homebrew (NONINTERACTIVE=1)"
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi
log "Homebrew: $(brew --version | head -n1)"

# ---------------------------------------------------------------------------
# 3) Brewfile packages (taps, brews, casks)
# ---------------------------------------------------------------------------
if [[ -f "$DOTFILES_DIR/Brewfile" ]]; then
  # Homebrew >= 5.x's `brew bundle` does not always tap before fetching, so
  # cask references like `cask "aerospace"` (provided by nikitabobko/tap) fail
  # to resolve. Explicitly tap first to make `brew bundle` deterministic.
  log "Adding required taps"
  awk '/^[[:space:]]*tap[[:space:]]+"/ {gsub(/"/,"",$2); print $2}' \
      "$DOTFILES_DIR/Brewfile" \
    | while read -r t; do
        [[ -z "$t" ]] && continue
        log "  brew tap $t"
        brew tap "$t" >/dev/null 2>&1 || warn "  failed to tap $t"
      done

  log "Installing Brewfile packages"
  HOMEBREW_NO_AUTO_UPDATE=1 brew bundle --file="$DOTFILES_DIR/Brewfile" \
    || warn "brew bundle reported errors (inspect output above)"
else
  warn "Brewfile not found at $DOTFILES_DIR/Brewfile — skipping"
fi

# Starship is referenced in .zshrc but not in the Brewfile.
if ! command -v starship >/dev/null 2>&1; then
  log "Installing starship prompt"
  brew install starship
fi

# ---------------------------------------------------------------------------
# 4) Rust toolchain (rustup)
# ---------------------------------------------------------------------------
if ! command -v rustup >/dev/null 2>&1; then
  log "Installing Rust toolchain (silent)"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --no-modify-path --default-toolchain stable
fi
# shellcheck disable=SC1091
[[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
rustup component add clippy rustfmt 2>/dev/null || true

# ---------------------------------------------------------------------------
# 5) Cargo tools — skip if the produced binary is already on PATH.
#    `cargo install` re-checks crates.io even when up-to-date, which adds
#    noticeable latency on re-runs; a `command -v` check is instant.
#    Some crates produce a binary with a different name (bottom -> btm,
#    cargo-update -> cargo-install-update), so use crate:binary pairs.
# ---------------------------------------------------------------------------
log "Installing Cargo tools"
CARGO_TOOLS=(
  "dotter:dotter"
  "cargo-update:cargo-install-update"
  "vivid:vivid"
  "eza:eza"
  "bottom:btm"
  "bat:bat"
  "mise:mise"
)
for entry in "${CARGO_TOOLS[@]}"; do
  crate="${entry%%:*}"
  bin="${entry##*:}"
  if command -v "$bin" >/dev/null 2>&1; then
    log "  $crate already installed ($bin on PATH)"
    continue
  fi
  cargo install "$crate" 2>&1 | tail -n1 || warn "  failed: $crate"
done

log "Installing coreutils"
# Recent uutils/coreutils dropped the platform-named features (`macos`,
# `windows`, `unix`) — features are now per-utility. Use defaults.
if command -v coreutils >/dev/null 2>&1; then
  log "  coreutils already installed"
else
  cargo install coreutils 2>&1 | tail -n1 || warn "  failed: coreutils"
fi

# ---------------------------------------------------------------------------
# 6) Oh My Zsh (unattended) + plugins
# ---------------------------------------------------------------------------
export ZSH="$ZSH_CUSTOM_DIR"
if [[ ! -d "$ZSH" ]]; then
  log "Installing Oh My Zsh into $ZSH"
  RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" \
    "" --unattended
else
  log "Oh My Zsh already installed at $ZSH"
fi

log "Cloning Oh My Zsh plugins"
clone_plugin() {
  local url="$1" dest="$ZSH/custom/plugins/$2"
  if [[ -d "$dest" ]]; then
    log "  $2 already present"
  else
    git clone --depth=1 --quiet "$url" "$dest" || warn "  clone failed: $2"
  fi
}
clone_plugin https://github.com/Aloxaf/fzf-tab                fzf-tab
clone_plugin https://github.com/zsh-users/zsh-autosuggestions zsh-autosuggestions
clone_plugin https://github.com/zsh-users/zsh-syntax-highlighting zsh-syntax-highlighting
clone_plugin https://github.com/zsh-users/zsh-completions     zsh-completions

# ---------------------------------------------------------------------------
# 7) uv (Python package manager) + uv tools
# ---------------------------------------------------------------------------
if ! command -v uv >/dev/null 2>&1; then
  log "Installing uv"
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi
[[ -d "$HOME/.local/bin" ]] && export PATH="$HOME/.local/bin:$PATH"

if [[ -f "$DOTFILES_DIR/uv-tools.txt" ]] && command -v uv >/dev/null 2>&1; then
  log "Installing uv tools from uv-tools.txt"
  while IFS= read -r pkg; do
    [[ -z "$pkg" || "$pkg" == \#* ]] && continue
    uv tool install "$pkg" 2>/dev/null || warn "  skip $pkg (already installed or failed)"
  done < "$DOTFILES_DIR/uv-tools.txt"
fi

# ---------------------------------------------------------------------------
# 7b) Claude Code companion CLIs (rtk hook)
#     Marketplace plugins (claude-hud, handoff, andrej-karpathy-skills) are
#     declared in common/claude/settings.json and load at Claude Code startup.
# ---------------------------------------------------------------------------
if ! command -v rtk >/dev/null 2>&1; then
  log "Installing rtk (LLM output compressor + Claude Code hook)"
  curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh \
    || warn "  rtk install script failed"
fi
# Note: do not run `rtk init -g` here. The hook, RTK.md, and @RTK.md reference
# are all baked into common/claude/{settings.json,RTK.md,CLAUDE.md} and wired
# by dotter (step 10). Running `rtk init -g` would create real files that block
# dotter's symlinks.

# ---------------------------------------------------------------------------
# 7c) Global npm tools (hostc — Cloudflare-Workers edge tunnel CLI; openwolf — context manager)
# ---------------------------------------------------------------------------
if command -v npm >/dev/null 2>&1; then
  if ! command -v hostc >/dev/null 2>&1; then
    log "Installing hostc (edge tunnel CLI) via npm"
    npm install -g hostc 2>/dev/null || warn "  hostc install failed"
  fi
  if ! command -v openwolf >/dev/null 2>&1; then
    log "Installing openwolf via npm"
    npm install -g openwolf 2>/dev/null || warn "  openwolf install failed"
  fi
else
  warn "npm not on PATH -- skipping hostc/openwolf install (ensure node was installed by brew bundle)"
fi

# ---------------------------------------------------------------------------
# 7d) pnpm via corepack (ships with Node >= 16.10)
# ---------------------------------------------------------------------------
if command -v corepack >/dev/null 2>&1; then
  log "Enabling pnpm via corepack"
  corepack enable 2>/dev/null || warn "  corepack enable failed"
  corepack prepare pnpm@latest --activate 2>/dev/null || warn "  corepack prepare pnpm failed"
else
  warn "corepack not on PATH -- skipping pnpm activation (ensure node was installed by brew bundle)"
fi

# ---------------------------------------------------------------------------
# 8) mise — install runtimes declared in mise config (if any)
# ---------------------------------------------------------------------------
if command -v mise >/dev/null 2>&1; then
  log "Running 'mise install' for declared runtimes"
  ( cd "$DOTFILES_DIR" && mise install ) 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 9) Dotter machine config — auto-create if missing for this hostname.
#    Dotter reads $HOSTNAME.toml under .dotter/ to decide which packages to
#    activate from global.toml. Bootstrapping a fresh Mac fork needs one.
# ---------------------------------------------------------------------------
HOSTNAME_FQDN="$(hostname)"
MACHINE_TOML="$DOTFILES_DIR/.dotter/${HOSTNAME_FQDN}.toml"
if [[ ! -f "$MACHINE_TOML" ]]; then
  log "Creating dotter machine config: ${MACHINE_TOML#$DOTFILES_DIR/}"
  printf 'packages = [ "common", "mac" ]\n' > "$MACHINE_TOML"
fi

# ---------------------------------------------------------------------------
# 9b) ZDOTDIR bootstrap so zsh finds its config under ~/.config/zsh.
#     Without this, macOS zsh reads ~/.zshrc (often empty on a fresh install)
#     and the dotter-symlinked common/zsh/.zshrc is never sourced — leaving
#     /opt/homebrew/bin and ~/.local/bin off PATH (brew/claude not found).
# ---------------------------------------------------------------------------
if [[ ! -f "$HOME/.zshenv" ]] || ! grep -q 'ZDOTDIR' "$HOME/.zshenv" 2>/dev/null; then
  log "Writing ZDOTDIR bootstrap to ~/.zshenv"
  printf 'export ZDOTDIR=$HOME/.config/zsh\n' >> "$HOME/.zshenv"
fi

# ---------------------------------------------------------------------------
# 10) Symlinks via dotter
# ---------------------------------------------------------------------------
if command -v dotter >/dev/null 2>&1; then
  log "Symlinking dotfiles via dotter"
  ( cd "$DOTFILES_DIR" && dotter -v ) || warn "dotter exited with errors"
else
  warn "dotter not on PATH — skipping symlinks. Re-run after \$HOME/.cargo/bin is on PATH."
fi

# ---------------------------------------------------------------------------
# 11) WezTerm session state directory (created by common/wezterm/wezterm.lua
#     for save/restore — pre-create so the lua mkdir fallback never runs).
# ---------------------------------------------------------------------------
mkdir -p "$HOME/.local/share/wezterm/sessions"

# ---------------------------------------------------------------------------
# 12) Default shell
# ---------------------------------------------------------------------------
ZSH_BIN="$(command -v zsh || echo /bin/zsh)"
if [[ "${SHELL:-}" != "$ZSH_BIN" ]]; then
  log "Default shell is $SHELL — to switch, run: chsh -s $ZSH_BIN"
fi

log "Done. Open a new terminal to pick up the environment."
