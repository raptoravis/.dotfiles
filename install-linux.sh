#!/usr/bin/env bash
# install-linux.sh — Linux / WSL2 dotfiles & dev environment bootstrap
#
# Usage:
#   ./install-linux.sh                       # full silent install
#   DOTFILES_DIR=~/code/dotfiles ./install-linux.sh
#   SET_HOSTNAME=my-wsl ./install-linux.sh   # optional WSL hostname
#
# Idempotent: safe to re-run. Mirrors `cargo make init` for Linux/WSL2.

set -uo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$HOME/.dotfiles}"
ZSH_CUSTOM_DIR="${ZSH:-$HOME/.config/zsh/ohmyzsh}"
IS_WSL=0
grep -qi 'microsoft\|wsl' /proc/version 2>/dev/null && IS_WSL=1

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; }

if [[ "$(uname -s)" != "Linux" ]]; then
  err "Linux/WSL2 only. Detected: $(uname -s)"
  exit 1
fi
(( IS_WSL )) && log "WSL2 detected" || log "Pure Linux detected"

# ---------------------------------------------------------------------------
# 1) apt packages — base toolchain + dev essentials
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
log "Updating apt and installing base packages"
sudo -E apt-get update -qq
APT_PKGS=(
  zsh fzf ripgrep fd-find bat neovim cmake curl git
  build-essential pkg-config libssl-dev fastfetch tmux mosh
  unzip ca-certificates gnupg
  nodejs npm
)
sudo -E apt-get install -y -qq "${APT_PKGS[@]}"
(( IS_WSL )) && sudo -E apt-get install -y -qq wslu 2>/dev/null || true

# WezTerm — only on bare Linux (WSL uses the Windows host's wezterm).
# Default Debian/Ubuntu repos lag behind upstream by years; use wez's
# fury.io apt repo for current builds.
if (( ! IS_WSL )) && ! command -v wezterm >/dev/null 2>&1; then
  log "Installing WezTerm via official apt repo"
  sudo install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://apt.fury.io/wez/gpg.key \
    | sudo gpg --yes --dearmor -o /etc/apt/keyrings/wezterm-fury.gpg
  echo 'deb [signed-by=/etc/apt/keyrings/wezterm-fury.gpg] https://apt.fury.io/wez/ * *' \
    | sudo tee /etc/apt/sources.list.d/wezterm.list >/dev/null
  sudo -E apt-get update -qq
  sudo -E apt-get install -y -qq wezterm || warn "  wezterm install failed"
fi

# Debian ships fd as `fdfind` and bat as `batcat` — provide expected names.
mkdir -p "$HOME/.local/bin"
[[ -x "$(command -v fdfind)" && ! -e "$HOME/.local/bin/fd" ]]   && ln -s "$(command -v fdfind)" "$HOME/.local/bin/fd"
[[ -x "$(command -v batcat)" && ! -e "$HOME/.local/bin/bat" ]]  && ln -s "$(command -v batcat)" "$HOME/.local/bin/bat"
export PATH="$HOME/.local/bin:$PATH"

# ---------------------------------------------------------------------------
# 2) Rust toolchain (rustup)
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
# 3) Cargo tools (dotter, cargo-update, vivid, eza, bottom, bat)
#    coreutils is provided by the base system on Linux, so we skip it.
# ---------------------------------------------------------------------------
log "Installing Cargo tools"
CARGO_TOOLS=(dotter cargo-update vivid eza bottom bat yazi-fm yazi-cli)
for tool in "${CARGO_TOOLS[@]}"; do
  cargo install "$tool" 2>&1 | tail -n1 || warn "  failed: $tool"
done

# ---------------------------------------------------------------------------
# 4) mise — install via official script (the Linux path in Makefile.toml)
# ---------------------------------------------------------------------------
if ! command -v mise >/dev/null 2>&1; then
  log "Installing mise"
  curl -fsSL https://mise.jdx.dev/install.sh | sh
fi
[[ -d "$HOME/.local/bin" ]] && export PATH="$HOME/.local/bin:$PATH"

# ---------------------------------------------------------------------------
# 5) Go-based tools (lazygit, lazydocker)
# ---------------------------------------------------------------------------
if ! command -v go >/dev/null 2>&1; then
  log "Installing Go via apt"
  sudo -E apt-get install -y -qq golang-go
fi
if command -v go >/dev/null 2>&1; then
  log "Installing lazygit + lazydocker via go install"
  go install github.com/jesseduffield/lazygit@latest    || warn "  lazygit failed"
  go install github.com/jesseduffield/lazydocker@latest || warn "  lazydocker failed"
  export PATH="$(go env GOPATH 2>/dev/null)/bin:$PATH"
fi

# ---------------------------------------------------------------------------
# 6) starship prompt
# ---------------------------------------------------------------------------
if ! command -v starship >/dev/null 2>&1; then
  log "Installing starship prompt"
  curl -sS https://starship.rs/install.sh | sh -s -- -y
fi

# ---------------------------------------------------------------------------
# 7) Oh My Zsh (unattended) + plugins
# ---------------------------------------------------------------------------
export ZSH="$ZSH_CUSTOM_DIR"
if [[ ! -d "$ZSH" ]]; then
  log "Installing Oh My Zsh into $ZSH"
  RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" \
    "" --unattended
else
  log "Oh My Zsh already present at $ZSH"
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
clone_plugin https://github.com/Aloxaf/fzf-tab                   fzf-tab
clone_plugin https://github.com/zsh-users/zsh-autosuggestions    zsh-autosuggestions
clone_plugin https://github.com/zsh-users/zsh-syntax-highlighting zsh-syntax-highlighting
clone_plugin https://github.com/zsh-users/zsh-completions        zsh-completions

