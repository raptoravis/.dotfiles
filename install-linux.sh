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
CARGO_TOOLS=(dotter cargo-update vivid eza bottom bat yazi-fm yazi-cli abtop)
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

if command -v graphify >/dev/null 2>&1; then
  for platform in claude codex opencode; do
    log "Registering graphify skill for $platform"
    graphify install --platform "$platform" >/dev/null 2>&1 \
      || warn "  graphify install --platform $platform failed"
  done
fi

# ---------------------------------------------------------------------------
# 8a-bis) Cross-CLI agent skills
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

  # Track what THIS run installs so --clean can diff against on-disk state.
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

  # 3b. html-ppt-skill (single SKILL.md at repo root, no build step)
  log "Installing html-ppt skill for claude / codex / opencode"
  clone_or_pull https://github.com/lewislulu/html-ppt-skill "$PLUGIN_CACHE/html-ppt-skill"
  if [[ -f "$PLUGIN_CACHE/html-ppt-skill/SKILL.md" ]]; then
    link_skill "$PLUGIN_CACHE/html-ppt-skill" html-ppt
  else
    warn "  html-ppt-skill: SKILL.md missing after clone"
  fi

  # 4. understand-anything (upstream provides a multi-target installer)
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

  # 8. Codex slash-prompts ported from Claude Code commands/
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
# 8b) Claude Code companion CLIs (rtk hook)
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
  warn "npm not on PATH -- skipping npm-based CLI installs (apt nodejs may be too old; need Node 18+)"
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
  set_git user.name        raptoravis
  set_git user.email       raptoravis@gmail.com
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
