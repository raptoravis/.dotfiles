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
  jq ffmpeg
)
sudo -E apt-get install -y -qq "${APT_PKGS[@]}"
(( IS_WSL )) && sudo -E apt-get install -y -qq wslu 2>/dev/null || true

# Ensure node/npm are on PATH after apt install.
# On Debian/Ubuntu the 'nodejs' package provides /usr/bin/nodejs (not /usr/bin/node).
# Create a symlink if only nodejs exists, so 'node' resolves too.
if ! command -v node >/dev/null 2>&1 && command -v nodejs >/dev/null 2>&1; then
  sudo ln -sf "$(command -v nodejs)" /usr/local/bin/node
  log "  symlinked /usr/local/bin/node -> nodejs"
fi
if command -v node >/dev/null 2>&1; then
  log "node: $(node --version 2>/dev/null || echo '?')"
else
  warn "node not on PATH after apt install — consider nodesource.com/setup_22.x for a current Node.js"
fi
if command -v npm >/dev/null 2>&1; then
  log "npm:  $(npm --version 2>/dev/null || echo '?')"
else
  warn "npm not on PATH after apt install — consider nodesource.com/setup_22.x for a current Node.js"
fi

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

# VS Code — only on bare Linux (WSL2 uses the Windows host's VS Code via code
# command, which resolves through the Windows PATH in WSL interop).
if (( ! IS_WSL )) && ! command -v code >/dev/null 2>&1; then
  log "Installing VS Code via Microsoft apt repo"
  sudo install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
    | sudo gpg --yes --dearmor -o /etc/apt/keyrings/packages.microsoft.gpg
  echo 'deb [signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main' \
    | sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null
  sudo -E apt-get update -qq
  sudo -E apt-get install -y -qq code || warn "  VS Code install failed"
elif (( IS_WSL )); then
  log "  WSL2 detected — VS Code available via Windows host (code .)"
fi

# GitHub CLI (gh) — Ubuntu/Debian's apt `gh` lags behind upstream by months;
# use the official cli.github.com keyring repo for current builds.
if ! command -v gh >/dev/null 2>&1; then
  log "Installing GitHub CLI via official apt repo"
  sudo install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo gpg --yes --dearmor -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
  sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  sudo -E apt-get update -qq
  sudo -E apt-get install -y -qq gh || warn "  gh install failed"
fi

# cloudflared — Cloudflare Tunnel client (内网穿透). Use Cloudflare's apt repo
# so we get current builds and auto-updates; distro repos don't ship it.
if ! command -v cloudflared >/dev/null 2>&1; then
  log "Installing cloudflared via official apt repo"
  sudo install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
    | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
  CF_CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null)}")"
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared ${CF_CODENAME} main" \
    | sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
  sudo -E apt-get update -qq
  sudo -E apt-get install -y -qq cloudflared || warn "  cloudflared install failed"
fi

