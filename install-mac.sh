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

UNINSTALL_AGENTS=0
for arg in "$@"; do
  case "$arg" in
    --uninstallagents) UNINSTALL_AGENTS=1 ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--uninstallagents]
  --uninstallagents  Uninstall all AI agent CLIs (Claude Code, Codex, OpenCode, Grok,
                     DeepSeek Harness, Pi) and remove their config dirs.
EOF
      exit 0
      ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

if (( UNINSTALL_AGENTS )); then
  log "Uninstalling AI agent CLIs and cleaning config directories"

  # 1) npm global uninstall
  if command -v npm >/dev/null 2>&1; then
    for pkg in "@anthropic-ai/claude-code" "@openai/codex" "@opencode/cli" "@xai-official/grok" "@deepseek-ai/dsh" "@deepseek-harness-tui/dsh-tui" "@earendil-works/pi-coding-agent"; do
      log "  npm uninstall -g $pkg"
      npm uninstall -g "$pkg" 2>/dev/null || warn "  $pkg was not installed globally (or uninstall failed)"
    done
  else
    warn "npm not on PATH — skipping npm uninstall step"
  fi

  # 2) Remove agent config directories
  AGENT_DIRS=(
    "$HOME/.claude"
    "${CODEX_HOME:-$HOME/.codex}"
    "$HOME/.config/opencode"
    "$HOME/.grok"
    "${DSH_HOME:-$HOME/.dsh}"
    "$HOME/.pi"
    "$HOME/.agents"
    "$HOME/.cache/dotfiles/agent-plugins"
    "$HOME/.cache/opencode"
    "$HOME/.cache/claude"
    "$HOME/.cache/codex"
    "$HOME/.cache/dsh"
  )
  for d in "${AGENT_DIRS[@]}"; do
    if [[ -d "$d" || -L "$d" ]]; then
      log "  rm -rf $d"
      rm -rf "$d"
    else
      log "  skip (not found): $d"
    fi
  done

  log "Agent uninstall complete."
  exit 0
fi

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

# WezTerm — installed as an optional terminal, but NOT the default session
# manager (herdr auto-starts instead). Brewfile declares the cask; brew bundle
# may skip already-installed casks, so ensure it's installed/up to date here.
log "Installing/upgrading WezTerm terminal (optional)"
if command -v wezterm >/dev/null 2>&1; then
  brew upgrade --cask wezterm --no-quarantine --greedy-latest 2>/dev/null \
    && log "  wezterm upgraded" || log "  wezterm already up to date"
else
  brew install --cask wezterm --no-quarantine 2>/dev/null \
    || warn "  wezterm cask install failed (check Brewfile)"
fi

# VS Code — primary editor; declared in Brewfile but brew bundle may skip
# already-installed casks without upgrading.
log "Installing/upgrading VS Code"
if command -v code >/dev/null 2>&1; then
  brew upgrade --cask visual-studio-code --no-quarantine 2>/dev/null \
    && log "  VS Code upgraded" || log "  VS Code already up to date"
else
  brew install --cask visual-studio-code --no-quarantine 2>/dev/null \
    || warn "  VS Code cask install failed (check Brewfile)"
fi

# Starship is referenced in .zshrc but not in the Brewfile.
if ! command -v starship >/dev/null 2>&1; then
  log "Installing starship prompt"
  brew install starship
fi

# CLI tools not in Brewfile — install idempotently via brew.
log "Installing CLI tools (jq, vhs, silicon, ffmpeg, ast-grep)"
for pkg in jq vhs silicon ffmpeg ast-grep; do
  bin="$pkg"
  # ast-grep's CLI binary is `sg` (structural grep)
  [[ "$pkg" == "ast-grep" ]] && bin="sg"
  if command -v "$bin" >/dev/null 2>&1; then
    log "  $pkg already installed"
  else
    brew install "$pkg" 2>/dev/null || warn "  $pkg brew install failed"
  fi
done

# Tailscale — installed via Brewfile; start the daemon and authenticate if needed.
if command -v tailscale >/dev/null 2>&1; then
  log "Starting Tailscale daemon"
  brew services start tailscale 2>/dev/null || warn "  tailscaled start failed"
  if tailscale status >/dev/null 2>&1; then
    log "  Tailscale already up"
  else
    log "  Logging in to Tailscale — complete browser auth when prompted"
    tailscale up || warn "  tailscale up failed (run it manually)"
  fi
