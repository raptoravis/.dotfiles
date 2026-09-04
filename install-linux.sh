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

UNINSTALL_AGENTS=0
for arg in "$@"; do
  case "$arg" in
    --uninstallagents) UNINSTALL_AGENTS=1 ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--uninstallagents]
  --uninstallagents  Uninstall all AI agent CLIs (Claude Code, Codex, OpenCode,
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
    for pkg in "@anthropic-ai/claude-code" "@openai/codex" "opencode-ai" "@deepseek-ai/dsh" "@earendil-works/pi-coding-agent"; do
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
IS_WSL=0
grep -qi 'microsoft\|wsl' /proc/version 2>/dev/null && IS_WSL=1

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; }

# WSL interop 会把 Windows 的 PATH 追加进来（appendWindowsPath=true），于是
# `command -v claude` 可能命中 /mnt/c/... 下的 Windows 同名二进制。对 AI agent
# CLI 我们只关心 WSL 本地安装，把 /mnt/*（以及 UNC //*）当作「不存在」，避免
# 安装/注册守卫被 Windows host 的版本骗过而静默跳过。
cmd_exists_local() {
  local p
  p="$(command -v "$1" 2>/dev/null)" || return 1
  [[ "$p" != /mnt/* && "$p" != //* ]]
}

if [[ "$(uname -s)" != "Linux" ]]; then
  err "Linux/WSL2 only. Detected: $(uname -s)"
  exit 1
fi
(( IS_WSL )) && log "WSL2 detected" || log "Pure Linux detected"

# ---------------------------------------------------------------------------
# 0) 网络代理 — 检测 Clash 7890 端口，设置全局代理环境变量，让 curl/git/wget/
#    npm/go 等自动走代理。TUN 模式对 https(443) 超时，走 7890 由 Clash 规则
#    分流（国内直连 / 海外走节点）秒通。
# ---------------------------------------------------------------------------
if (exec 3<>/dev/tcp/127.0.0.1/7890) 2>/dev/null; then
  exec 3>&- 3<&- 2>/dev/null || true
  export http_proxy=http://127.0.0.1:7890
  export https_proxy=http://127.0.0.1:7890
  export HTTP_PROXY=http://127.0.0.1:7890
  export HTTPS_PROXY=http://127.0.0.1:7890
  export no_proxy=localhost,127.0.0.1
  export NO_PROXY=localhost,127.0.0.1
  log "检测到 7890 代理 — 设置全局 http(s)_proxy"

  # 持久化到 bash 交互 shell（WSL 默认 login shell 是 bash）。zsh 的代理已在
  # common/zsh/.zshenv 持久化，但 bash 的 ~/.bashrc 没有——补上，让 gh/curl/
  # git 等 CLI 在 bash 里也自动走 7890。幂等：已含 PROXY_URL 则跳过。
  if [[ -f "$HOME/.bashrc" ]] && ! grep -q 'PROXY_URL=' "$HOME/.bashrc" 2>/dev/null; then
    log "持久化代理到 ~/.bashrc"
    cat >> "$HOME/.bashrc" <<'EOF'

# Proxy (Clash / mihomo default port 7890) — mirrors common/zsh/.zshenv
export PROXY_URL="http://127.0.0.1:7890"
export http_proxy="$PROXY_URL"
export https_proxy="$PROXY_URL"
export all_proxy="$PROXY_URL"
export HTTP_PROXY="$PROXY_URL"
export HTTPS_PROXY="$PROXY_URL"
export ALL_PROXY="$PROXY_URL"
EOF
  fi
fi

# ---------------------------------------------------------------------------
# 1) apt packages — base toolchain + dev essentials
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive

# 国内镜像源：默认阿里云，可用 APT_MIRROR 覆盖（需以 /ubuntu/ 结尾，如
# APT_MIRROR=https://mirrors.ustc.edu.cn/ubuntu/）。仅对 Ubuntu 生效、幂等
# （当前已是该镜像则跳过）。解决国内直连 archive.ubuntu.com 跨境链路不稳、
# `apt update` 卡在 "Waiting for headers" 的问题。
# 选阿里云而非清华 TUNA：TUNA 对走代理的请求返回 403（x-tuna-mirror-id
# neomirrors 反代理），在「必须走 Clash 代理」的网络下装不上包；阿里云对
# 代理访问宽容（走 7890 仍 200）。
if [[ -r /etc/os-release ]] && grep -q '^ID=ubuntu$' /etc/os-release; then
  APT_MIRROR="${APT_MIRROR:-https://mirrors.aliyun.com/ubuntu/}"
  CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null)}")"
  APT_SOURCES="/etc/apt/sources.list.d/ubuntu.sources"        # Ubuntu 24.04+ deb822
  [[ -f "$APT_SOURCES" ]] || APT_SOURCES="/etc/apt/sources.list"  # 旧版 one-line
  if grep -qF "$APT_MIRROR" "$APT_SOURCES" 2>/dev/null; then
    log "apt 已使用镜像源 $APT_MIRROR — 跳过换源"
  else
    log "切换 apt 源到国内镜像: $APT_MIRROR ($CODENAME)"
    sudo cp "$APT_SOURCES" "$APT_SOURCES.bak"
    if [[ "$APT_SOURCES" == *.sources ]]; then
      sudo tee "$APT_SOURCES" >/dev/null <<EOF
Types: deb
URIs: ${APT_MIRROR}
Suites: ${CODENAME} ${CODENAME}-updates ${CODENAME}-backports
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: ${APT_MIRROR}
Suites: ${CODENAME}-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
    else
      sudo tee "$APT_SOURCES" >/dev/null <<EOF
deb ${APT_MIRROR} ${CODENAME} main universe restricted multiverse
deb ${APT_MIRROR} ${CODENAME}-updates main universe restricted multiverse
deb ${APT_MIRROR} ${CODENAME}-backports main universe restricted multiverse
deb ${APT_MIRROR} ${CODENAME}-security main universe restricted multiverse
EOF
    fi
  fi
fi

# apt 走 7890 代理（Clash 混合端口）：本机网络「直连 IPv4 全断」（连 baidu
# 都超时），只能走代理出网。国内镜像换阿里云后走代理仍 200，无需 DIRECT
# 例外（直连不通，加 DIRECT 反而下载超时）。无条件覆盖，清掉可能残留的
# per-host DIRECT 配置。
if (exec 3<>/dev/tcp/127.0.0.1/7890) 2>/dev/null; then
  exec 3>&- 3<&- 2>/dev/null || true
  APT_PROXY_CONF="/etc/apt/apt.conf.d/01proxy"
  log "配置 apt 走 7890 代理"
  sudo tee "$APT_PROXY_CONF" >/dev/null <<'EOF'
Acquire::http::Proxy "http://127.0.0.1:7890";
Acquire::https::Proxy "http://127.0.0.1:7890";
EOF
fi

log "Updating apt and installing base packages"
sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq
APT_PKGS=(
  zsh fzf ripgrep fd-find bat neovim cmake curl git
  build-essential pkg-config libssl-dev fastfetch tmux mosh
  libfontconfig1-dev libfreetype6-dev libharfbuzz-dev
  libxcb1-dev libxcb-render0-dev libxcb-shape0-dev libxcb-xfixes0-dev
  unzip ca-certificates gnupg
  nodejs npm
  jq ffmpeg
)
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${APT_PKGS[@]}"
(( IS_WSL )) && sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wslu 2>/dev/null || true

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
  sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wezterm || warn "  wezterm install failed"
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
  sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq code || warn "  VS Code install failed"
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
  sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gh || warn "  gh install failed"
fi

# cloudflared — Cloudflare Tunnel client (内网穿透). Use Cloudflare's apt repo
# so we get current builds and auto-updates; distro repos don't ship it.
if ! command -v cloudflared >/dev/null 2>&1; then
  log "Installing cloudflared via official apt repo"
  sudo install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
    | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
  # Cloudflare 的 cloudflared 仓库不分发行版代号，统一用固定 `any`（dists/any/Release）。
  # 不能写 VERSION_CODENAME（如 Ubuntu 26.04 的 `resolute`）——那个目录不存在会 404。
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
    | sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
  sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cloudflared || warn "  cloudflared install failed"
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
# rustup 偶发安装不完整：component 标记已装但 std 的 .rlib 实际缺失，
# 会导致后续 cargo install 全部报 can't find crate for std。
if ! compgen -G "$HOME/.rustup/toolchains/"*/lib/rustlib/*/lib/libstd-*.rlib >/dev/null; then
  warn "rust-std missing/corrupt — reinstalling stable toolchain"
  rustup toolchain uninstall stable 2>/dev/null || true
  rustup toolchain install stable --profile default
  rustup component add clippy rustfmt 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 3) Cargo tools (dotter, cargo-update, vivid, eza, bottom, bat)
#    coreutils is provided by the base system on Linux, so we skip it.
# ---------------------------------------------------------------------------
log "Installing Cargo tools"
# crate:binary 对 —— 部分 crate 产出的二进制名与 crate 名不同
# （bottom -> btm, cargo-update -> cargo-install-update, yazi-fm -> yazi, yazi-cli -> ya）。
CARGO_TOOLS=(
  "dotter:dotter"
  "cargo-update:cargo-install-update"
  "cargo-make:cargo-make"
  "vivid:vivid"
  # eza 改用 apt 预编译二进制（见下方 apt fallback）：cargo 源码编译在 rustc 1.98+
  # 会因 palette 0.7.5 的 derive 宏报 `could not find lms/meta in crate`。
  "bottom:btm"
  "bat:bat"
  # yazi-fm / yazi-cli 改用官方 GitHub Release 预编译二进制（见下方 fallback）：
  # 同样受 palette 0.7.5 影响，且 apt 无包。
  "abtop:abtop"
  "silicon:silicon"
  "ast-grep:ast-grep"
)
if ! command -v cargo >/dev/null 2>&1; then
  warn "cargo not on PATH — skipping Cargo tools (run 'source \$HOME/.cargo/env' or re-install rustup)"
else
  for entry in "${CARGO_TOOLS[@]}"; do
    crate="${entry%%:*}"
    bin="${entry##*:}"
    if command -v "$bin" >/dev/null 2>&1; then
      log "  $crate already installed ($bin on PATH)"
      continue
    fi
    # 捕获完整输出到变量：不依赖临时文件/重定向，失败时总能 tail 到真实报错
    # （如缺 cc/gcc 的 ToolNotFound，或 cargo 本身 command not found）。
    if install_log="$(cargo install "$crate" 2>&1)"; then
      # Verify binary landed — cargo may exit 0 but still fail to link.
      bin_path="$HOME/.cargo/bin/$bin"
      if [[ -x "$bin_path" ]]; then
        log "  -> $bin_path"
      else
        warn "  $crate: cargo reported OK but $bin_path not found — build log tail:"
        printf '%s\n' "$install_log" | tail -n 40 >&2
      fi
    else
      warn "  failed: $crate — build log tail:"
      if [[ -n "$install_log" ]]; then
        printf '%s\n' "$install_log" | tail -n 80 >&2
      else
        warn "  (no build output captured)"
      fi
    fi
  done
fi

# eza — cargo 源码编译与 rustc 1.98+ 不兼容（palette 0.7.5 的 derive 宏），改用 apt
# 预编译二进制。Ubuntu universe 的 eza（0.23.x）已足够新，支持别名里用到的
# --sort=modified / --group-directories-first / --icons 等 flag。
if ! command -v eza >/dev/null 2>&1; then
  log "Installing eza via apt (cargo build broken: palette 0.7.5 vs rustc 1.98+)"
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq eza \
    || warn "  eza install failed (apt unavailable?)"
fi

# yazi（yazi-fm → yazi / yazi-cli → ya）— cargo 源码编译同样受 palette 0.7.5 影响，
# 且 apt 无包，改用官方 GitHub Release 的预编译二进制（含 yazi 与 ya），放入 ~/.local/bin。
if ! command -v yazi >/dev/null 2>&1 || ! command -v ya >/dev/null 2>&1; then
  YAZI_ARCH="$(uname -m)"
  if [[ "$YAZI_ARCH" == x86_64 || "$YAZI_ARCH" == aarch64 ]]; then
    log "Installing yazi via official GitHub Release (cargo build broken: palette 0.7.5)"
    mkdir -p "$HOME/.local/bin"
    YAZI_TMP="$(mktemp -d)"
    if curl -fsSL "https://github.com/sxyazi/yazi/releases/latest/download/yazi-${YAZI_ARCH}-unknown-linux-gnu.zip" \
           -o "$YAZI_TMP/yazi.zip" \
       && unzip -q -o "$YAZI_TMP/yazi.zip" -d "$YAZI_TMP" \
       && install -m 0755 "$YAZI_TMP/yazi-${YAZI_ARCH}-unknown-linux-gnu/yazi" "$HOME/.local/bin/yazi" \
       && install -m 0755 "$YAZI_TMP/yazi-${YAZI_ARCH}-unknown-linux-gnu/ya"    "$HOME/.local/bin/ya"; then
      log "  -> yazi + ya -> $HOME/.local/bin"
    else
      warn "  yazi install failed (download / extract error)"
    fi
    rm -rf "$YAZI_TMP"
  else
    warn "  unsupported arch ($YAZI_ARCH) — skipping yazi"
  fi
fi

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
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq golang-go
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
if [[ ! -f "$ZSH/oh-my-zsh.sh" ]]; then
  log "Installing Oh My Zsh into $ZSH"
  # 目录存在但缺 oh-my-zsh.sh = 历史遗留的空壳（clone 中途失败）。install.sh 遇到已存在的
  # 非 git 仓库目录不会重装，所以先清掉（custom 里的插件稍后由下面的 clone_plugin 重建）。
  [[ -d "$ZSH" ]] && rm -rf "$ZSH"
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
# 8b) Grok Build
# ---------------------------------------------------------------------------
if ! command -v grok >/dev/null 2>&1; then
  log "Installing Grok Build"
  curl -fsSL https://x.ai/cli/install.sh | bash || warn "  Grok Build install failed"
else
  log "Grok Build already installed"
fi

# ---------------------------------------------------------------------------
# 8c) Global npm tools (hostc — Cloudflare-Workers edge tunnel CLI)
# ---------------------------------------------------------------------------
if command -v npm >/dev/null 2>&1; then
  # npm 全局安装需要 sudo（apt/nodesource node 的 prefix 是 /usr/local，root 所有）；
  # sudo 默认 env_reset 会清掉代理，而本机直连不通，用 --preserve-env 显式带上代理。
  npm_global() {
    sudo --preserve-env=http_proxy,https_proxy,HTTP_PROXY,HTTPS_PROXY,no_proxy,NO_PROXY \
      npm install -g "$@"
  }
  if ! command -v hostc >/dev/null 2>&1; then
    log "Installing hostc (edge tunnel CLI) via npm"
    npm_global hostc || warn "  hostc install failed"
  fi
  if ! command -v claude-mem >/dev/null 2>&1; then
    log "Installing claude-mem via npm"
    npm_global claude-mem || warn "  claude-mem install failed"
  fi
  if ! command -v agent-browser >/dev/null 2>&1; then
    log "Installing agent-browser (browser automation for AI agents) via npm"
    npm_global agent-browser || warn "  agent-browser install failed"
  fi
  # One-time Chromium download for agent-browser (idempotent — skips if already present)
  if command -v agent-browser >/dev/null 2>&1; then
    log "agent-browser: downloading Chromium (one-time)"
    agent-browser install 2>/dev/null || warn "  agent-browser install (Chromium) failed"
  fi
  # puppeteer — 浏览器自动化库（自带 Chromium）。--ignore-scripts 跳过 postinstall 的
  # Chromium 下载：storage.googleapis.com 走 Clash 代理返回 403，~160MB 会一直重试卡死；
  # 且上面装的 agent-browser 已带 Chromium，这份重复。
  if [ ! -d "$(npm root -g 2>/dev/null)/puppeteer" ]; then
    log "Installing puppeteer (browser automation) via npm"
    npm_global puppeteer --ignore-scripts || warn "  puppeteer install failed"
  else
    log "puppeteer already installed"
  fi

  # AI coding CLIs (Claude Code / Codex / OpenCode / DeepSeek Harness / Pi)
  if ! cmd_exists_local claude; then
    log "Installing Claude Code CLI (@anthropic-ai/claude-code)"
    npm_global @anthropic-ai/claude-code || warn "  claude-code install failed"
  fi
  if ! cmd_exists_local codex; then
    log "Installing Codex CLI (@openai/codex)"
    npm_global @openai/codex || warn "  codex install failed"
  fi
  if ! cmd_exists_local opencode; then
    log "Installing OpenCode CLI (opencode-ai)"
    npm_global opencode-ai || warn "  opencode install failed"
  fi
  # DeepSeek Harness — official DeepSeek native agent framework. bin: `dsh`,
  # profile/state under ${DSH_HOME:-~/.dsh}/profiles. Node ^22.19 || >=24.
  if ! cmd_exists_local dsh; then
    log "Installing DeepSeek Harness CLI (@deepseek-ai/dsh)"
    npm_global @deepseek-ai/dsh || warn "  dsh (DeepSeek Harness) install failed (requires Node.js >= 22.19)"
  fi
  # Pi — earendil-works coding agent CLI (unified LLM API, agent loop, TUI). bin: `pi`.
  # Skills are loaded from ~/.pi/agent/skills/ and ~/.agents/skills/.
  if ! cmd_exists_local pi; then
    log "Installing Pi coding agent CLI (@earendil-works/pi-coding-agent)"
    npm_global @earendil-works/pi-coding-agent || warn "  pi install failed"
  fi

  # Register upstash/context7 as an MCP server for Claude Code & Codex.
  # Idempotent: `mcp add` errors if already registered, which we swallow.
  if cmd_exists_local claude; then
    log "Registering context7 MCP for Claude Code (idempotent)"
    claude mcp add context7 -s user -- npx -y @upstash/context7-mcp 2>/dev/null \
      || log "  context7 MCP already registered for claude (or registration failed — see 'claude mcp list')"
  fi
  if cmd_exists_local codex; then
    log "Registering context7 MCP for Codex (idempotent)"
    codex mcp add context7 -- npx -y @upstash/context7-mcp 2>/dev/null \
      || log "  context7 MCP already registered for codex (or registration failed — see 'codex mcp list')"
  fi

  # Register chrome-devtools MCP (local stdio via npx) for Claude Code & Codex.
  # Drives a real Chrome via the DevTools Protocol; idempotent — `mcp add`
  # errors if already registered, which we swallow.
  if cmd_exists_local claude; then
    log "Registering chrome-devtools MCP for Claude Code (idempotent)"
    claude mcp add chrome-devtools -s user -- npx -y chrome-devtools-mcp@latest 2>/dev/null \
      || log "  chrome-devtools MCP already registered for claude (or registration failed — see 'claude mcp list')"
  fi
  if cmd_exists_local codex; then
    log "Registering chrome-devtools MCP for Codex (idempotent)"
    codex mcp add chrome-devtools -- npx -y chrome-devtools-mcp@latest 2>/dev/null \
      || log "  chrome-devtools MCP already registered for codex (or registration failed — see 'codex mcp list')"
  fi

  # Register zcaceres/fetch-mcp (local stdio via npx, package `mcp-fetch-server`)
  # for Claude Code & Codex. Fetches web content as HTML/markdown/text/JSON.
  # Idempotent — `mcp add` errors if already registered, which we swallow.
  if cmd_exists_local claude; then
    log "Registering fetch MCP for Claude Code (idempotent)"
    claude mcp add fetch -s user -- npx -y mcp-fetch-server 2>/dev/null \
      || log "  fetch MCP already registered for claude (or registration failed — see 'claude mcp list')"
  fi
  if cmd_exists_local codex; then
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
  if cmd_exists_local claude; then
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
  if cmd_exists_local codex; then
    log "Registering github MCP for Codex (remote HTTP; run 'codex mcp login github' to OAuth)"
    codex mcp add github --url "$GH_MCP_URL" 2>/dev/null \
      || log "  github MCP already registered for codex (or registration failed — see 'codex mcp list')"
  fi
  # opencode: merge an `mcp.github` (remote) entry into its JSON
  # config idempotently.
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
    CDT_LOCAL_JSON='{"chrome-devtools":{"type":"local","command":["npx","-y","chrome-devtools-mcp@latest"],"enabled":true}}'
    FETCH_LOCAL_JSON='{"fetch":{"type":"local","command":["npx","-y","mcp-fetch-server"],"enabled":true}}'
    CTX7_LOCAL_JSON='{"context7":{"type":"local","command":["npx","-y","@upstash/context7-mcp"],"enabled":true}}'
    if cmd_exists_local opencode; then
      log "Registering github + chrome-devtools + fetch + context7 MCP for opencode (~/.config/opencode/opencode.json)"
      register_json_mcp "$HOME/.config/opencode/opencode.json" "$GH_REMOTE_JSON"
      register_json_mcp "$HOME/.config/opencode/opencode.json" "$CDT_LOCAL_JSON"
      register_json_mcp "$HOME/.config/opencode/opencode.json" "$FETCH_LOCAL_JSON"
      register_json_mcp "$HOME/.config/opencode/opencode.json" "$CTX7_LOCAL_JSON"
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
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq corepack 2>/dev/null \
    || (command -v npm >/dev/null 2>&1 && sudo npm install -g corepack 2>/dev/null) \
    || warn "  corepack install failed (apt + npm both unable)"
fi
if command -v corepack >/dev/null 2>&1; then
  log "Enabling pnpm via corepack"
  sudo corepack enable 2>/dev/null || warn "  corepack enable failed"
  sudo --preserve-env=http_proxy,https_proxy,HTTP_PROXY,HTTPS_PROXY \
    corepack prepare pnpm@latest --activate 2>/dev/null || warn "  corepack prepare pnpm failed"
else
  warn "corepack still not on PATH -- skipping pnpm activation"
fi

# ---------------------------------------------------------------------------
# 8d) Yunxing plugin (raptoravis/yunxing)
#     Claude Code — marketplace name "yunxing" (derived from
#     .claude-plugin/marketplace.json), plugin selector "yunxing@yunxing".
#     Also redundantly declared in common/claude/settings.json (enabledPlugins)
#     for fresh dotter-only setups.
#     Codex — marketplace name "yunxing", plugin selector "yunxing@yunxing"
#     (derived from .codex-plugin/plugin.json).
#     OpenCode — native plugin module via git URL.
# ---------------------------------------------------------------------------
# Claude Code — `claude plugin` CLI (declarative settings.json is the fallback).
if cmd_exists_local claude; then
  log "Installing yunxing Claude Code plugin (marketplace: yunxing)"
  claude plugin marketplace add raptoravis/yunxing >/dev/null 2>&1 \
    || warn "  claude marketplace add failed (may already be registered)"
  claude plugin install yunxing@yunxing >/dev/null 2>&1 \
    || warn "  claude plugin install failed (may already be enabled)"
else
  warn "claude CLI not on PATH -- falling back to settings.json declaration (re-run after claude is installed)"
fi

if cmd_exists_local codex; then
  log "Installing yunxing Codex plugin (marketplace: yunxing)"
  codex plugin marketplace add raptoravis/yunxing >/dev/null 2>&1 \
    || warn "  codex marketplace add failed"
  codex plugin add yunxing@yunxing >/dev/null 2>&1 \
    || warn "  codex plugin add failed"
else
  warn "codex CLI not on PATH -- skipping Codex plugin install (re-run after codex is installed)"
fi

# OpenCode — native plugin module (one-step; no marketplace concept).
if cmd_exists_local opencode; then
  log "Installing yunxing OpenCode plugin"
  opencode plugin --force -g 'yunxing@git+https://github.com/raptoravis/yunxing.git' >/dev/null 2>&1 \
    || warn "  opencode plugin install failed"
else
  warn "opencode CLI not on PATH -- skipping OpenCode plugin install (re-run after opencode is installed)"
fi

# dsh — DeepSeek Harness bundle (package.json dsh.bundle → cordis.patch.yml).
if cmd_exists_local dsh; then
  log "Installing yunxing dsh bundle"
  dsh plugin --profile web add github:raptoravis/yunxing >/dev/null 2>&1 \
    || warn "  dsh plugin add failed (may already be installed)"
else
  warn "dsh CLI not on PATH -- skipping dsh yunxing bundle (re-run after dsh is installed)"
fi

# Grok Build — grok CLI plugin marketplace (reads yunxing's .grok-plugin/marketplace.json).
if cmd_exists_local grok; then
  log "Installing yunxing Grok plugin (marketplace: yunxing)"
  grok plugin marketplace add raptoravis/yunxing >/dev/null 2>&1 \
    || warn "  grok marketplace add failed (may already be registered)"
  grok plugin install yunxing --trust >/dev/null 2>&1 \
    || warn "  grok plugin install failed"
else
  warn "grok CLI not on PATH -- skipping Grok plugin install (re-run after grok is installed)"
fi

# Cursor — no scriptable plugin install; symlink promoted skills into ~/.cursor/skills/.
YUNXING_SRC="${XDG_DATA_HOME:-$HOME/.local/share}/yunxing"
if command -v git >/dev/null 2>&1; then
  if [ -d "$YUNXING_SRC/.git" ]; then
    log "Updating yunxing checkout for Cursor skills"
    git -C "$YUNXING_SRC" pull --ff-only --quiet 2>/dev/null \
      || warn "  yunxing pull failed"
  else
    log "Cloning yunxing for Cursor skills"
    mkdir -p "$(dirname "$YUNXING_SRC")"
    git clone --depth=1 --quiet https://github.com/raptoravis/yunxing.git "$YUNXING_SRC" \
      || warn "  yunxing clone failed"
  fi
  if [ -d "$YUNXING_SRC/skills" ]; then
    log "Linking yunxing skills into ~/.cursor/skills"
    mkdir -p "$HOME/.cursor/skills"
    for skill in "$YUNXING_SRC"/skills/engineering/*/SKILL.md "$YUNXING_SRC"/skills/productivity/*/SKILL.md; do
      [ -e "$skill" ] || continue
      name="$(basename "$(dirname "$skill")")"
      ln -sfn "$(dirname "$skill")" "$HOME/.cursor/skills/$name"
    done
  fi
else
  warn "git not on PATH -- skipping Cursor yunxing skills"
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