# witr — "why is this running?" CLI. Not packaged in apt; use upstream
# install.sh with INSTALL_PREFIX so it lands in ~/.local/bin without sudo.
if ! command -v witr >/dev/null 2>&1; then
  log "Installing witr via upstream install.sh"
  mkdir -p "$HOME/.local/bin" "$HOME/.local/share/man/man1"
  INSTALL_PREFIX="$HOME/.local" \
    bash -c "$(curl -fsSL https://raw.githubusercontent.com/pranshuparmar/witr/main/install.sh)" \
    || warn "  witr install failed"
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
CARGO_TOOLS=(dotter cargo-update vivid eza bottom bat yazi-fm yazi-cli abtop silicon ast-grep)
for tool in "${CARGO_TOOLS[@]}"; do
  if cargo install "$tool" 2>&1 | tail -n1; then
    # Verify binary landed — cargo may exit 0 but still fail to link.
    bin_path="$HOME/.cargo/bin/$tool"
    if [[ -x "$bin_path" ]]; then
      log "  -> $bin_path"
    else
      warn "  $tool: cargo reported OK but $bin_path not found — check cargo output above for linker/build errors"
    fi
  else
    warn "  failed: $tool"
  fi
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
  go install github.com/charmbracelet/vhs@latest        || warn "  vhs failed"
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
# 8a-bis) Cross-CLI agent skills
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

  # Track what THIS run installs so --clean can diff against on-disk state.
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

  # 1. handoff
  log "Installing handoff skill (cross-CLI)"
  clone_or_pull https://github.com/willseltzer/claude-handoff "$PLUGIN_CACHE/claude-handoff"
  link_skills_from "$PLUGIN_CACHE/claude-handoff"

  # 2. andrej-karpathy-skills (single CLAUDE.md — wrap into a SKILL.md)
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

  # 3a. excalidraw-diagram-skill (single SKILL.md at repo root — link for claude/codex/opencode)
  log "Installing excalidraw-diagram skill for claude / codex / opencode"
  clone_or_pull https://github.com/coleam00/excalidraw-diagram-skill "$PLUGIN_CACHE/excalidraw-diagram-skill"
  if [[ -f "$PLUGIN_CACHE/excalidraw-diagram-skill/SKILL.md" ]]; then
    link_skill "$PLUGIN_CACHE/excalidraw-diagram-skill" excalidraw-diagram
    # Pre-install renderer deps (uv + playwright chromium) so the skill works on first run
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

  # 3b. html-ppt-skill (single SKILL.md at repo root, no build step)
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

  # 6c. anthropics/skills — official monorepo; pick skill-creator, mcp-builder, webapp-testing
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
  #     MCP registration happens after the claude/codex CLI install (further down).
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
  #    as /handoff-create, /zr-dev, /commit etc. inside Codex (Codex doesn't
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

  # Files this script has historically copied into $CODEX_PROMPTS. Used by
  # --clean to drop entries that are no longer in INSTALLED_PROMPTS. Add the
  # filename here whenever you add a copy_prompt line; remove it only after
  # the script has stopped shipping that prompt for at least one --clean run
  # on every machine you care about.
  KNOWN_CODEX_PROMPTS=(handoff-create.md handoff-quick.md handoff-resume.md commit.md commit-push-pr.md clean-gone.md)

  if (( CLEAN )); then
    log "Clean mode: removing skills / plugins / codex prompts no longer managed by this script"

    # 1) Skill symlinks pointing into $PLUGIN_CACHE that are not in this run's set.
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

    # 2) Plugin-cache subdirs that are no longer cloned by this script.
    for entry in "$PLUGIN_CACHE"/*; do
      [[ -d "$entry" ]] || continue
      name="$(basename "$entry")"
      if [[ -z "${INSTALLED_PLUGINS[$name]:-}" ]]; then
        log "  rm stale plugin cache: $entry"
        rm -rf "$entry"
      fi
    done

    # 3) Codex prompts in the known-managed set that this run did not ship.
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
# 8b) Global npm tools (hostc — Cloudflare-Workers edge tunnel CLI)
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
    npm i -g reasonix@next || warn "  reasonix install failed (requires Node.js >= 22)"
  fi
  # Xiaomi MiMo Code — an OpenCode fork tuned for long-horizon tasks. bin: `mimo`,
  # config: ~/.config/mimocode/mimocode.json (same JSON schema as opencode).
  if ! command -v mimo >/dev/null 2>&1; then
    log "Installing Xiaomi MiMo Code CLI (@mimo-ai/cli)"
    npm install -g @mimo-ai/cli || warn "  mimo (MiMo Code) install failed"
  fi

  # Register tunan as a native plugin for Claude Code (enables slash commands,
  # MCP auto-load, agents, and hooks). Add marketplace source then install or update.
  if command -v claude >/dev/null 2>&1; then
    log "Registering tunan native plugin for Claude Code"
    claude plugins marketplace add https://github.com/raptoravis/tunan 2>/dev/null \
      || log "  tunan marketplace already registered for claude (or command failed)"
    if claude plugins install tunan@tunan -s user 2>/dev/null; then
      log "  tunan installed for claude"
    else
      log "  tunan already installed, updating for claude..."
      claude plugins update tunan@tunan 2>/dev/null \
        || warn "  tunan update for claude failed"
    fi
  fi
  # Register tunan as a native plugin for OpenCode (enables slash commands,
  # MCP auto-load, and agents). Idempotent — `plugin -g` no-ops if already installed.
  if command -v opencode >/dev/null 2>&1; then
    log "Registering tunan native plugin for OpenCode"
    if opencode plugin -g tunan@git+https://github.com/raptoravis/tunan.git 2>/dev/null; then
      log "  tunan registered for opencode"
    else
      log "  tunan already registered, updating for opencode..."
      opencode plugin update tunan 2>/dev/null \
        || warn "  tunan update for opencode failed"
    fi
  fi
  # Register tunan as a plugin marketplace source for Codex. The user must
  # then run `/plugins` inside Codex to install the plugin interactively.
  if command -v codex >/dev/null 2>&1; then
    log "Registering tunan plugin marketplace for Codex"
    codex plugin marketplace add raptoravis/tunan 2>/dev/null \
      || log "  tunan marketplace already registered for codex (or command failed — see 'codex plugin marketplace list')"
  fi
  # Register tunan skills for Reasonix (no native plugin support; use npx-based skill install).
  if command -v npx >/dev/null 2>&1; then
    log "Installing tunan skills for Reasonix via npx"
    if npx skills add raptoravis/tunan --skill '*' -a reasonix -g -y 2>/dev/null; then
      log "  tunan skills installed for reasonix"
    else
      log "  tunan skills already installed, updating for reasonix..."
      npx skills add raptoravis/tunan --skill '*' -a reasonix -g -y 2>/dev/null \
        || warn "  tunan skills update for reasonix failed"
    fi

    log "Installing threejs-game-skills via npx (claude-code / codex / opencode / reasonix)"
    for agent in claude-code codex opencode reasonix; do
      if npx skills add majidmanzarpour/threejs-game-skills --skill '*' -a "$agent" -g -y 2>/dev/null; then
        log "  threejs-game-skills installed for $agent"
      else
        log "  threejs-game-skills already installed, updating for $agent..."
        npx skills add majidmanzarpour/threejs-game-skills --skill '*' -a "$agent" -g -y 2>/dev/null \
          || warn "  threejs-game-skills update for $agent failed"
      fi
    done
  fi

  # Register upstash/context7 as an MCP server for Claude Code & Codex.
  # Idempotent: `mcp add` errors if already registered, which we swallow.
  if command -v claude >/dev/null 2>&1; then
    log "Registering context7 MCP for Claude Code (idempotent)"
    claude mcp add context7 -- npx -y @upstash/context7-mcp 2>/dev/null \
      || log "  context7 MCP already registered for claude (or registration failed — see 'claude mcp list')"
  fi
  if command -v claude >/dev/null 2>&1 && command -v codegraph >/dev/null 2>&1; then
    log "Registering codegraph MCP for Claude Code (user scope)"
    codegraph install --target=claude --yes 2>/dev/null \
      || warn "  codegraph MCP registration for claude FAILED — run 'codegraph install' interactively"
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
    CTX7_LOCAL_JSON='{"context7":{"type":"local","command":["npx","-y","@upstash/context7-mcp"],"enabled":true}}'
    if command -v opencode >/dev/null 2>&1; then
      log "Registering github + chrome-devtools + fetch + context7 MCP for opencode (~/.config/opencode/opencode.json)"
      register_json_mcp "$HOME/.config/opencode/opencode.json" "$GH_REMOTE_JSON"
      register_json_mcp "$HOME/.config/opencode/opencode.json" "$CDT_LOCAL_JSON"
      register_json_mcp "$HOME/.config/opencode/opencode.json" "$FETCH_LOCAL_JSON"
      register_json_mcp "$HOME/.config/opencode/opencode.json" "$CTX7_LOCAL_JSON"
    fi
    if command -v mimo >/dev/null 2>&1; then
      log "Registering github + codegraph + chrome-devtools + fetch MCP for MiMo Code (~/.config/mimocode/mimocode.json)"
      register_json_mcp "$HOME/.config/mimocode/mimocode.json" "$GH_REMOTE_JSON"
      command -v codegraph >/dev/null 2>&1 \
        && register_json_mcp "$HOME/.config/mimocode/mimocode.json" "$CG_LOCAL_JSON"
      register_json_mcp "$HOME/.config/mimocode/mimocode.json" "$CDT_LOCAL_JSON"
      register_json_mcp "$HOME/.config/mimocode/mimocode.json" "$FETCH_LOCAL_JSON"
    fi
    # reasonix: its `mcp` config is a stdio command-string array (`"name=cmd args"`).
    # Can't take a remote HTTP url so github stays with its existing stdio server.
    REASONIX_CFG="${REASONIX_HOME:-$HOME/.reasonix}/config.json"
    if [ -f "$REASONIX_CFG" ]; then
      log "Registering context7 + chrome-devtools + fetch MCP with reasonix"
      REASONIX_CFG="$REASONIX_CFG" node -e '
        const fs=require("fs"), p=process.env.REASONIX_CFG;
        const c=JSON.parse(fs.readFileSync(p,"utf8"));
        c.mcp=Array.isArray(c.mcp)?c.mcp:[];
        const entries=["context7=npx -y @upstash/context7-mcp","chrome-devtools=npx -y chrome-devtools-mcp@latest","fetch=npx -y mcp-fetch-server"];
        let changed=false;
        for(const e of entries){const n=e.split("=")[0];if(!c.mcp.some(m=>typeof m==="string"&&m.startsWith(n+"="))){c.mcp.push(e);changed=true;}}
        if(changed)fs.writeFileSync(p,JSON.stringify(c,null,2)+"\n");
      ' || warn "  failed to register MCPs with reasonix"
    fi
  fi
else
  warn "npm not on PATH -- skipping npm-based CLI installs (apt nodejs may be too old; need Node 18+)"
fi

# ---------------------------------------------------------------------------
# 8c) pnpm via corepack
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
# 11b) Git global config
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
# 11c) SSH: route github.com over 443 (port 22 is blocked on some networks)
# ---------------------------------------------------------------------------
SSH_DIR="$HOME/.ssh"
SSH_CONFIG="$SSH_DIR/config"
mkdir -p "$SSH_DIR" && chmod 700 "$SSH_DIR"
[ -f "$SSH_CONFIG" ] || { : > "$SSH_CONFIG"; chmod 600 "$SSH_CONFIG"; }
if ! grep -q '^[[:space:]]*Hostname[[:space:]]\+ssh\.github\.com' "$SSH_CONFIG" 2>/dev/null; then
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
# 12) Symlinks via dotter
# ---------------------------------------------------------------------------
if command -v dotter >/dev/null 2>&1; then
  log "Symlinking dotfiles via dotter"
  ( cd "$DOTFILES_DIR" && dotter -v ) || warn "dotter exited with errors"
else
  warn "dotter not on PATH — skipping symlinks. Open a new shell so \$HOME/.cargo/bin is loaded, then re-run."
fi

# ---------------------------------------------------------------------------
# 12b) MANUAL: sync Claude settings into cc-switch
#      ~/.claude/settings.json is NOT symlinked by dotter — cc-switch owns it
#      and injects the env block (ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN) on
#      every provider switch. The repo's common/claude/settings.json is the
#      shared *base* (permissions / hooks / enabledPlugins / statusLine). Copy
#      that base into cc-switch's common config ("通用配置") by hand so cc-switch
#      composes base + per-provider env into ~/.claude/settings.json.
# ---------------------------------------------------------------------------
warn 'MANUAL STEP: sync common/claude/settings.json into cc-switch "通用配置" (cc-switch owns ~/.claude/settings.json; dotter no longer symlinks it).'

# ---------------------------------------------------------------------------
# 13) WezTerm session state directory — only needed if wezterm is installed.
# ---------------------------------------------------------------------------
if command -v wezterm >/dev/null 2>&1; then
  mkdir -p "$HOME/.local/share/wezterm/sessions"
fi

# ---------------------------------------------------------------------------
# 12) Default shell
# ---------------------------------------------------------------------------
ZSH_BIN="$(command -v zsh || echo /usr/bin/zsh)"
if [[ "${SHELL:-}" != "$ZSH_BIN" ]]; then
  log "Default shell is $SHELL — to switch, run: chsh -s $ZSH_BIN"
fi

log "Done. Open a new terminal (or 'wsl --shutdown' on WSL) to pick up the environment."
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