else
  warn "tailscale not on PATH — ensure Brewfile installed it"
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
# rustup 偶发安装不完整：component 标记已装但 std 的 .rlib 实际缺失，
# 会导致后续 cargo install 全部报 can't find crate for std。
if ! compgen -G "$HOME/.rustup/toolchains/"*/lib/rustlib/*/lib/libstd-*.rlib >/dev/null; then
  warn "rust-std missing/corrupt — reinstalling stable toolchain"
  rustup toolchain uninstall stable 2>/dev/null || true
  rustup toolchain install stable --profile default
  rustup component add clippy rustfmt 2>/dev/null || true
fi

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
  # eza 由 Brewfile 用 brew 装（macOS），不走 cargo：palette 0.7.5 与 rustc 1.98+ 不兼容。
  "bottom:btm"
  "bat:bat"
  "mise:mise"
  # yazi-fm / yazi-cli 由 Brewfile 用 brew 装（macOS），不走 cargo：同样受 palette 0.7.5 影响。
  "abtop:abtop"
)
for entry in "${CARGO_TOOLS[@]}"; do
  crate="${entry%%:*}"
  bin="${entry##*:}"
  if command -v "$bin" >/dev/null 2>&1; then
    log "  $crate already installed ($bin on PATH)"
    continue
  fi
  log "  installing $crate ..."
  if cargo install "$crate" 2>&1 | tail -n1; then
    # Verify binary landed — cargo may exit 0 but still fail to link.
    bin_path="$HOME/.cargo/bin/$bin"
    if [[ -x "$bin_path" ]]; then
      log "    -> $bin_path"
    else
      warn "  $crate: cargo reported OK but $bin_path not found — check cargo output above for linker/build errors"
    fi
  else
    warn "  failed: $crate"
  fi
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
# 7b2) herdr — coding-agent runtime (background daemon that keeps terminals
#      alive for Claude Code / Codex / OpenCode etc. across sleep/network drops)
# ---------------------------------------------------------------------------
if ! command -v herdr >/dev/null 2>&1; then
  log "Installing herdr (coding-agent runtime)"
  curl -fsSL https://herdr.dev/install.sh | sh || warn "  herdr install failed"
  # herdr installs to ~/.local/bin (overridable via HERDR_INSTALL_DIR)
  [[ -d "$HOME/.local/bin" ]] && export PATH="$HOME/.local/bin:$PATH"
else
  log "herdr already installed"
fi

# ---------------------------------------------------------------------------
# 7c) Global npm tools (hostc — Cloudflare-Workers edge tunnel CLI)
# ---------------------------------------------------------------------------
if command -v npm >/dev/null 2>&1; then
  # 安装/升级一个 npm 全局 CLI。`npm install -g` 不看已装版本、每次都拉 latest 重装，
  # 已是最新也白跑。这里先比 installed vs latest：未安装或远端有新版才真正 install，
  # 已是最新则跳过。$1=pkg $2=显示名，其余参数透传给 npm install。
  # semver_lt A B — exit 0 if A < B (npm semver)，否则非 0。用 node（npm 依赖 node）比较，
  # 预发布标签（-rc/-alpha）也能正确排序，避免把「本地比 latest 新」误判成可升级。
  semver_lt() {
    node -e '
      const n = (v) => {
        const m = String(v).replace(/^v/, "").split("-");
        return { core: m[0].split(".").map((x) => +x || 0), pre: m[1] ? m[1].split(".") : [] };
      };
      const a = n(process.argv[1]), b = n(process.argv[2]);
      for (let i = 0; i < 3; i++) { const d = a.core[i] - b.core[i]; if (d) process.exit(d < 0 ? 0 : 1); }
      const cmp = (x, y) => {
        for (let i = 0; i < Math.max(x.length, y.length); i++) {
          if (x[i] === undefined) return -1;
          if (y[i] === undefined) return 1;
          if (x[i] === y[i]) continue;
          const xn = /^\d+$/.test(x[i]), yn = /^\d+$/.test(y[i]);
          if (xn && yn) return (+x[i]) - (+y[i]);
          if (xn) return -1;
          if (yn) return 1;
          return x[i] < y[i] ? -1 : 1;
        }
        return 0;
      };
      if (a.pre.length === 0 && b.pre.length === 0) process.exit(1);
      if (a.pre.length === 0) process.exit(1);
      if (b.pre.length === 0) process.exit(0);
      process.exit(cmp(a.pre, b.pre) < 0 ? 0 : 1);
    ' "$1" "$2" 2>/dev/null
  }
  # semver_safe_upgrade A B — exit 0 if A→B is a safe auto-upgrade: B is not a
  # pre-release, and the bump stays within the same minor line (for 0.x the minor
  # is breaking, so 0.x only auto-upgrades patch). Pre-release latest and any
  # minor/major jump are treated as unsafe — keeps coupled dsh/dsh-tui from being
  # pulled by `latest` onto incompatible version lines.
  semver_safe_upgrade() {
    node -e '
      const n = (v) => {
        const m = String(v).replace(/^v/, "").split("-");
        return { core: m[0].split(".").map((x) => +x || 0), pre: m[1] };
      };
      const a = n(process.argv[1]), b = n(process.argv[2]);
      if (b.pre) process.exit(1);
      if (a.core[0] !== b.core[0]) process.exit(1);
      if (a.core[0] === 0 && a.core[1] !== b.core[1]) process.exit(1);
      process.exit(0);
    ' "$1" "$2" 2>/dev/null
  }
  # npm 全局 bin 目录 (/opt/homebrew/bin) 与 brew cask 共享同一路径。若某 AI CLI 的二进制
  # 已被 brew cask 占用（符号链接指向 Caskroom），npm install -g 会 EEXIST。安装前先卸载
  # 冲突的 cask，保持所有 AI CLI 统一由 npm 管理。
  clear_brew_cask_conflict() {
    command -v brew >/dev/null 2>&1 || return 0
    local cask bin link
    case "$1" in
      @anthropic-ai/claude-code) cask=claude-code; bin=claude ;;
      *) return 0 ;;
    esac
    link=$(command -v "$bin" 2>/dev/null)
    [[ -n "$link" && -L "$link" ]] || return 0
    [[ "$(readlink "$link")" == *"Caskroom/${cask}"* ]] || return 0
    log "  ${cask} 由 brew cask 管理，卸载后改由 npm 接管"
    brew uninstall --cask "$cask" || warn "  brew uninstall --cask ${cask} failed"
  }
  npm_install_if_stale() {
    local pkg="$1" label="$2" inst latest
    shift 2
    inst=$(npm list -g --depth=0 "$pkg" 2>/dev/null | sed -nE 's/.*@([^@]+)$/\1/p' | head -1)
    if [[ -z "$inst" ]]; then
      clear_brew_cask_conflict "$pkg"
      log "Installing $label ($pkg)"
      npm install -g "$pkg" "$@" || warn "  $label install failed"
      return
    fi
    latest=$(npm view "$pkg" version 2>/dev/null)
    if [[ -n "$latest" ]] && semver_lt "$inst" "$latest"; then
      if semver_safe_upgrade "$inst" "$latest"; then
        clear_brew_cask_conflict "$pkg"
        log "Upgrading $label ($pkg): $inst -> $latest"
        npm install -g "$pkg" "$@" || warn "  $label upgrade failed"
      else
        log "  $label ($pkg) @ $inst → $latest 跨 minor/major 或为预发布，跳过自动升级"
      fi
    elif [[ -n "$latest" ]] && semver_lt "$latest" "$inst"; then
      log "  $label ($pkg) @ $inst 比 latest ($latest) 新，跳过"
    else
      log "  $label ($pkg) @ $inst 已是最新，跳过"
    fi
  }
  if ! command -v hostc >/dev/null 2>&1; then
    log "Installing hostc (edge tunnel CLI) via npm"
    npm install -g hostc || warn "  hostc install failed"
  fi
  if ! command -v claude-mem >/dev/null 2>&1; then
    log "Installing claude-mem via npm"
    npm install -g claude-mem || warn "  claude-mem install failed"
  fi
  if ! command -v agent-browser >/dev/null 2>&1; then
    log "Installing agent-browser (browser automation for AI agents) via npm"
    npm install -g agent-browser || warn "  agent-browser install failed"
  fi
  # One-time Chromium download for agent-browser (idempotent — skips if already present)
  if command -v agent-browser >/dev/null 2>&1; then
    log "agent-browser: downloading Chromium (one-time)"
    agent-browser install 2>/dev/null || warn "  agent-browser install (Chromium) failed"
  fi
  # puppeteer — browser automation library (includes Chromium). --ignore-scripts skips the
  # postinstall Chromium download (redundant: agent-browser above already ships Chromium).
  if [ ! -d "$(npm root -g 2>/dev/null)/puppeteer" ]; then
    log "Installing puppeteer (browser automation) via npm"
    npm install -g puppeteer --ignore-scripts || warn "  puppeteer install failed"
  else
    log "puppeteer already installed"
  fi

  # AI coding CLIs (Claude Code / Codex / OpenCode / Grok / DeepSeek Harness / Pi)
  # 只在未安装或远端有新版时才 npm install；已是最新则跳过，重跑脚本不再白升级。
  npm_install_if_stale @anthropic-ai/claude-code "Claude Code CLI"
  npm_install_if_stale @openai/codex "Codex CLI"
  npm_install_if_stale @opencode/cli "OpenCode CLI"
  npm_install_if_stale @xai-official/grok "Grok CLI"
  # DeepSeek Harness — official DeepSeek native agent framework. bin: `dsh`,
  # profile/state under ${DSH_HOME:-~/.dsh}/profiles. Node ^22.19 || >=24.
  npm_install_if_stale @deepseek-ai/dsh "DeepSeek Harness CLI"
  # dsh-tui — Claude Code-style interactive TUI front door for dsh. bin: `dsh-tui`.
  npm_install_if_stale @deepseek-harness-tui/dsh-tui "DeepSeek Harness TUI"
  # Pi — earendil-works coding agent CLI (unified LLM API, agent loop, TUI). bin: `pi`.
  # Skills are loaded from ~/.pi/agent/skills/ and ~/.agents/skills/.
  npm_install_if_stale @earendil-works/pi-coding-agent "Pi coding agent CLI"
  # zg — zvec-grep: local-first search layer (ripgrep + BM25 + vector search)
  # for humans and agents. bin: `zg`. Requires Node.js >= 22.
  npm_install_if_stale @zvec/zvec-grep "zg (zvec-grep)"
  # Wire zg into supported AI agents via MCP (managed zvec_grep entry + search
  # guidance + tool approval + start local server). Idempotent — re-runs update
  # only the ZVEC_GREP_START/END managed blocks; --force absorbs any stray
  # unmanaged zvec_grep table (codex rewrites config.toml and drops the TOML
  # comment markers). dsh / pi / grok are not supported zg targets and skipped.
  # opencode is wired manually below (opencode v2 reads nested mcp.servers, but
  # zg 0.2.2 still writes flat v1 mcp.zvec_grep).
  if command -v zg >/dev/null 2>&1; then
    zg_targets=(cursor)  # GUI IDE, no CLI to detect — always wire
    for t in claude codex; do
      command -v "$t" >/dev/null 2>&1 && zg_targets+=("$t")
    done
    zg_args=(--force)
    for t in "${zg_targets[@]}"; do zg_args+=(--target "$t"); done
    log "Wiring zg MCP into AI agents: ${zg_targets[*]}"
    if zg_out=$(zg install "${zg_args[@]}" --yes 2>&1); then
      printf '%s\n' "$zg_out"
    else
      case "$zg_out" in
        *EADDRINUSE*)
          log "  zg daemon already running — daemon start skipped (benign)";;
        *conflicting*|*unmanaged*)
          printf '%s\n' "$zg_out" >&2
          warn "  zg install failed: MCP config conflict needs cleanup (see zg output above)";;
        *)
          printf '%s\n' "$zg_out" >&2
          warn "  zg install failed (see zg output above)";;
      esac
    fi
  fi

  # Register upstash/context7 as an MCP server for Claude Code & Codex.
  # Idempotent: `mcp add` errors if already registered, which we swallow.
  if command -v claude >/dev/null 2>&1; then
    log "Registering context7 MCP for Claude Code (idempotent)"
    claude mcp add context7 -s user -- npx -y @upstash/context7-mcp 2>/dev/null \
      || log "  context7 MCP already registered for claude (or registration failed — see 'claude mcp list')"
  fi
  if command -v codex >/dev/null 2>&1; then
    log "Registering context7 MCP for Codex (idempotent)"
    codex mcp add context7 -- npx -y @upstash/context7-mcp 2>/dev/null \
      || log "  context7 MCP already registered for codex (or registration failed — see 'codex mcp list')"
  fi

  # Register chrome-devtools MCP (local stdio via npx) for Claude Code & Codex.
  # Drives a real Chrome via the DevTools Protocol; idempotent — `mcp add`
  # errors if already registered, which we swallow.
  if command -v claude >/dev/null 2>&1; then
    log "Registering chrome-devtools MCP for Claude Code (idempotent)"
    claude mcp add chrome-devtools -s user -- npx -y chrome-devtools-mcp@latest 2>/dev/null \
      || log "  chrome-devtools MCP already registered for claude (or registration failed — see 'claude mcp list')"
  fi
  if command -v codex >/dev/null 2>&1; then
    log "Registering chrome-devtools MCP for Codex (idempotent)"
    codex mcp add chrome-devtools -- npx -y chrome-devtools-mcp@latest 2>/dev/null \
      || log "  chrome-devtools MCP already registered for codex (or registration failed — see 'codex mcp list')"
  fi

  # Register zcaceres/fetch-mcp (local stdio via npx, package `mcp-fetch-server`)
  # for Claude Code & Codex. Fetches web content as HTML/markdown/text/JSON.
  # Idempotent — `mcp add` errors if already registered, which we swallow.
  if command -v claude >/dev/null 2>&1; then
    log "Registering fetch MCP for Claude Code (idempotent)"
    claude mcp add fetch -s user -- npx -y mcp-fetch-server 2>/dev/null \
      || log "  fetch MCP already registered for claude (or registration failed — see 'claude mcp list')"
  fi
  if command -v codex >/dev/null 2>&1; then
    log "Registering fetch MCP for Codex (idempotent)"
    codex mcp add fetch -- npx -y mcp-fetch-server 2>/dev/null \
      || log "  fetch MCP already registered for codex (or registration failed — see 'codex mcp list')"
  fi

  # Register GitHub's official remote MCP server (streamable HTTP). The endpoint
  # does NOT support OAuth dynamic client registration, so clients must auth with a
  # PAT in an Authorization header. Token source: GITHUB_PERSONAL_ACCESS_TOKEN /
  # GH_TOKEN env vars, then the gh CLI's stored token. Claude/Codex register via
  # their CLIs; opencode takes a JSON `mcp` entry.
  GH_MCP_URL="https://api.githubcopilot.com/mcp/"
  GH_MCP_PAT="${GITHUB_PERSONAL_ACCESS_TOKEN:-${GH_TOKEN:-}}"
  if [ -z "$GH_MCP_PAT" ] && command -v gh >/dev/null 2>&1; then
    GH_MCP_PAT="$(gh auth token 2>/dev/null || true)"
  fi
  if command -v claude >/dev/null 2>&1; then
    if claude mcp get github >/dev/null 2>&1; then
      log "github MCP already registered for Claude Code (user scope)"
    elif [ -n "$GH_MCP_PAT" ]; then
      log "Registering github MCP for Claude Code (remote HTTP, PAT header)"
      claude mcp add --transport http github "$GH_MCP_URL" -H "Authorization: Bearer $GH_MCP_PAT" -s user >/dev/null \
        || warn "  github MCP registration FAILED — run: claude mcp add --transport http github $GH_MCP_URL -H \"Authorization: Bearer <PAT>\" -s user"
    else
      warn "  no GitHub PAT found (set GITHUB_PERSONAL_ACCESS_TOKEN or run 'gh auth login') — skipping github MCP for Claude Code (remote endpoint OAuth/DCR is unsupported)"
    fi
  fi
  if command -v codex >/dev/null 2>&1; then
    log "Registering github MCP for Codex (remote HTTP; run 'codex mcp login github' to OAuth)"
    codex mcp add github --url "$GH_MCP_URL" 2>/dev/null \
      || log "  github MCP already registered for codex (or registration failed — see 'codex mcp list')"
  fi
  # opencode: merge an `mcp.servers.github` (remote) entry into its JSON
  # config idempotently. v2 nests MCP servers under mcp.servers (v1 put them
  # directly under mcp).
  if command -v node >/dev/null 2>&1; then
    register_json_mcp() {  # $1=config file  $2=JSON object to merge under .mcp.servers
      MCP_FILE="$1" MCP_ADD="$2" node -e '
        const fs=require("fs"), path=require("path");
        const f=process.env.MCP_FILE, add=JSON.parse(process.env.MCP_ADD);
        let c={}; try{ c=JSON.parse(fs.readFileSync(f,"utf8")); }catch(e){}
        c.mcp=(c.mcp&&typeof c.mcp==="object")?c.mcp:{};
        c.mcp.servers=(c.mcp.servers&&typeof c.mcp.servers==="object")?c.mcp.servers:{};
        let changed=false;
        for(const [k,v] of Object.entries(add)){ if(!c.mcp.servers[k]){ c.mcp.servers[k]=v; changed=true; } }
        if(changed){ fs.mkdirSync(path.dirname(f),{recursive:true}); fs.writeFileSync(f, JSON.stringify(c,null,2)+"\n"); }
      ' || warn "  failed to write MCP config to $1"
    }
    # Build the github entry via node's JSON.stringify so a PAT containing quotes
    # or backslashes can't corrupt the JSON (hand-built strings would).
    GH_REMOTE_JSON="$(GH_MCP_URL="$GH_MCP_URL" GH_MCP_PAT="${GH_MCP_PAT:-}" node -e '
      const o={github:{type:"remote",url:process.env.GH_MCP_URL,oauth:false}};
      if(process.env.GH_MCP_PAT){ o.github.headers={Authorization:"Bearer "+process.env.GH_MCP_PAT}; }
      process.stdout.write(JSON.stringify(o));
    ')"
    CDT_LOCAL_JSON='{"chrome-devtools":{"type":"local","command":["npx","-y","chrome-devtools-mcp@latest"]}}'
    FETCH_LOCAL_JSON='{"fetch":{"type":"local","command":["npx","-y","mcp-fetch-server"],"timeout":{"startup":120000}}}'
    CTX7_LOCAL_JSON='{"context7":{"type":"local","command":["npx","-y","@upstash/context7-mcp"]}}'
    # zg (zvec-grep) — stdio bootstrap; starts/reuses the shared daemon.
    ZVEC_LOCAL_JSON='{"zvec_grep":{"type":"local","command":["zg","server","--stdio"],"timeout":600000}}'
    if command -v opencode >/dev/null 2>&1; then
      log "Registering github + chrome-devtools + fetch + context7 + zvec_grep MCP for opencode (~/.config/opencode/opencode.json)"
      register_json_mcp "$HOME/.config/opencode/opencode.json" "$GH_REMOTE_JSON"
      register_json_mcp "$HOME/.config/opencode/opencode.json" "$CDT_LOCAL_JSON"
      register_json_mcp "$HOME/.config/opencode/opencode.json" "$FETCH_LOCAL_JSON"
      register_json_mcp "$HOME/.config/opencode/opencode.json" "$CTX7_LOCAL_JSON"
      command -v zg >/dev/null 2>&1 && register_json_mcp "$HOME/.config/opencode/opencode.json" "$ZVEC_LOCAL_JSON"
    fi
  fi
else
  warn "npm not on PATH -- skipping npm-based CLI installs (ensure node was installed by brew bundle)"
fi

# ---------------------------------------------------------------------------
# 7c) pnpm — standalone binary (dsh invokes `pnpm` to install profile plugins).
#     Avoid corepack: the corepack bundled with node / brew can't run pnpm >= 10
#     (pnpm.cjs top-level dynamic import throws ERR_VM_DYNAMIC_IMPORT_CALLBACK_MISSING).
#     Gate on "can actually run", not command -v — a broken shim may already be on PATH.
# ---------------------------------------------------------------------------
if command -v npm >/dev/null 2>&1; then
  if ! pnpm --version >/dev/null 2>&1; then
    log "Installing standalone pnpm via npm"
    npm install -g pnpm || warn "  pnpm install failed"
  else
    log "pnpm: $(pnpm --version 2>/dev/null)"
  fi
else
  warn "npm not on PATH -- skipping pnpm install (ensure node was installed by brew bundle)"
fi

# ---------------------------------------------------------------------------
# 7d) Yunxing plugin (raptoravis/yunxing)
#     Claude Code — marketplace name "yunxing" (derived from
#     .claude-plugin/marketplace.json), plugin selector "yunxing@yunxing".
#     Also redundantly declared in common/claude/settings.json (enabledPlugins)
#     for fresh dotter-only setups.
#     Codex — marketplace name "yunxing", plugin selector "yunxing@yunxing"
#     (derived from .codex-plugin/plugin.json).
#     OpenCode — native plugin module via git URL.
# ---------------------------------------------------------------------------
# Claude Code — `claude plugin` CLI (declarative settings.json is the fallback).
if command -v claude >/dev/null 2>&1; then
  log "Installing/updating yunxing Claude Code plugin (marketplace: yunxing)"
  claude plugin marketplace add raptoravis/yunxing >/dev/null 2>&1 \
    || warn "  claude marketplace add failed (may already be registered)"
  # `install` is idempotent and won't pull newer code, so force a marketplace
  # refresh + `update` to pick up the latest yunxing on every re-run.
  claude plugin marketplace update yunxing >/dev/null 2>&1 \
    || warn "  claude marketplace update failed"
  if claude plugin list 2>/dev/null | grep -q 'yunxing@yunxing'; then
    claude plugin update yunxing@yunxing >/dev/null 2>&1 \
      || warn "  claude plugin update failed"
  else
    claude plugin install yunxing@yunxing >/dev/null 2>&1 \
      || warn "  claude plugin install failed (may already be enabled)"
  fi
else
  warn "claude CLI not on PATH -- falling back to settings.json declaration (re-run after claude is installed)"
fi

# Ensure a local yunxing checkout is up to date — it's the version reference for
# the Codex "reinstall only on a new version" check, and the source for the
# Cursor skills links below.
YUNXING_SRC="${XDG_DATA_HOME:-$HOME/.local/share}/yunxing"
if command -v git >/dev/null 2>&1; then
  if [ -d "$YUNXING_SRC/.git" ]; then
    log "Updating yunxing checkout"
    if ! git -C "$YUNXING_SRC" pull --ff-only --quiet 2>/dev/null; then
      warn "  yunxing pull failed — re-cloning"
      rm -rf "$YUNXING_SRC"
    fi
  fi
  if [ ! -d "$YUNXING_SRC/.git" ]; then
    log "Cloning yunxing checkout"
    mkdir -p "$(dirname "$YUNXING_SRC")"
    git clone --depth=1 --quiet https://github.com/raptoravis/yunxing.git "$YUNXING_SRC" \
      || warn "  yunxing clone failed"
  fi
else
  warn "git not on PATH -- skipping yunxing checkout (Cursor skills + Codex version check)"
fi

if command -v codex >/dev/null 2>&1; then
  # Reinstall the Codex plugin only when yunxing has a new version: compare the
  # installed version (codex plugin list) against the checkout's plugin.json.
  new_ver="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$YUNXING_SRC/.codex-plugin/plugin.json" 2>/dev/null | head -1)"
  installed_ver="$(codex plugin list 2>/dev/null | awk '/^yunxing@yunxing[[:space:]]/{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+(\.[0-9]+)+$/) {print $i; exit}}')"

  if [ -z "$new_ver" ]; then
    warn "  could not resolve yunxing version; skipping Codex plugin install"
  elif [ -n "$installed_ver" ] && [ "$installed_ver" = "$new_ver" ]; then
    log "  yunxing Codex plugin already up to date ($installed_ver)"
  else
    if [ -n "$installed_ver" ]; then
      log "Updating yunxing Codex plugin ($installed_ver -> $new_ver)"
    else
      log "Installing yunxing Codex plugin (marketplace: yunxing)"
    fi
    codex plugin marketplace add raptoravis/yunxing >/dev/null 2>&1 \
      || warn "  codex marketplace add failed"
    # `add` is idempotent and won't pull newer code, so refresh the marketplace
    # snapshot first — otherwise `plugin add` installs a stale version.
    codex plugin marketplace upgrade yunxing >/dev/null 2>&1 \
      || warn "  codex marketplace upgrade failed"

    # `plugin add` can fail with "Access denied" while codex is running (it holds
    # its plugin cache/state files open). Capture stderr to tell that case apart
    # from a real error.
    codex_err="$(codex plugin add yunxing@yunxing 2>&1)"
    if [ $? -ne 0 ]; then
      if printf '%s' "$codex_err" | grep -qi 'Access denied'; then
        warn "  codex plugin add failed: codex is running (close codex, then re-run)"
      elif [ -n "$codex_err" ]; then
        warn "  codex plugin add failed: $codex_err"
      else
        warn "  codex plugin add failed"
      fi
    fi
  fi
else
  warn "codex CLI not on PATH -- skipping Codex plugin install (re-run after codex is installed)"
fi

# OpenCode — native plugin module (one-step; no marketplace concept).
if command -v opencode >/dev/null 2>&1; then
  # 清理 opencode v1 遗留的 `plugin` 单数键（pin 到 commit hash 的残留）。v2 用
  # `plugins` 复数键，`opencode plugin remove` 只认复数键，旧 pin 条目会留成坏记录
  # （该 commit 的 yunxing 缺 default export），让 `plugin check`/`update` 遍历时失败。
  OC_CFG="$HOME/.config/opencode/opencode.json"
  if [ -f "$OC_CFG" ] && command -v node >/dev/null 2>&1; then
    OC_CFG="$OC_CFG" node -e '
      const fs=require("fs");
      let c; try{ c=JSON.parse(fs.readFileSync(process.env.OC_CFG,"utf8")); }catch(e){ process.exit(0); }
      if(c && typeof c==="object" && Object.prototype.hasOwnProperty.call(c,"plugin")){
        delete c.plugin; fs.writeFileSync(process.env.OC_CFG, JSON.stringify(c,null,2)+"\n");
        console.error("==> removed legacy opencode `plugin` key (v1 pinned residue)");
      }
    ' || warn "  failed to clean legacy opencode \`plugin\` key"
  fi
  log "Installing yunxing OpenCode plugin"
  # Unpinned spec: `add` is idempotent (no duplicate entries), and upgrades go
  # through `plugin update`. Pinning a full commit hash would give each re-run a
  # new spec and accumulate duplicate entries.
  opencode plugin add "yunxing@git+https://github.com/raptoravis/yunxing.git" >/dev/null 2>&1 \
    || warn "  opencode plugin add failed"
  opencode plugin update "yunxing@git+https://github.com/raptoravis/yunxing.git" >/dev/null 2>&1 \
    || warn "  opencode plugin update failed"
else
  warn "opencode CLI not on PATH -- skipping OpenCode plugin install (re-run after opencode is installed)"
fi

# dsh — DeepSeek Harness plugins (package.json dsh.bundle → cordis.patch.yml).
# dshmarket: in-harness plugin marketplace; dsh-context: context insight panel;
# dsh-browser-use: Browser Use Cloud bridge (removed; no 0.2.0-rc-compatible release);
# yunxing: local skill bundle via GitHub shorthand; modlens: vision/tools bundle
# (image → structured JSON evidence). `add` is non-idempotent, warn on repeat.
#
# Profiles install per directory, so a profile booted without these skill bundles
# composes no yunxing/modlens skill provider and its sessions list no yunxing or
# modlens skills. The bundles therefore go into EVERY profile already on disk — the
# earlier `web`-only loop left the TUI profile, the everyday entry point, skill-less.
# Re-run after creating a new profile. The web/UI plugins stay on `web`.
#
# dsh-tui is the exception: its profile is bootstrapped lazily by the launcher on
# first `dst` run, so it isn't on disk when this loop scans. Pre-install the skill
# bundles into it explicitly, or the TUI boots skill-less until the next re-run.
if command -v dsh >/dev/null 2>&1; then
  # Skill/tool bundles that must live in EVERY profile (skills are per-profile).
  dsh_bundles="github:raptoravis/yunxing @liustack/modlens"
  dsh_profiles_seen=0
  dsh_tui_covered=0
  for dsh_profile_dir in "${DSH_HOME:-$HOME/.dsh}"/profiles/*/; do
    [ -f "${dsh_profile_dir}package.json" ] || continue
    dsh_profile="$(basename "$dsh_profile_dir")"
    dsh_profiles_seen=$((dsh_profiles_seen + 1))
    [ "$dsh_profile" = "dsh-tui" ] && dsh_tui_covered=1
    for dsh_bundle in $dsh_bundles; do
      log "Installing dsh plugin: $dsh_bundle (profile: $dsh_profile)"
      dsh plugin --profile "$dsh_profile" add "$dsh_bundle" >/dev/null 2>&1 \
        || warn "  dsh plugin add failed on $dsh_profile (may already be installed)"
    done
  done
  if [ "$dsh_profiles_seen" -eq 0 ]; then
    # Fresh machine: no profile on disk yet — the plugin manager creates `web` on demand.
    for dsh_bundle in $dsh_bundles; do
      log "Installing dsh plugin: $dsh_bundle (profile: web)"
      dsh plugin --profile web add "$dsh_bundle" >/dev/null 2>&1 \
        || warn "  dsh plugin add failed on web (may already be installed)"
    done
  fi
  if [ "$dsh_tui_covered" -eq 0 ]; then
    for dsh_bundle in $dsh_bundles; do
      log "Installing dsh plugin: $dsh_bundle (profile: dsh-tui)"
      dsh plugin --profile dsh-tui add "$dsh_bundle" >/dev/null 2>&1 \
        || warn "  dsh plugin add failed on dsh-tui (may already be installed)"
    done
  fi

  for plugin in dshmarket dsh-context; do
    log "Installing dsh plugin: $plugin"
    dsh plugin --profile web add "$plugin" >/dev/null 2>&1 \
      || warn "  dsh plugin add $plugin failed (may already be installed)"
  done

  # dsh-browser-use (Browser Use Cloud bridge) has no release compatible with
  # dsh 0.2.0-rc — its peer @deepseek-ai/dsh-tools ^0.1.0-rc.6 pins it to 0.1.x.
  # Drop it so the web profile isn't denied at startup; re-add once upstream
  # ships a 0.2.0-rc-compatible build.
  if dsh plugin --profile web list 2>/dev/null | grep -q 'dsh-browser-use'; then
    log "Removing incompatible dsh plugin: dsh-browser-use"
    dsh plugin --profile web remove dsh-browser-use >/dev/null 2>&1 \
      || warn "  dsh plugin remove dsh-browser-use failed"
  fi

  # The dsh-tui launcher (`dst`) hard-fails when its version drifts from the
  # profile's @deepseek-harness-tui/dsh-tui bundle, so re-add the bundle at the
  # installed launcher version whenever the profile already exists (it is lazily
  # bootstrapped on first `dst`, so skip when absent).
  dsh_tui_launcher="$(npm list -g --depth=0 @deepseek-harness-tui/dsh-tui 2>/dev/null | sed -nE 's/.*@([^@]+)$/\1/p' | head -1)"
  if [ -n "$dsh_tui_launcher" ] && [ -f "${DSH_HOME:-$HOME/.dsh}/profiles/dsh-tui/package.json" ]; then
    log "Syncing dsh-tui bundle to launcher $dsh_tui_launcher"
    dsh plugin --profile dsh-tui add "@deepseek-harness-tui/dsh-tui@$dsh_tui_launcher" >/dev/null 2>&1 \
      || warn "  dsh plugin sync @deepseek-harness-tui/dsh-tui@$dsh_tui_launcher failed (may already be synced)"
  fi
