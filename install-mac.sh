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

# Ghostty is declared in Brewfile but brew bundle may skip already-installed
# casks without upgrading them. Ensure it's installed and up to date.
log "Installing/upgrading Ghostty terminal"
if command -v ghostty >/dev/null 2>&1; then
  brew upgrade --cask ghostty --no-quarantine --greedy-latest 2>/dev/null \
    && log "  ghostty upgraded" || log "  ghostty already up to date"
else
  brew install --cask ghostty --no-quarantine 2>/dev/null \
    || warn "  ghostty cask install failed (check Brewfile)"
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
  "yazi-fm:yazi"
  "yazi-cli:ya"
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
# 7a-bis) Cross-CLI agent skills
#     Keep Claude, Codex native/shared, and OpenCode skill installs in sync.
#     Mirrors the Claude Code marketplace plugins that are platform-neutral:
#       handoff, andrej-karpathy-skills
#     Claude-Code-specific bits (slash /commands, hooks/hooks.json) are not
#     ported — they only run inside Claude Code.
# ---------------------------------------------------------------------------
if command -v git >/dev/null 2>&1; then
  AGENT_SKILLS="$HOME/.agents/skills"
  CLAUDE_SKILLS="$HOME/.claude/skills"
  CODEX_SKILLS="${CODEX_HOME:-$HOME/.codex}/skills"
  OPENCODE_SKILLS="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/skills"
  REASONIX_SKILLS="${REASONIX_HOME:-$HOME/.reasonix}/skills"
  PLUGIN_CACHE="$HOME/.cache/dotfiles/agent-plugins"
  mkdir -p "$AGENT_SKILLS" "$CLAUDE_SKILLS" "$CODEX_SKILLS" "$OPENCODE_SKILLS" "$REASONIX_SKILLS" "$PLUGIN_CACHE"

  declare -A INSTALLED_SKILLS=() INSTALLED_PLUGINS=() INSTALLED_PROMPTS=()

  clone_or_pull() {
    local url="$1" dir="$2"
    if [[ -d "$dir/.git" ]]; then
      if ! git -C "$dir" pull --quiet --ff-only 2>/dev/null; then
        # upstream may have rewritten history (force-push/squash) — hard-reset
        # this throwaway mirror to the remote instead of staying diverged.
        git -C "$dir" fetch --quiet 2>/dev/null
        git -C "$dir" reset --hard --quiet '@{u}' 2>/dev/null || warn "  pull failed: $dir"
      fi
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
    ln -sfn "$src" "$REASONIX_SKILLS/$name"
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
      # Clear UV_INDEX_URL so uv.toml's aliyun mirror takes effect — the user's
      # shell may have a stale/broken mirror env var (e.g. tsinghua 403).
      sync_err=$(cd "$PLUGIN_CACHE/excalidraw-diagram-skill/references" && UV_INDEX_URL='' uv sync 2>&1)
      if [[ $? -eq 0 ]]; then
        UV_INDEX_URL='' uv run --quiet playwright install chromium 2>/dev/null \
          || warn "  excalidraw-diagram: playwright chromium install failed (run uv run playwright install chromium in $PLUGIN_CACHE/excalidraw-diagram-skill/references)"
      else
        warn "  excalidraw-diagram: uv sync failed: $(echo "$sync_err" | tail -n5)"
      fi
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

  # 3c. anysearch-skill (single SKILL.md at repo root, no build step)
  #     https://anysearch.com/install/skill-install.md
  log "Installing anysearch skill for claude / codex / opencode"
  clone_or_pull https://github.com/anysearch-ai/anysearch-skill "$PLUGIN_CACHE/anysearch-skill"
  if [[ -f "$PLUGIN_CACHE/anysearch-skill/SKILL.md" ]]; then
    link_skill "$PLUGIN_CACHE/anysearch-skill" anysearch
  else
    warn "  anysearch-skill: SKILL.md missing after clone"
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

  # 6a. nextlevelbuilder/ui-ux-pro-max-skill — multi-skill plugin monorepo
  #     (banner-design, brand, design-system, design, slides, ui-styling, ui-ux-pro-max)
  log "Installing ui-ux-pro-max skills (cross-CLI)"
  clone_or_pull https://github.com/nextlevelbuilder/ui-ux-pro-max-skill "$PLUGIN_CACHE/ui-ux-pro-max-skill"
  link_skills_from "$PLUGIN_CACHE/ui-ux-pro-max-skill"

  # 6b. vercel-labs/agent-skills — pick web-design-guidelines only
  log "Installing web-design-guidelines skill (cross-CLI)"
  clone_or_pull https://github.com/vercel-labs/agent-skills "$PLUGIN_CACHE/vercel-agent-skills"
  if [[ -f "$PLUGIN_CACHE/vercel-agent-skills/skills/web-design-guidelines/SKILL.md" ]]; then
    link_skill "$PLUGIN_CACHE/vercel-agent-skills/skills/web-design-guidelines" web-design-guidelines
  else
    warn "  web-design-guidelines: SKILL.md not found in upstream"
  fi

  # 6c. anthropics/skills — official skills monorepo; pick skill-creator, mcp-builder, webapp-testing
  log "Installing anthropics/skills subset (skill-creator / mcp-builder / webapp-testing)"
  clone_or_pull https://github.com/anthropics/skills "$PLUGIN_CACHE/anthropics-skills"
  for s in skill-creator mcp-builder webapp-testing; do
    if [[ -f "$PLUGIN_CACHE/anthropics-skills/skills/$s/SKILL.md" ]]; then
      link_skill "$PLUGIN_CACHE/anthropics-skills/skills/$s" "$s"
    else
      warn "  anthropics/skills/$s: SKILL.md not found"
    fi
  done

  # 6d. upstash/context7 — primarily an MCP server; also ships a find-docs SKILL.md.
  #     MCP registration happens after the claude CLI install (further down).
  log "Installing context7 find-docs skill (cross-CLI)"
  clone_or_pull https://github.com/upstash/context7 "$PLUGIN_CACHE/context7"
  if [[ -f "$PLUGIN_CACHE/context7/skills/find-docs/SKILL.md" ]]; then
    link_skill "$PLUGIN_CACHE/context7/skills/find-docs" find-docs
  else
    warn "  context7/find-docs: SKILL.md not found in upstream"
  fi

  # 6e. leonxlnx/taste-skill — anti-slop frontend design monorepo; pick
  #     design-taste-frontend, redesign-existing-projects, image-to-code.
  log "Installing taste-skill subset (design-taste-frontend / redesign-existing-projects / image-to-code)"
  clone_or_pull https://github.com/leonxlnx/taste-skill "$PLUGIN_CACHE/taste-skill"
  for entry in "taste-skill:design-taste-frontend" \
               "redesign-skill:redesign-existing-projects" \
               "image-to-code-skill:image-to-code"; do
    src_dir="${entry%%:*}"; link_name="${entry##*:}"
    if [[ -f "$PLUGIN_CACHE/taste-skill/skills/$src_dir/SKILL.md" ]]; then
      link_skill "$PLUGIN_CACHE/taste-skill/skills/$src_dir" "$link_name"
    else
      warn "  taste-skill/$src_dir: SKILL.md not found in upstream"
    fi
  done

  # 7. Codex slash-prompts ported from Claude Code commands/
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

    for root in "$AGENT_SKILLS" "$CLAUDE_SKILLS" "$CODEX_SKILLS" "$OPENCODE_SKILLS" "$REASONIX_SKILLS"; do
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
# 7b) Global npm tools (hostc — Cloudflare-Workers edge tunnel CLI)
# ---------------------------------------------------------------------------
if command -v npm >/dev/null 2>&1; then
  if ! command -v hostc >/dev/null 2>&1; then
    log "Installing hostc (edge tunnel CLI) via npm"
    npm install -g hostc || warn "  hostc install failed"
  fi
  if ! command -v claude-mem >/dev/null 2>&1; then
    log "Installing claude-mem via npm"
    npm install -g claude-mem || warn "  claude-mem install failed"
  fi
  if ! command -v codegraph >/dev/null 2>&1; then
    log "Installing codegraph via npm"
    npm install -g @colbymchenry/codegraph || warn "  codegraph install failed"
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
  if command -v codegraph >/dev/null 2>&1; then
    # Claude Code is wired separately via `claude mcp add` below (needs the
    # `claude` binary, installed in the AI-coding-CLIs block).
    log "Registering codegraph with codex / opencode"
    codegraph install --target=codex,opencode --yes >/dev/null 2>&1 \
      || warn "  codegraph install failed (run 'codegraph install' interactively)"
    # reasonix isn't a known codegraph target — register manually in its config.json
    REASONIX_CFG="${REASONIX_HOME:-$HOME/.reasonix}/config.json"
    if [ -f "$REASONIX_CFG" ] && command -v node >/dev/null 2>&1; then
      log "Registering codegraph MCP with reasonix"
      REASONIX_CFG="$REASONIX_CFG" node -e '
        const fs=require("fs"), p=process.env.REASONIX_CFG;
        const c=JSON.parse(fs.readFileSync(p,"utf8"));
        c.mcp=Array.isArray(c.mcp)?c.mcp:[];
        if(!c.mcp.some(m=>typeof m==="string"&&m.startsWith("codegraph="))){
          c.mcp.push("codegraph=codegraph serve --mcp");
          fs.writeFileSync(p, JSON.stringify(c,null,2)+"\n");
        }
      ' || warn "  failed to register codegraph with reasonix"
    fi
  fi
  # AI coding CLIs (Claude Code / Codex / OpenCode)
  if ! command -v claude >/dev/null 2>&1; then
    log "Installing Claude Code CLI (@anthropic-ai/claude-code)"
    npm install -g @anthropic-ai/claude-code || warn "  claude-code install failed"
  fi
  if ! command -v codex >/dev/null 2>&1; then
    log "Installing Codex CLI (@openai/codex)"
    npm install -g @openai/codex || warn "  codex install failed"
  fi
  if ! command -v opencode >/dev/null 2>&1; then
    log "Installing OpenCode CLI (opencode-ai)"
    npm install -g opencode-ai || warn "  opencode install failed"
  fi
  if ! command -v reasonix >/dev/null 2>&1; then
    log "Installing DeepSeek-Reasonix CLI (reasonix)"
    npm install -g reasonix || warn "  reasonix install failed (requires Node.js >= 22)"
  fi
  # Xiaomi MiMo Code — an OpenCode fork tuned for long-horizon tasks. bin: `mimo`,
  # config: ~/.config/mimocode/mimocode.json (same JSON schema as opencode).
  if ! command -v mimo >/dev/null 2>&1; then
    log "Installing Xiaomi MiMo Code CLI (@mimo-ai/cli)"
    npm install -g @mimo-ai/cli || warn "  mimo (MiMo Code) install failed"
  fi

  # Register upstash/context7 as an MCP server for Claude Code & Codex.
  # Idempotent: `mcp add` errors if already registered, which we swallow.
  if command -v claude >/dev/null 2>&1; then
    log "Registering context7 MCP for Claude Code (idempotent)"
    claude mcp add context7 -- npx -y @upstash/context7-mcp 2>/dev/null \
      || log "  context7 MCP already registered for claude (or registration failed — see 'claude mcp list')"
  fi
  if command -v claude >/dev/null 2>&1 && command -v codegraph >/dev/null 2>&1; then
    if claude mcp get codegraph >/dev/null 2>&1; then
      log "codegraph MCP already registered for Claude Code (user scope)"
    else
      log "Registering codegraph MCP for Claude Code (user scope)"
      claude mcp add codegraph -s user -- codegraph serve --mcp >/dev/null \
        || warn "  codegraph MCP registration FAILED — run manually: claude mcp add codegraph -s user -- codegraph serve --mcp"
    fi
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
    claude mcp add chrome-devtools -- npx -y chrome-devtools-mcp@latest 2>/dev/null \
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
    claude mcp add fetch -- npx -y mcp-fetch-server 2>/dev/null \
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
  # their CLIs; opencode & MiMo Code (an opencode fork) take a JSON `mcp` entry.
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
  # opencode + MiMo Code: merge an `mcp.github` (remote) entry into their JSON
  # config idempotently. MiMo additionally gets codegraph (local) since
  # `codegraph install` doesn't know the mimocode target.
  if command -v node >/dev/null 2>&1; then
    register_json_mcp() {  # $1=config file  $2=JSON object to merge under .mcp
      MCP_FILE="$1" MCP_ADD="$2" node -e '
        const fs=require("fs"), path=require("path");
        const f=process.env.MCP_FILE, add=JSON.parse(process.env.MCP_ADD);
        let c={}; try{ c=JSON.parse(fs.readFileSync(f,"utf8")); }catch(e){}
        c.mcp=(c.mcp&&typeof c.mcp==="object")?c.mcp:{};
        let changed=false;
        for(const [k,v] of Object.entries(add)){ if(!c.mcp[k]){ c.mcp[k]=v; changed=true; } }
        if(changed){ fs.mkdirSync(path.dirname(f),{recursive:true}); fs.writeFileSync(f, JSON.stringify(c,null,2)+"\n"); }
      ' || warn "  failed to write MCP config to $1"
    }
    if [ -n "$GH_MCP_PAT" ]; then
      GH_REMOTE_JSON="{\"github\":{\"type\":\"remote\",\"url\":\"$GH_MCP_URL\",\"enabled\":true,\"headers\":{\"Authorization\":\"Bearer $GH_MCP_PAT\"}}}"
    else
      GH_REMOTE_JSON="{\"github\":{\"type\":\"remote\",\"url\":\"$GH_MCP_URL\",\"enabled\":true}}"
    fi
    CG_LOCAL_JSON='{"codegraph":{"type":"local","command":["codegraph","serve","--mcp"],"enabled":true}}'
    CDT_LOCAL_JSON='{"chrome-devtools":{"type":"local","command":["npx","-y","chrome-devtools-mcp@latest"],"enabled":true}}'
    FETCH_LOCAL_JSON='{"fetch":{"type":"local","command":["npx","-y","mcp-fetch-server"],"enabled":true}}'
    if command -v opencode >/dev/null 2>&1; then
      log "Registering github + chrome-devtools + fetch MCP for opencode (~/.config/opencode/opencode.json)"
      register_json_mcp "$HOME/.config/opencode/opencode.json" "$GH_REMOTE_JSON"
      register_json_mcp "$HOME/.config/opencode/opencode.json" "$CDT_LOCAL_JSON"
      register_json_mcp "$HOME/.config/opencode/opencode.json" "$FETCH_LOCAL_JSON"
    fi
    if command -v mimo >/dev/null 2>&1; then
      log "Registering github + codegraph + chrome-devtools + fetch MCP for MiMo Code (~/.config/mimocode/mimocode.json)"
      register_json_mcp "$HOME/.config/mimocode/mimocode.json" "$GH_REMOTE_JSON"
      command -v codegraph >/dev/null 2>&1 \
        && register_json_mcp "$HOME/.config/mimocode/mimocode.json" "$CG_LOCAL_JSON"
      register_json_mcp "$HOME/.config/mimocode/mimocode.json" "$CDT_LOCAL_JSON"
      register_json_mcp "$HOME/.config/mimocode/mimocode.json" "$FETCH_LOCAL_JSON"
    fi
  fi
  # reasonix: its `mcp` config is a stdio command-string array and can't take a
  # remote HTTP url, so it keeps its existing stdio github server (PAT-based).
else
  warn "npm not on PATH -- skipping npm-based CLI installs (ensure node was installed by brew bundle)"
fi

# ---------------------------------------------------------------------------
# 7c) pnpm via corepack (ships with Node >= 16.10)
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
  ( cd "$DOTFILES_DIR" && dotter -v ) || warn "dotter exited with errors"
else
  warn "dotter not on PATH — skipping symlinks. Re-run after \$HOME/.cargo/bin is on PATH."
fi

# ---------------------------------------------------------------------------
# 10b) MANUAL: sync Claude settings into cc-switch
#      ~/.claude/settings.json is NOT symlinked by dotter — cc-switch owns it
#      and injects the env block (ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN) on
#      every provider switch. The repo's common/claude/settings.json is the
#      shared *base* (permissions / hooks / enabledPlugins / statusLine). Copy
#      that base into cc-switch's common config ("通用配置") by hand so cc-switch
#      composes base + per-provider env into ~/.claude/settings.json.
# ---------------------------------------------------------------------------
warn 'MANUAL STEP: sync common/claude/settings.json into cc-switch "通用配置" (cc-switch owns ~/.claude/settings.json; dotter no longer symlinks it).'

# ---------------------------------------------------------------------------
# 11) Ghostty config directory — pre-create so dotter can symlink into it.
# ---------------------------------------------------------------------------
mkdir -p "$HOME/.config/ghostty"

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
echo " codegraph: per-project setup"
echo "============================================================"
echo " For each project where you want a knowledge graph, run:"
echo
echo "   cd <your-project>"
echo "   codegraph init -i         # interactive: index + register MCP"
echo "   codegraph sync            # incremental update"
echo
echo " Agents call codegraph_search / _context / _explore via MCP."
echo " Output lives in .codegraph/ (gitignored)."
echo "============================================================"