# ---------------------------------------------------------------------------
# 8) uv (Python package manager) + uv tools
# ---------------------------------------------------------------------------
if ! command -v uv >/dev/null 2>&1; then
  log "Installing uv"
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi

if [[ -f "$DOTFILES_DIR/uv-tools.txt" ]] && command -v uv >/dev/null 2>&1; then
  log "Installing uv tools from uv-tools.txt"
  while IFS= read -r pkg; do
    [[ -z "$pkg" || "$pkg" == \#* ]] && continue
    uv tool install "$pkg" 2>/dev/null || warn "  skip $pkg (already installed or failed)"
  done < "$DOTFILES_DIR/uv-tools.txt"
fi

# ---------------------------------------------------------------------------
# 8b) Claude Code companion CLIs (rtk hook)
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
# by dotter (step 12). Running `rtk init -g` would create real files that block
# dotter's symlinks.

# ---------------------------------------------------------------------------
# 8c) Global npm tools (hostc — Cloudflare-Workers edge tunnel CLI; openwolf — context manager)
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
  warn "npm not on PATH -- skipping hostc/openwolf install (apt nodejs may be too old; need Node 18+)"
fi

# ---------------------------------------------------------------------------
# 8d) pnpm via corepack
#     apt 的 nodejs 包不一定带 corepack（取决于发行版）。优先尝试独立的
#     corepack apt 包（Ubuntu 24.04+ / Debian 12+），失败回退到 npm -g。
# ---------------------------------------------------------------------------
if ! command -v corepack >/dev/null 2>&1; then
  log "corepack not on PATH -- installing"
  sudo -E apt-get install -y -qq corepack 2>/dev/null \
    || (command -v npm >/dev/null 2>&1 && sudo npm install -g corepack 2>/dev/null) \
    || warn "  corepack install failed (apt + npm both unable)"
fi
if command -v corepack >/dev/null 2>&1; then
  log "Enabling pnpm via corepack"
  corepack enable 2>/dev/null || warn "  corepack enable failed"
  corepack prepare pnpm@latest --activate 2>/dev/null || warn "  corepack prepare pnpm failed"
else
  warn "corepack still not on PATH -- skipping pnpm activation"
fi

# ---------------------------------------------------------------------------
# 9) WSL-only: deploy /etc/wsl.conf and (optionally) set hostname
# ---------------------------------------------------------------------------
if (( IS_WSL )); then
  WSL_CONF_SRC="$DOTFILES_DIR/windows/wsl/wsl.conf"
  if [[ -f "$WSL_CONF_SRC" ]]; then
    log "Deploying $WSL_CONF_SRC -> /etc/wsl.conf"
    sudo cp "$WSL_CONF_SRC" /etc/wsl.conf
  else
    warn "wsl.conf not found at $WSL_CONF_SRC — skipping"
  fi
  if [[ -n "${SET_HOSTNAME:-}" ]]; then
    log "Setting hostname -> $SET_HOSTNAME"
    sudo hostnamectl set-hostname "$SET_HOSTNAME"
  else
    log "SET_HOSTNAME not provided — leaving hostname unchanged ($(hostname))"
  fi
fi

# ---------------------------------------------------------------------------
# 10) ZDOTDIR bootstrap so zsh finds its config under ~/.config/zsh
# ---------------------------------------------------------------------------
if [[ ! -f "$HOME/.zshenv" ]] || ! grep -q 'ZDOTDIR' "$HOME/.zshenv" 2>/dev/null; then
  log "Writing ZDOTDIR bootstrap to ~/.zshenv"
  printf 'export ZDOTDIR=$HOME/.config/zsh\n' >> "$HOME/.zshenv"
fi

# ---------------------------------------------------------------------------
# 11) Ensure .dotter/local.toml exists (gitignored, machine-local)
#     Tells dotter which package set to apply without needing a hostname file.
# ---------------------------------------------------------------------------
LOCAL_TOML="$DOTFILES_DIR/.dotter/local.toml"
if [[ -f "$LOCAL_TOML" ]]; then
  log ".dotter/local.toml already exists"
else
  log "Creating .dotter/local.toml (packages: common + linux)"
  printf 'packages = [ "common", "linux" ]\n' > "$LOCAL_TOML"
fi

# ---------------------------------------------------------------------------
# 12) Symlinks via dotter
# ---------------------------------------------------------------------------
if command -v dotter >/dev/null 2>&1; then
  log "Symlinking dotfiles via dotter"
  ( cd "$DOTFILES_DIR" && dotter -v ) || warn "dotter exited with errors"
else
  warn "dotter not on PATH — skipping symlinks. Open a new shell so \$HOME/.cargo/bin is loaded, then re-run."
fi

# ---------------------------------------------------------------------------
# 13) WezTerm session state directory (created by common/wezterm/wezterm.lua
#     for save/restore — pre-create so the lua mkdir fallback never runs).
# ---------------------------------------------------------------------------
mkdir -p "$HOME/.local/share/wezterm/sessions"

# ---------------------------------------------------------------------------
# 12) Default shell
# ---------------------------------------------------------------------------
ZSH_BIN="$(command -v zsh || echo /usr/bin/zsh)"
if [[ "${SHELL:-}" != "$ZSH_BIN" ]]; then
  log "Default shell is $SHELL — to switch, run: chsh -s $ZSH_BIN"
fi

log "Done. Open a new terminal (or 'wsl --shutdown' on WSL) to pick up the environment."