else
  warn "dsh CLI not on PATH -- skipping dsh plugins (re-run after dsh is installed)"
fi

# Grok Build — grok CLI plugin. `grok plugin install <name>` treats <name> as a
# marketplace plugin name (fails); use GitHub shorthand (user/repo) to install
# directly. install is non-idempotent (repeat errors "already installed"), so
# guard with `grok plugin list`.
if command -v grok >/dev/null 2>&1; then
  if grok plugin list 2>/dev/null | grep -q 'yunxing'; then
    log "grok yunxing plugin already installed"
  else
    log "Installing yunxing Grok plugin (raptoravis/yunxing)"
    grok plugin install raptoravis/yunxing --trust >/dev/null 2>&1 \
      || warn "  grok plugin install failed"
  fi
else
  warn "grok CLI not on PATH -- skipping Grok plugin install (re-run after grok is installed)"
fi

# Cursor — no scriptable plugin install; symlink promoted skills into ~/.cursor/skills/.
# YUNXING_SRC is ensured above (shared with the Codex plugin version check).
if [ -d "$YUNXING_SRC/skills" ]; then
  log "Linking yunxing skills into ~/.cursor/skills"
  mkdir -p "$HOME/.cursor/skills"
  for skill in "$YUNXING_SRC"/skills/engineering/*/SKILL.md "$YUNXING_SRC"/skills/productivity/*/SKILL.md; do
    [ -e "$skill" ] || continue
    name="$(basename "$(dirname "$skill")")"
    ln -sfn "$(dirname "$skill")" "$HOME/.cursor/skills/$name"
  done
