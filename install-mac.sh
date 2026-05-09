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

CLEAN=0
for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN=1 ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--clean]
  --clean  After install, remove agent-skill links / plugin-cache dirs /
           codex prompts that this script no longer manages.
EOF
      exit 0
      ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

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

if command -v graphify >/dev/null 2>&1; then
  for platform in claude codex opencode; do
    log "Registering graphify skill for $platform"
    graphify install --platform "$platform" >/dev/null 2>&1 \
      || warn "  graphify install --platform $platform failed"
  done
fi

# ---------------------------------------------------------------------------
# 7a-bis) Cross-CLI agent skills
#     Keep Claude, Codex native/shared, and OpenCode skill installs in sync.
#     Mirrors the Claude Code marketplace plugins that are platform-neutral:
#       handoff, andrej-karpathy-skills, understand-anything
#     Claude-Code-specific bits (slash /commands, hooks/hooks.json) are not
#     ported — they only run inside Claude Code.
# ---------------------------------------------------------------------------
if command -v git >/dev/null 2>&1; then
  AGENT_SKILLS="$HOME/.agents/skills"
  CLAUDE_SKILLS="$HOME/.claude/skills"
  CODEX_SKILLS="${CODEX_HOME:-$HOME/.codex}/skills"
  OPENCODE_SKILLS="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/skills"
  PLUGIN_CACHE="$HOME/.cache/dotfiles/agent-plugins"
  mkdir -p "$AGENT_SKILLS" "$CLAUDE_SKILLS" "$CODEX_SKILLS" "$OPENCODE_SKILLS" "$PLUGIN_CACHE"

  declare -A INSTALLED_SKILLS=() INSTALLED_PLUGINS=() INSTALLED_PROMPTS=()

  clone_or_pull() {
    local url="$1" dir="$2"
    if [[ -d "$dir/.git" ]]; then
      git -C "$dir" pull --quiet --ff-only 2>/dev/null || warn "  pull failed: $dir"
    else
      git clone --depth=1 --quiet "$url" "$dir" || warn "  clone failed: $url"
    fi
    INSTALLED_PLUGINS["$(basename "$dir")"]=1
  }

  link_skill() {
    local src="$1" name="$2"
    ln -sfn "$src" "$AGENT_SKILLS/$name"
    ln -sfn "$src" "$CLAUDE_SKILLS/$name"
    ln -sfn "$src" "$CODEX_SKILLS/$name"
    ln -sfn "$src" "$OPENCODE_SKILLS/$name"
    INSTALLED_SKILLS["$name"]=1
  }

  link_skills_from() {
    local repo="$1"
    find "$repo" -maxdepth 4 -name SKILL.md 2>/dev/null | while read -r f; do
      local src; src="$(dirname "$f")"
      local name; name="$(basename "$src")"
      link_skill "$src" "$name"
    done
  }

  log "Installing handoff skill (cross-CLI)"
  clone_or_pull https://github.com/willseltzer/claude-handoff "$PLUGIN_CACHE/claude-handoff"
  link_skills_from "$PLUGIN_CACHE/claude-handoff"

  log "Installing andrej-karpathy-skills (cross-CLI)"
  clone_or_pull https://github.com/forrestchang/andrej-karpathy-skills "$PLUGIN_CACHE/karpathy-skills"
  link_skills_from "$PLUGIN_CACHE/karpathy-skills"
  KARPATHY_WRAPPER="$PLUGIN_CACHE/karpathy-guidelines-skill"
  KARPATHY_UPSTREAM_SKILL="$PLUGIN_CACHE/karpathy-skills/skills/karpathy-guidelines/SKILL.md"
  if [[ ! -f "$KARPATHY_UPSTREAM_SKILL" && -f "$PLUGIN_CACHE/karpathy-skills/CLAUDE.md" && ! -e "$KARPATHY_WRAPPER/SKILL.md" ]]; then
    mkdir -p "$KARPATHY_WRAPPER"
    {
      printf -- '---\nname: karpathy-guidelines\ndescription: Behavioral guidelines (Andrej Karpathy) to reduce common LLM coding mistakes\n---\n\n'
      cat "$PLUGIN_CACHE/karpathy-skills/CLAUDE.md"
    } > "$KARPATHY_WRAPPER/SKILL.md"
  fi
  if [[ ! -f "$KARPATHY_UPSTREAM_SKILL" && -e "$KARPATHY_WRAPPER/SKILL.md" ]]; then
    link_skill "$KARPATHY_WRAPPER" karpathy-guidelines
  fi

  log "Installing excalidraw-diagram skill for claude / codex / opencode"
  clone_or_pull https://github.com/coleam00/excalidraw-diagram-skill "$PLUGIN_CACHE/excalidraw-diagram-skill"
  if [[ -f "$PLUGIN_CACHE/excalidraw-diagram-skill/SKILL.md" ]]; then
    link_skill "$PLUGIN_CACHE/excalidraw-diagram-skill" excalidraw-diagram
    if command -v uv >/dev/null 2>&1 && [[ -f "$PLUGIN_CACHE/excalidraw-diagram-skill/references/pyproject.toml" ]]; then
      log "  excalidraw-diagram: uv sync + playwright chromium (one-time)"
      ( cd "$PLUGIN_CACHE/excalidraw-diagram-skill/references" \
        && uv sync --quiet 2>/dev/null \
        && uv run --quiet playwright install chromium 2>/dev/null ) \
        || warn "  excalidraw-diagram: renderer deps install failed (run uv sync + uv run playwright install chromium in $PLUGIN_CACHE/excalidraw-diagram-skill/references)"
    else
      warn "  excalidraw-diagram: uv missing -- skill installed but renderer deps deferred"
    fi
  else
    warn "  excalidraw-diagram-skill: SKILL.md missing after clone"
  fi

  log "Installing html-ppt skill for claude / codex / opencode"
  clone_or_pull https://github.com/lewislulu/html-ppt-skill "$PLUGIN_CACHE/html-ppt-skill"
  if [[ -f "$PLUGIN_CACHE/html-ppt-skill/SKILL.md" ]]; then
    link_skill "$PLUGIN_CACHE/html-ppt-skill" html-ppt
  else
    warn "  html-ppt-skill: SKILL.md missing after clone"
  fi

  log "Installing understand-anything for claude / codex / opencode"
  if command -v curl >/dev/null 2>&1; then
    # Defensive: remove any stale real-dir residue under skill roots so
    # upstream's `ln -sfn` doesn't fail with "cannot overwrite directory".
    for root in "$AGENT_SKILLS" "$CLAUDE_SKILLS" "$CODEX_SKILLS" "$OPENCODE_SKILLS"; do
      if [[ -d "$root" ]]; then
        for d in "$root"/understand*; do
          [[ -d "$d" && ! -L "$d" ]] && rm -rf "$d"
        done
      fi
    done
    for tgt in claude codex opencode; do
      curl -fsSL https://raw.githubusercontent.com/Lum1104/Understand-Anything/main/install.sh \
        | bash -s "$tgt" || warn "  understand-anything install failed for $tgt"
    done
  fi

  # 5. anthropics/claude-plugins-official monorepo — pick portable subsets
  #    (frontend-design skill + commit-commands prompts). Other plugins in this
  #    monorepo are LSP wrappers / Claude-Code-only and skipped.
  log "Installing frontend-design skill (cross-CLI)"
  clone_or_pull https://github.com/anthropics/claude-plugins-official "$PLUGIN_CACHE/claude-plugins-official"
  CPO_PLUGINS="$PLUGIN_CACHE/claude-plugins-official/plugins"
  if [[ -f "$CPO_PLUGINS/frontend-design/skills/frontend-design/SKILL.md" ]]; then
    link_skill "$CPO_PLUGINS/frontend-design/skills/frontend-design" frontend-design
  else
    warn "  frontend-design: SKILL.md not found in upstream"
  fi

  # 7. (was: ruvnet/ruflo — clone + skill scan)
  #    ruflo is now installed as an npm CLI in the npm-globals block below to
  #    expose its full feature set (orchestrator, MCP server, hooks). Per-repo
  #    activation: `npx ruflo@latest init` and
  #    `claude mcp add ruflo -- npx ruflo@latest mcp start`.

  # 8. A7um/zero-review — code review plugin. Same pattern: clone and link any
  #    SKILL.md it ships.
  log "Installing zero-review (cross-CLI scan for SKILL.md)"
  clone_or_pull https://github.com/A7um/zero-review "$PLUGIN_CACHE/zero-review"
  link_skills_from "$PLUGIN_CACHE/zero-review"

  # 9. Codex slash-prompts ported from Claude Code commands/
  #    Copies select *.md command files into ~/.codex/prompts/ so they show up
  #    as /handoff-create, /commit etc. inside Codex (Codex doesn't
  #    auto-load Claude commands/, but does scan ~/.codex/prompts/).
  log "Installing Codex prompts (handoff / commit-commands)"
  CODEX_PROMPTS="${CODEX_HOME:-$HOME/.codex}/prompts"
  mkdir -p "$CODEX_PROMPTS"
  copy_prompt() {
    [[ -f "$1" ]] || return 0
    cp -f "$1" "$CODEX_PROMPTS/$2"
    INSTALLED_PROMPTS["$2"]=1
  }
  copy_prompt "$PLUGIN_CACHE/claude-handoff/commands/create.md"        handoff-create.md
  copy_prompt "$PLUGIN_CACHE/claude-handoff/commands/quick.md"         handoff-quick.md
  copy_prompt "$PLUGIN_CACHE/claude-handoff/commands/resume.md"        handoff-resume.md
  copy_prompt "$CPO_PLUGINS/commit-commands/commands/commit.md"         commit.md
  copy_prompt "$CPO_PLUGINS/commit-commands/commands/commit-push-pr.md" commit-push-pr.md
  copy_prompt "$CPO_PLUGINS/commit-commands/commands/clean_gone.md"     clean-gone.md

  # See install-linux.sh for rationale; keep this list symmetric across the
  # three install scripts.
  KNOWN_CODEX_PROMPTS=(handoff-create.md handoff-quick.md handoff-resume.md commit.md commit-push-pr.md clean-gone.md)

  if (( CLEAN )); then
    log "Clean mode: removing skills / plugins / codex prompts no longer managed by this script"

    for root in "$AGENT_SKILLS" "$CLAUDE_SKILLS" "$CODEX_SKILLS" "$OPENCODE_SKILLS"; do
      [[ -d "$root" ]] || continue
      for entry in "$root"/*; do
        [[ -L "$entry" ]] || continue
        target="$(readlink "$entry")"
        case "$target" in "$PLUGIN_CACHE"/*) ;; *) continue ;; esac
        name="$(basename "$entry")"
        if [[ -z "${INSTALLED_SKILLS[$name]:-}" ]]; then
          log "  rm stale skill link: $entry"
          rm -f "$entry"
        fi
      done
    done

    for entry in "$PLUGIN_CACHE"/*; do
      [[ -d "$entry" ]] || continue
      name="$(basename "$entry")"
      if [[ -z "${INSTALLED_PLUGINS[$name]:-}" ]]; then
        log "  rm stale plugin cache: $entry"
        rm -rf "$entry"
      fi
    done

    for p in "${KNOWN_CODEX_PROMPTS[@]}"; do
      if [[ -e "$CODEX_PROMPTS/$p" && -z "${INSTALLED_PROMPTS[$p]:-}" ]]; then
        log "  rm stale codex prompt: $p"
        rm -f "$CODEX_PROMPTS/$p"
      fi
    done
  fi
else
  warn "git not on PATH -- skipping cross-CLI agent-skill setup"
fi

# ---------------------------------------------------------------------------
# 7b) Claude Code companion CLIs (rtk hook)
#     Claude-specific marketplace plugins are declared in
#     common/claude/settings.json. Portable skills are installed above for all
#     supported coding CLIs.
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
  if ! command -v ruflo >/dev/null 2>&1; then
    log "Installing ruflo (multi-agent orchestrator) via npm"
    npm install -g ruflo@latest 2>/dev/null || warn "  ruflo install failed"
  fi
  # AI coding CLIs (Claude Code / Codex / OpenCode)
  if ! command -v claude >/dev/null 2>&1; then
    log "Installing Claude Code CLI (@anthropic-ai/claude-code)"
    npm install -g @anthropic-ai/claude-code 2>/dev/null || warn "  claude-code install failed"
  fi
  if ! command -v codex >/dev/null 2>&1; then
    log "Installing Codex CLI (@openai/codex)"
    npm install -g @openai/codex 2>/dev/null || warn "  codex install failed"
  fi
  if ! command -v opencode >/dev/null 2>&1; then
    log "Installing OpenCode CLI (opencode-ai)"
    npm install -g opencode-ai 2>/dev/null || warn "  opencode install failed"
  fi
else
  warn "npm not on PATH -- skipping npm-based CLI installs (ensure node was installed by brew bundle)"
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
echo
echo "============================================================"
echo " graphify: per-project setup"
echo "============================================================"
echo " For each project where you want a knowledge graph, run:"
echo
echo "   cd <your-project>"
echo "   graphify hook install     # auto-rebuild on commit/checkout"
echo "   graphify update .         # initial AST build (no API cost)"
echo
echo " Then in your AI coding CLI (any of these works):"
echo "   claude     # Claude Code     -> /graphify ."
echo "   codex      # OpenAI Codex    -> /graphify ."
echo "   opencode   # OpenCode        -> /graphify ."
echo "============================================================"
echo
echo "============================================================"
echo " openwolf: per-project setup"
echo "============================================================"
echo " For each project where you want OpenWolf context management:"
echo
echo "   cd <your-project>"
echo "   openwolf init             # creates .wolf/ in the project"
echo "   openwolf status           # check daemon health"
echo "   openwolf dashboard        # open browser dashboard"
echo
echo " Then your AI coding CLI will read .wolf/OPENWOLF.md each session."
echo "============================================================"