fi

# ---------------------------------------------------------------------------
# 7e) herdr agent skill — install the release-matched herdr SKILL.md into each
#     coding agent's global skills dir. `herdr --skill` prints the copy bundled
#     with the installed binary (no network, always matches the running version).
#     Written directly per-agent: grok isn't covered by the `npx skills` CLI.
# ---------------------------------------------------------------------------
if command -v herdr >/dev/null 2>&1; then
  log "Installing herdr skill into coding agents (claude/codex/grok/opencode/cursor)"
  herdr_skill_dir() { # $1 = target skill dir
    mkdir -p "$1"
    herdr --skill > "$1/SKILL.md" 2>/dev/null \
      || warn "  herdr --skill failed (writing $1)"
  }
  herdr_skill_dir "$HOME/.claude/skills/herdr"
  herdr_skill_dir "${CODEX_HOME:-$HOME/.codex}/skills/herdr"
  herdr_skill_dir "$HOME/.grok/skills/herdr"
  herdr_skill_dir "$HOME/.config/opencode/skills/herdr"
  herdr_skill_dir "$HOME/.cursor/skills/herdr"
else
  warn "herdr CLI not on PATH -- skipping herdr agent skill (re-run after herdr is installed)"
fi

# ---------------------------------------------------------------------------
# 7f) Codex subagents (awesome-codex-subagents) — clone/update into $HOME and
#     copy selected agents into ~/.codex/agents/ (global, available in every
#     project). Ships all of 01-core-development plus a curated set across
#     02-language-specialists and 05-data-ai.
# ---------------------------------------------------------------------------
CODEX_AGENTS_SRC="$HOME/awesome-codex-subagents"
CODEX_AGENTS_DST="${CODEX_HOME:-$HOME/.codex}/agents"
if command -v git >/dev/null 2>&1; then
  if [ -d "$CODEX_AGENTS_SRC/.git" ]; then
    log "Updating awesome-codex-subagents checkout"
    if ! git -C "$CODEX_AGENTS_SRC" pull --ff-only --quiet 2>/dev/null; then
      # pull failed — checkout is corrupt (e.g. lost .git/index); drop it and re-clone below.
      warn "  awesome-codex-subagents pull failed — re-cloning"
      rm -rf "$CODEX_AGENTS_SRC"
    fi
  fi
  if [ ! -d "$CODEX_AGENTS_SRC/.git" ]; then
    log "Cloning awesome-codex-subagents into $CODEX_AGENTS_SRC"
    git clone --depth=1 --quiet https://github.com/VoltAgent/awesome-codex-subagents.git "$CODEX_AGENTS_SRC" \
      || warn "  awesome-codex-subagents clone failed"
  fi
  if [ -d "$CODEX_AGENTS_SRC/categories" ]; then
    log "Syncing Codex subagents into $CODEX_AGENTS_DST"
    mkdir -p "$CODEX_AGENTS_DST"
    cp -f "$CODEX_AGENTS_SRC"/categories/01-core-development/*.toml "$CODEX_AGENTS_DST/" 2>/dev/null \
      || warn "  failed to copy 01-core-development agents"
    EXTRA_AGENTS=(
      02-language-specialists/node-specialist
      02-language-specialists/javascript-pro
      02-language-specialists/fastapi-developer
      02-language-specialists/nextjs-developer
      02-language-specialists/python-pro
      02-language-specialists/typescript-pro
      02-language-specialists/vue-expert
      02-language-specialists/react-specialist
      02-language-specialists/sql-pro
      05-data-ai/database-optimizer
      05-data-ai/postgres-pro
      05-data-ai/prompt-engineer
      05-data-ai/llm-architect
    )
    for rel in "${EXTRA_AGENTS[@]}"; do
      src="$CODEX_AGENTS_SRC/categories/$rel.toml"
      if [ -f "$src" ]; then
        cp -f "$src" "$CODEX_AGENTS_DST/"
      else
        warn "  missing agent: $rel.toml"
      fi
    done
  else
    warn "  awesome-codex-subagents/categories missing — skipping agent copy"
  fi
else
  warn "git not on PATH -- skipping Codex subagents install (re-run after git is installed)"
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
# 9b) Git global config
# ---------------------------------------------------------------------------
if command -v git >/dev/null 2>&1; then
  set_git() {
    local key="$1" val="$2"
    if [ "$(git config --global --get "$key" 2>/dev/null || echo __unset__)" != "$val" ]; then
      git config --global "$key" "$val"
      log "set git $key = $val"
    fi
  }
  # Identity: only set from env vars; never overwrite existing values.
  if [ -n "${GIT_USER_NAME:-}" ] && [ -z "$(git config --global --get user.name 2>/dev/null)" ]; then
    set_git user.name "$GIT_USER_NAME"
  fi
  if [ -n "${GIT_USER_EMAIL:-}" ] && [ -z "$(git config --global --get user.email 2>/dev/null)" ]; then
    set_git user.email "$GIT_USER_EMAIL"
  fi
  set_git http.version     HTTP/1.1
  set_git http.postBuffer  524288000
  set_git core.compression 0
  set_git core.quotepath   false
  # Proxy — only set if 127.0.0.1:7890 is actually reachable
  if (exec 3<>/dev/tcp/127.0.0.1/7890) 2>/dev/null; then
    exec 3>&- 3<&- 2>/dev/null || true
    set_git http.proxy  http://127.0.0.1:7890
    set_git https.proxy http://127.0.0.1:7890
  fi
  unset -f set_git
fi

# ---------------------------------------------------------------------------
# 9c) SSH: route github.com over 443 (port 22 is blocked on some networks)
# ---------------------------------------------------------------------------
SSH_DIR="$HOME/.ssh"
SSH_CONFIG="$SSH_DIR/config"
mkdir -p "$SSH_DIR" && chmod 700 "$SSH_DIR"
[ -f "$SSH_CONFIG" ] || { : > "$SSH_CONFIG"; chmod 600 "$SSH_CONFIG"; }
if ! grep -q '^[[:space:]]*Hostname[[:space:]]\+ssh\.github\.com' "$SSH_CONFIG" 2>/dev/null; then
  # Ensure trailing newline before appending
  [ -s "$SSH_CONFIG" ] && [ "$(tail -c1 "$SSH_CONFIG")" != "" ] && printf '\n' >> "$SSH_CONFIG"
  cat >> "$SSH_CONFIG" <<'EOF'
Host github.com
  Hostname ssh.github.com
  Port 443
  User git
EOF
  chmod 600 "$SSH_CONFIG"
  log "appended github.com:443 block to $SSH_CONFIG"
fi

# ---------------------------------------------------------------------------
# 10) Symlinks via dotter
# ---------------------------------------------------------------------------
if command -v dotter >/dev/null 2>&1; then
  log "Symlinking dotfiles via dotter"
  # --force: overwrite stray non-symlink targets (e.g. `zg install` writes
  # AGENTS.md as regular files before dotter runs) so symlinks always win.
  ( cd "$DOTFILES_DIR" && dotter -v --force ) || warn "dotter exited with errors"
else
  warn "dotter not on PATH — skipping symlinks. Re-run after \$HOME/.cargo/bin is on PATH."
fi

# ---------------------------------------------------------------------------
# 11) Default shell
# ---------------------------------------------------------------------------
ZSH_BIN="$(command -v zsh || echo /bin/zsh)"
if [[ "${SHELL:-}" != "$ZSH_BIN" ]]; then
  log "Default shell is $SHELL — to switch, run: chsh -s $ZSH_BIN"
fi

log "Done. Open a new terminal to pick up the environment."
echo
echo "============================================================"
