#!/usr/bin/env bash
# install-linux.sh — Linux / WSL dotfiles & dev environment bootstrap
#
# Usage:
#   ./install-linux.sh                       # full silent install
#   DOTFILES_DIR=~/code/dotfiles ./install-linux.sh
#   SET_HOSTNAME=my-wsl ./install-linux.sh   # optional WSL hostname
#
# Idempotent: safe to re-run. Mirrors `cargo make init` for Linux/WSL.

set -uo pipefail

UNINSTALL_AGENTS=0
for arg in "$@"; do
  case "$arg" in
    --uninstallagents) UNINSTALL_AGENTS=1 ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--uninstallagents]
  --uninstallagents  Uninstall all AI agent CLIs (Claude Code, Codex, OpenCode, Grok,
                     DeepSeek Harness, omp) and remove their config dirs.
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
    for pkg in "@anthropic-ai/claude-code" "@openai/codex" "@opencode/cli" "@xai-official/grok" "@deepseek-ai/dsh" "@deepseek-harness-tui/dsh-tui"; do
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
    "$HOME/.omp"
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

  # omp binary (curl installer → ~/.local/bin); config dir removed above
  if [[ -f "$HOME/.local/bin/omp" || -L "$HOME/.local/bin/omp" ]]; then
    log "  rm -f $HOME/.local/bin/omp"
    rm -f "$HOME/.local/bin/omp"
  fi

  log "Agent uninstall complete."
  exit 0
fi

DOTFILES_DIR="${DOTFILES_DIR:-$HOME/.dotfiles}"
ZSH_CUSTOM_DIR="${ZSH:-$HOME/.config/zsh/ohmyzsh}"
IS_WSL=0
grep -qi 'microsoft\|wsl' /proc/version 2>/dev/null && IS_WSL=1

# WSL engine release (e.g. 3.0.1.0), read from the host binary through interop.
# The distro kernel stays tagged `-microsoft-standard-WSL2` even on a WSL 3
# engine, and `wsl --status` only reports the per-distro version (2), so the
# kernel string cannot tell the engine release. Interop returns the host
# console's UTF-16 text, hence the NUL strip; empty on pre-store WSL, which has
# no `wsl.exe --version`.
WSL_RELEASE=""
WSL_EXE=""
if (( IS_WSL )); then
  # Resolve by name first, then fall back to the host mount: with
  # `[interop] appendWindowsPath=false`, or when the caller pastes a sanitised
  # PATH, the Windows dirs never reach PATH and interop still works by path.
  WSL_EXE="$(command -v wsl.exe 2>/dev/null || true)"
  if [[ -z "$WSL_EXE" ]]; then
    for _cand in /mnt/[a-z]/Windows/System32/wsl.exe \
                 /mnt/[a-z]/windows/System32/wsl.exe; do
      [[ -f "$_cand" ]] && { WSL_EXE="$_cand"; break; }
    done
    unset _cand
  fi
  if [[ -n "$WSL_EXE" ]]; then
    WSL_RELEASE="$("$WSL_EXE" --version 2>/dev/null | tr -d '\0\r' \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
  fi
fi

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
  err "Linux/WSL only. Detected: $(uname -s)"
  exit 1
fi
if (( IS_WSL )); then
  if [[ -n "$WSL_RELEASE" ]]; then
    log "WSL detected (engine $WSL_RELEASE)"
  else
    log "WSL detected (engine version unavailable; kernel $(uname -r))"
  fi
else
  log "Pure Linux detected"
fi

# ---------------------------------------------------------------------------
# 0) 网络代理 — 探测 Clash 7890：通就设全局代理（curl/git/wget/npm/go 自动走
#    代理），不通就清掉继承来的 7890 代理变量直连。代理只在「Clash 在本机监听」
#    时有意义：macOS / 纯 Linux 与 Clash 同机；WSL 下 127.0.0.1 只有在 mirrored
#    网络模式（.wslconfig: networkingMode=mirrored）里才是 Windows 宿主回环，
#    NAT 模式下它是 WSL 自己 —— 此时继承来的 7890 代理会让 curl/go/npm/git 全部
#    connection refused（直连反而正常）。
# ---------------------------------------------------------------------------
PROXY_URL="http://127.0.0.1:7890"
proxy_port_reachable() { (exec 3<>/dev/tcp/127.0.0.1/7890) 2>/dev/null; }
# 只清我们自己设的那份（指向 127.0.0.1:7890），不动调用方自带的代理。
proxy_env_clear() {
  local _v
  for _v in http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY \
            GLOBAL_AGENT_HTTP_PROXY GLOBAL_AGENT_HTTPS_PROXY; do
    case "${!_v:-}" in *127.0.0.1:7890*) unset "$_v" ;; esac
  done
  case "${NODE_USE_ENV_PROXY:-}" in 1) unset NODE_USE_ENV_PROXY ;; esac
}
if proxy_port_reachable; then
  export http_proxy="$PROXY_URL"
  export https_proxy="$PROXY_URL"
  export HTTP_PROXY="$PROXY_URL"
  export HTTPS_PROXY="$PROXY_URL"
  export all_proxy="$PROXY_URL"
  export ALL_PROXY="$PROXY_URL"
  export no_proxy=localhost,127.0.0.1
  export NO_PROXY=localhost,127.0.0.1
  # global-agent（原生模块安装器如 onnxruntime-node）只认 GLOBAL_AGENT_*，不设则绕过代理直连、TUN 下卡死
  export GLOBAL_AGENT_HTTP_PROXY="$PROXY_URL"
  export GLOBAL_AGENT_HTTPS_PROXY="$PROXY_URL"
  export GLOBAL_AGENT_NO_PROXY=localhost,127.0.0.1
  # Node 内置 fetch(undici) 默认不认 http(s)_proxy；NODE_USE_ENV_PROXY=1 让它走代理（zg 下模型依赖这个）
  export NODE_USE_ENV_PROXY=1
  log "检测到 7890 代理 — 设置全局 http(s)_proxy"
else
  proxy_env_clear
  if (( IS_WSL )); then
    warn "未检测到 7890 代理（WSL 网络模式: $(wslinfo --networking-mode 2>/dev/null || echo unknown)，127.0.0.1 不是 Windows 宿主）— 已清除继承的代理变量，直连出网"
    warn "  需要走代理时：Windows 侧 Clash 打开 Allow LAN 后改连宿主 IP，或让 .wslconfig 的 networkingMode=mirrored 生效（wsl --shutdown 后重开）"
  else
    warn "未检测到 7890 代理（Clash 未运行？）— 已清除继承的代理变量，直连出网"
  fi
fi

# 持久化到 bash 交互 shell（WSL 默认 login shell 是 bash）。zsh 的代理已在
# common/zsh/.zshenv 持久化，bash 的 ~/.bashrc 没有 —— 补上「探测后启用」的
# 块，让 gh/curl/git 等 CLI 在 bash 里同样自动适配，Clash 没开时不残留失效代理。
# 幂等：带标记的新块已存在则跳过；旧静态 exports 版（mirrors 注释开头）会先被
# 剥掉再写入，避免机器上遗留的死代理继续生效。
bashrc_file="$HOME/.bashrc"
if [[ -f "$bashrc_file" ]]; then
  if grep -qF '# >>> dotfiles proxy >>>' "$bashrc_file" 2>/dev/null; then
    log "~/.bashrc 代理块已是最新 — 跳过"
  else
    if grep -qF 'mirrors common/zsh/.zshenv' "$bashrc_file" 2>/dev/null; then
      log "替换 ~/.bashrc 里的旧代理块（静态 exports）"
      bashrc_tmp="$(mktemp)"
      awk '/mirrors common\/zsh\/\.zshenv/ {skip=1}
           skip && /^export NODE_USE_ENV_PROXY=1$/ {skip=0; next}
           !skip' "$bashrc_file" > "$bashrc_tmp" \
        && cat "$bashrc_tmp" > "$bashrc_file"
      rm -f "$bashrc_tmp"
    fi
    log "写入 ~/.bashrc 代理块（探测后启用）"
    cat >> "$bashrc_file" <<'EOF'

# >>> dotfiles proxy >>>
# Clash / mihomo 7890 — 仅在端口真的应答时启用；否则清掉继承的失效值直连。
# mirrors common/zsh/.zshenv。WSL 下需 mirrored 网络模式 127.0.0.1 才等于宿主回环。
if (exec 3<>/dev/tcp/127.0.0.1/7890) 2>/dev/null; then
  exec 3>&- 3<&- 2>/dev/null || true
  export PROXY_URL="http://127.0.0.1:7890"
  export http_proxy="$PROXY_URL"
  export https_proxy="$PROXY_URL"
  export all_proxy="$PROXY_URL"
  export HTTP_PROXY="$PROXY_URL"
  export HTTPS_PROXY="$PROXY_URL"
  export ALL_PROXY="$PROXY_URL"
  export GLOBAL_AGENT_HTTP_PROXY="$PROXY_URL"
  export GLOBAL_AGENT_HTTPS_PROXY="$PROXY_URL"
  export GLOBAL_AGENT_NO_PROXY="localhost,127.0.0.1"
  export NODE_USE_ENV_PROXY=1
else
  for _v in http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY GLOBAL_AGENT_HTTP_PROXY GLOBAL_AGENT_HTTPS_PROXY; do
    case "${!_v:-}" in *127.0.0.1:7890*) unset "$_v" ;; esac
  done
  unset _v GLOBAL_AGENT_NO_PROXY NODE_USE_ENV_PROXY
fi
# <<< dotfiles proxy <<<
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

# apt 走 7890 代理（Clash 混合端口）：只在 7890 真的应答时才写，否则把历史
# 写入的 apt 代理清掉 —— 失效的 apt 代理会让 `apt update` 连阿里云镜像也
# connection refused（直连能通）。已含目标配置则跳过，避免每次重跑都触发 sudo。
APT_PROXY_CONF="/etc/apt/apt.conf.d/01proxy"
if proxy_port_reachable; then
  if [[ -f "$APT_PROXY_CONF" ]] && grep -qF 'http://127.0.0.1:7890' "$APT_PROXY_CONF" 2>/dev/null; then
    log "apt 已走 7890 代理 — 跳过"
  else
    log "配置 apt 走 7890 代理"
    sudo tee "$APT_PROXY_CONF" >/dev/null <<'EOF'
Acquire::http::Proxy "http://127.0.0.1:7890";
Acquire::https::Proxy "http://127.0.0.1:7890";
EOF
  fi
elif [[ -f "$APT_PROXY_CONF" ]] && grep -qF 'http://127.0.0.1:7890' "$APT_PROXY_CONF" 2>/dev/null; then
  log "清除失效的 apt 代理配置 ($APT_PROXY_CONF)"
  sudo rm -f "$APT_PROXY_CONF"
fi

APT_PKGS=(
  zsh fzf ripgrep fd-find bat neovim cmake curl git
  build-essential pkg-config libssl-dev fastfetch tmux mosh
  libfontconfig1-dev libfreetype6-dev libharfbuzz-dev
  libxcb1-dev libxcb-render0-dev libxcb-shape0-dev libxcb-xfixes0-dev
  unzip ca-certificates gnupg
  jq ffmpeg
)
# 只对「尚未安装」的包走 apt（dpkg -s 判断）；全部就绪则完全跳过，避免每次
# 重跑都触发 sudo。apt-get install 本就不会升级已装包，语义等价。
MISSING_APT=()
for pkg in "${APT_PKGS[@]}"; do
  dpkg -s "$pkg" >/dev/null 2>&1 || MISSING_APT+=("$pkg")
done
if (( ${#MISSING_APT[@]} > 0 )); then
  log "Updating apt and installing missing base packages"
  sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${MISSING_APT[@]}"
else
  log "apt base packages already installed — skipping (no sudo)"
fi
# wslu 仅 WSL 需要，单独判断并保留原容错（装不上不致命）。
if (( IS_WSL )) && ! dpkg -s wslu >/dev/null 2>&1; then
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wslu 2>/dev/null || true
fi

# Node.js 22 via NodeSource — 不用 Node 24：其自带 npm 11 默认拦 install 脚本
# （allowScripts），会静默跳过 zg/node-llama-cpp/onnxruntime 等原生二进制下载，
# 装出「能用但缺原生组件」的坏状态；Node 22 自带 npm 10，无此拦截，与其它
# 能正常装 zg 的 WSL 机器一致。dsh/zg 需 >=22.19，22.x 满足。
# 注意：仅 Linux 锁 22；macOS(brew node)/Windows(choco 24.18.0) 仍走 24，暂不动。
# NodeSource 的 nodejs 包自带 npm，故上方 APT_PKGS 已移除 `nodejs`/`npm`。
# 幂等：node 主版本 == 22 即跳过；已装 24 会显式降级到 22。
NODE_MAJOR=22
# WSL interop 会把 Windows 的 node 追加进 PATH（见 cmd_exists_local 注释），而后面
# npm_global 需要 Linux 本地 node；用 local 判定，避免被 Windows 侧 node 骗过跳过安装。
node_major=0
if cmd_exists_local node; then
  node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
fi
if (( node_major == NODE_MAJOR )); then
  log "Node.js $(node --version) already ${NODE_MAJOR}.x — skipping NodeSource"
else
  log "Installing Node.js ${NODE_MAJOR}.x via NodeSource (from node $(node --version 2>/dev/null || echo none))"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" \
    | sudo --preserve-env=http_proxy,https_proxy,HTTP_PROXY,HTTPS_PROXY,no_proxy,NO_PROXY bash - \
    || warn "  nodesource setup failed (falling through to version check)"
  # 已装更高主版本（如 24）时 apt 不会自动降级，显式 remove 再 install 覆盖。
  sudo env DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq nodejs 2>/dev/null || true
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs \
    || warn "  nodejs install failed"
fi
if command -v node >/dev/null 2>&1; then
  log "node: $(node --version 2>/dev/null || echo '?')"
else
  warn "node not on PATH after install"
fi
if command -v npm >/dev/null 2>&1; then
  log "npm:  $(npm --version 2>/dev/null || echo '?')"
else
  warn "npm not on PATH after install"
fi

# npm 全局 prefix 指到 ~/.local（NodeSource 包的 prefix 是 /usr，root 所有），
# 免 sudo 装全局包，bin 落到 ~/.local/bin（已在 PATH 前部，先于 Windows node）。
# 幂等：重跑只覆盖同值。
if command -v npm >/dev/null 2>&1; then
  npm config set prefix "$HOME/.local" || warn "  npm prefix config failed"
fi

# Tailscale — private mesh network for reaching services (e.g. the PostgreSQL host).
if ! command -v tailscale >/dev/null 2>&1; then
  log "Installing Tailscale"
  curl -fsSL https://tailscale.com/install.sh | sh || warn "  tailscale install failed"
fi

if command -v tailscale >/dev/null 2>&1; then
  # Start the daemon (systemd). On WSL without systemd this is skipped — the
  # Windows host's Tailscale covers the network instead.
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet tailscaled 2>/dev/null; then
      log "  tailscaled already running"
    else
      sudo systemctl enable --now tailscaled 2>/dev/null \
        || warn "  tailscaled start failed (WSL without systemd? use the Windows host's Tailscale)"
    fi
  fi
  if tailscale status >/dev/null 2>&1; then
    log "  Tailscale already up"
  else
    log "  Logging in to Tailscale — complete browser auth when prompted"
    tailscale up || warn "  tailscale up failed (run it manually)"
  fi
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

# VS Code — only on bare Linux (WSL uses the Windows host's VS Code via code
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
  log "  WSL detected — VS Code available via Windows host (code .)"
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

# tree-sitter CLI — required by nvim-treesitter (main) to compile parsers.
# apt's `tree-sitter-cli` is too old (<0.26.1), so use the official release binary.
if ! command -v tree-sitter >/dev/null 2>&1; then
  TS_ARCH="$(uname -m)"
  case "$TS_ARCH" in
    x86_64) TS_ASSET="tree-sitter-linux-x64.gz" ;;
    aarch64) TS_ASSET="tree-sitter-linux-arm64.gz" ;;
    *) TS_ASSET="" ;;
  esac
  if [[ -n "$TS_ASSET" ]]; then
    log "Installing tree-sitter CLI via official GitHub Release (apt version too old)"
    mkdir -p "$HOME/.local/bin"
    TS_TMP="$(mktemp -d)"
    if curl -fsSL "https://github.com/tree-sitter/tree-sitter/releases/latest/download/$TS_ASSET" \
           -o "$TS_TMP/tree-sitter.gz" \
       && gunzip -c "$TS_TMP/tree-sitter.gz" > "$TS_TMP/tree-sitter" \
       && install -m 0755 "$TS_TMP/tree-sitter" "$HOME/.local/bin/tree-sitter"; then
      log "  -> tree-sitter -> $HOME/.local/bin"
    else
      warn "  tree-sitter install failed (download / extract error)"
    fi
    rm -rf "$TS_TMP"
  else
    warn "  unsupported arch ($TS_ARCH) — skipping tree-sitter"
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
# 8b2) herdr — coding-agent runtime (background daemon that keeps terminals
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
# 8b3) omp — coding agent with the IDE wired in (native Rust core). bin: `omp`,
#      config under ~/.omp. Supersedes the retired Pi coding agent.
# ---------------------------------------------------------------------------
# 安装器是幂等的：binary 模式命中 latest/${TARGET}?channel=stable，source 模式
# `bun install -g` 拉 latest。未装过 → 安装；已装过 → 同样跑安装器更新到最新。
if command -v omp >/dev/null 2>&1; then
  log "Updating omp (coding agent) to latest"
else
  log "Installing omp (coding agent)"
fi
curl -fsSL https://omp.sh/install | sh || warn "  omp install failed"
# omp installs to ~/.local/bin (overridable via PI_INSTALL_DIR)
[[ -d "$HOME/.local/bin" ]] && export PATH="$HOME/.local/bin:$PATH"

# ---------------------------------------------------------------------------
# 8c) Global npm tools (hostc — Cloudflare-Workers edge tunnel CLI)
# ---------------------------------------------------------------------------
if command -v npm >/dev/null 2>&1; then
  # 全局包装到 ~/.local（上方已 `npm config set prefix`），免 sudo；代理 env 天然透传。
  npm_global() {
    npm install -g "$@"
  }
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
  # minor/major jump are treated as unsafe for other CLIs.
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
  # 安装/升级一个 npm 全局 CLI。`npm install -g` 不看已装版本、每次都拉 latest 重装，
  # 已是最新也白跑（dsh 一次 30s+）。这里先比 installed vs latest：未安装或远端有
  # 新版才真正 install，已是最新则跳过。$1=pkg $2=显示名，其余参数透传给 npm install。
  npm_install_if_stale() {
    local pkg="$1" label="$2" inst latest
    shift 2
    inst=$(npm list -g --depth=0 "$pkg" 2>/dev/null | sed -nE 's/.*@([^@]+)$/\1/p' | head -1)
    if [[ -z "$inst" ]]; then
      log "Installing $label ($pkg)"
      npm_global "$pkg" "$@" || warn "  $label install failed"
      return
    fi
    latest=$(npm view "$pkg" version 2>/dev/null)
    if [[ -n "$latest" ]] && semver_lt "$inst" "$latest"; then
      if [[ "$pkg" == @deepseek-ai/dsh || "$pkg" == @deepseek-harness-tui/dsh-tui ]] || semver_safe_upgrade "$inst" "$latest"; then
        log "Upgrading $label ($pkg): $inst -> $latest"
        npm_global "$pkg" "$@" || warn "  $label upgrade failed"
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

  # AI coding CLIs (Claude Code / Codex / OpenCode / Grok / DeepSeek Harness)
  # 只在未安装或远端有新版时才 npm install；已是最新则跳过，重跑脚本不再白升级。
  npm_install_if_stale @anthropic-ai/claude-code "Claude Code CLI"
  npm_install_if_stale @openai/codex "Codex CLI"
  # oh-my-codex — Yeachan-Heo multi-agent orchestration layer for Codex. bin: `omx`.
  npm_install_if_stale oh-my-codex "oh-my-codex (omx CLI)"
  npm_install_if_stale @opencode/cli "OpenCode CLI"
  # d3c8e51 之前 Grok CLI 由 x.ai 的 curl 脚本安装，它在 ~/.local/bin 留下一条
  # grok -> ~/.grok/bin/grok 软链——而 npm 全局 prefix 正是 ~/.local，bin 目录
  # 就是同一个 ~/.local/bin。npm 只接管自己创建的 bin 链接，遇到这条外部软链会
  # EEXIST: file already exists 直接失败（`npm ls -g` 又看不到该包，于是每次都
  # 判定「未安装」→ 每次重跑都重装、每次都失败）。装前清掉任何不归 npm 管的
  # grok shim；随后的 postinstall 会重建 ~/.grok/bin/grok-<ver> 和正确的 bin 链接。
  _grok_bin="$(npm prefix -g 2>/dev/null)/bin/grok"
  if [[ -e "$_grok_bin" || -L "$_grok_bin" ]]; then
    _grok_target="$(readlink -f "$_grok_bin" 2>/dev/null)"
    if [[ -z "$_grok_target" || "$_grok_target" != "$(npm root -g 2>/dev/null)"/* ]]; then
      log "  清理非 npm 安装遗留的 grok shim ($_grok_bin${_grok_target:+ -> $_grok_target})"
      rm -f "$_grok_bin"
    fi
  fi
  unset _grok_bin _grok_target
  npm_install_if_stale @xai-official/grok "Grok CLI"
  # DeepSeek Harness — official DeepSeek native agent framework. bin: `dsh`,
  # profile/state under ${DSH_HOME:-~/.dsh}/profiles. Node ^22.19 || >=24.
  npm_install_if_stale @deepseek-ai/dsh "DeepSeek Harness CLI"
  # dsh-tui — Claude Code 风格交互式 TUI 入口（dsh 前端）。bin: `dsh-tui`。
  npm_install_if_stale @deepseek-harness-tui/dsh-tui "DeepSeek Harness TUI"
  # zg — zvec-grep: local-first search layer (ripgrep + BM25 + vector search)
  # for humans and agents. bin: `zg`. Requires Node.js >= 22.
  # onnxruntime-node postinstall 默认去 GitHub 下 CUDA(EP) 二进制（WSL 无 GPU 用不上）、
  # node-llama-cpp 默认下预编译 llama.cpp，两者经 Clash 代理都易卡死/超时；skip 跳过。
  # zg 核心搜索走 @zvec/bindings-linux-x64（Rust 绑定），不受影响。
  NODE_LLAMA_CPP_SKIP_DOWNLOAD=true ONNXRUNTIME_NODE_INSTALL_CUDA=skip \
    npm_install_if_stale @zvec/zvec-grep "zg (zvec-grep)" || warn "  zg install/upgrade failed (requires Node.js >= 22)"
  # npm 半途失败会留下悬空的 ~/.local/bin/zg，command -v 静默回退到 Windows 侧 /mnt/c
  # 的 zg，直到 `zg index` 才崩（missing @zvec/bindings-linux-x64）。装完立刻跑一次，
  # 失败就地暴露，而不是留个坏链接等后续才炸。
  if ! zg --version >/dev/null 2>&1; then
    warn "  zg unusable after install (-> $(command -v zg 2>/dev/null || echo 'not found')) — likely partial npm install or missing @zvec/bindings-linux-x64"
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
    # zg (zvec-grep) — WSL wires a local HTTP daemon on 7998 (the Windows-side
    # daemon holds 7999 for Cursor); pure Linux uses the stdio bootstrap.
    if (( IS_WSL )); then
      ZVEC_LOCAL_JSON='{"zvec_grep":{"type":"remote","url":"http://127.0.0.1:7998/mcp","timeout":600000,"oauth":false}}'
    else
      ZVEC_LOCAL_JSON='{"zvec_grep":{"type":"local","command":["zg","server","--stdio"],"timeout":600000}}'
    fi
    if cmd_exists_local opencode; then
      log "Registering github + chrome-devtools + fetch + context7 + zvec_grep MCP for opencode (~/.config/opencode/opencode.json)"
      register_json_mcp "$HOME/.config/opencode/opencode.json" "$GH_REMOTE_JSON"
      register_json_mcp "$HOME/.config/opencode/opencode.json" "$CDT_LOCAL_JSON"
      register_json_mcp "$HOME/.config/opencode/opencode.json" "$FETCH_LOCAL_JSON"
      register_json_mcp "$HOME/.config/opencode/opencode.json" "$CTX7_LOCAL_JSON"
      cmd_exists_local zg && register_json_mcp "$HOME/.config/opencode/opencode.json" "$ZVEC_LOCAL_JSON"
    fi
  fi
else
  warn "npm not on PATH -- skipping npm-based CLI installs (apt nodejs may be too old; need Node 18+)"
fi

# ---------------------------------------------------------------------------
# 8c) pnpm — 独立二进制（dsh 为 profile 装插件时调用 `pnpm`）。
#     不用 corepack：apt 的 node-corepack (0.24.0) 跑不了 pnpm >= 10
#     （pnpm.cjs 顶层 dynamic import 抛 ERR_VM_DYNAMIC_IMPORT_CALLBACK_MISSING）。
#     旧机器上 corepack 的 pnpm shim 可能已在 PATH 却是坏的，故按「能否真正
#     执行」判断（pnpm --version），而不是 command -v。
# ---------------------------------------------------------------------------
if command -v npm >/dev/null 2>&1; then
  if ! pnpm --version >/dev/null 2>&1; then
    log "Installing standalone pnpm via npm"
    npm install -g pnpm || warn "  pnpm install failed"
  else
    log "pnpm: $(pnpm --version 2>/dev/null)"
  fi
else
  warn "npm not on PATH -- skipping pnpm install"
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

if cmd_exists_local codex; then
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
if cmd_exists_local opencode; then
  # WSL mirrored networking: a Windows-side opencode background server holds
  # 127.0.0.1:49374 (the v2 binary's hardcoded default service port), so WSL's
  # opencode must pick a different port or every `opencode` — including the
  # `plugin add/update` below, which spawns the service — times out binding it.
  # Pure Linux and macOS keep the default. Idempotent; `set` only rewrites port.
  if (( IS_WSL )); then
    opencode service set port 49375 >/dev/null 2>&1 \
      || warn "  opencode service set port 49375 failed"
  fi
  # 清理 opencode v1 遗留的 `plugin` 单数键（pin 到 commit hash 的残留）。v2 用
  # `plugins` 复数键，`opencode plugin remove` 只认复数键，旧 pin 条目会留成坏记录
  # （该 commit 的 yunxing 缺 default export），让 `plugin check`/`update` 遍历时失败。
  OC_CFG="$HOME/.config/opencode/opencode.json"
  if [ -f "$OC_CFG" ] && command -v node >/dev/null 2>&1; then
    OC_CFG="$OC_CFG" node -e '
      const fs=require("fs");
      let c; try{ c=JSON.parse(fs.readFileSync(process.env.OC_CFG,"utf8")); }catch(e){ process.exit(0); }
      if(!c || typeof c!=="object") process.exit(0);
      let changed=false;
      if(Object.prototype.hasOwnProperty.call(c,"plugin")){ delete c.plugin; changed=true; }
      if(Array.isArray(c.plugins)){
        const next=[...new Set(c.plugins.filter(s=>!(typeof s==="string"&&s.startsWith("yunxing")&&s.includes("#"))))];
        if(next.length!==c.plugins.length){ c.plugins=next; changed=true; }
      }
      if(changed){ fs.writeFileSync(process.env.OC_CFG, JSON.stringify(c,null,2)+"\n"); console.error("==> cleaned legacy/pinned opencode plugin entries"); }
    ' || warn "  failed to clean legacy opencode plugin entries"
  fi
  log "Installing yunxing OpenCode plugin"
  # Unpinned spec: `add` is idempotent only for an exact match — a pinned
  # `#hash` entry from a prior run is treated as a different plugin and would
  # accumulate duplicates, so the cleanup above strips those first. Upgrades go
  # through `plugin update` with no target (updates all outdated plugins), which
  # never fails with "not configured" on a spec mismatch.
  # Capture stderr so a transient failure (e.g. git fetch/network) is visible
  # instead of a bare warning — mirrors the codex section below.
  oc_err="$(opencode plugin add "yunxing@git+https://github.com/raptoravis/yunxing.git" 2>&1)"
  if [ $? -ne 0 ]; then
    if [ -n "$oc_err" ]; then
      warn "  opencode plugin add failed: $oc_err"
    else
      warn "  opencode plugin add failed"
    fi
  fi
  oc_err="$(opencode plugin update 2>&1)"
  if [ $? -ne 0 ]; then
    if [ -n "$oc_err" ]; then
      warn "  opencode plugin update failed: $oc_err"
    else
      warn "  opencode plugin update failed"
    fi
  fi
else
  warn "opencode CLI not on PATH -- skipping OpenCode plugin install (re-run after opencode is installed)"
fi

# oh-my-claudecode + oh-my-codex (Yeachan-Heo)
#   oh-my-claudecode — Claude Code multi-agent plugin. Marketplace name "omc"
#   (from .claude-plugin/marketplace.json), plugin selector
#   "oh-my-claudecode@omc"; same install shape as yunxing.
#   oh-my-codex — Codex orchestration layer. The npm package (installed above)
#   ships the `omx` CLI; `omx setup --scope user` wires the plugin + hooks into
#   the user's codex config (idempotent; re-run keeps it current).
# Claude Code — oh-my-claudecode plugin.
if cmd_exists_local claude; then
  log "Installing oh-my-claudecode Claude Code plugin (marketplace: omc)"
  claude plugin marketplace add Yeachan-Heo/oh-my-claudecode >/dev/null 2>&1 \
    || warn "  claude marketplace add oh-my-claudecode failed (may already be registered)"
  # `install` is idempotent and won't pull newer code; refresh + `update` to keep current.
  claude plugin marketplace update omc >/dev/null 2>&1 \
    || warn "  claude marketplace update omc failed"
  if claude plugin list 2>/dev/null | grep -q 'oh-my-claudecode@omc'; then
    claude plugin update oh-my-claudecode@omc >/dev/null 2>&1 \
      || warn "  claude plugin update oh-my-claudecode failed"
  else
    claude plugin install oh-my-claudecode@omc >/dev/null 2>&1 \
      || warn "  claude plugin install oh-my-claudecode failed (may already be enabled)"
  fi
else
  warn "claude CLI not on PATH -- skipping oh-my-claudecode (re-run after claude is installed)"
fi

# Wire zg into supported AI agents via MCP (managed zvec_grep entry + search
# guidance + tool approval + start local server). Idempotent — re-runs update
# only the ZVEC_GREP_START/END managed blocks; --force absorbs any stray
# unmanaged zvec_grep table. dsh / omp / grok are not supported zg targets and
# are skipped. opencode is wired manually above.
#
# MUST run after the codex MCP/plugin registration above and before `omx setup`
# below: `codex mcp add` re-serializes config.toml and drops trailing comment
# markers, so zg's block (appended at EOF) would otherwise clobber the OMX hook
# trust END marker and make `omx setup` refuse to reconcile its trust state.
# Running zg here lets `omx setup` regenerate its block and re-serialize cleanly,
# absorbing zg's markers.
if cmd_exists_local zg; then
  zg_targets=(cursor)  # GUI IDE, no CLI to detect — always wire
  for t in claude codex; do
    cmd_exists_local "$t" && zg_targets+=("$t")
  done
  zg_args=(--force)
  for t in "${zg_targets[@]}"; do zg_args+=(--target "$t"); done
  log "Wiring zg MCP into AI agents: ${zg_targets[*]}"
  if (( IS_WSL )); then
    # WSL mirrored networking: the Windows-side zg daemon holds 127.0.0.1:7999
    # (serving Cursor) and cannot see WSL paths, so stdio would collide on 7999.
    # Run a separate WSL daemon on 7998 and wire agents over HTTP instead.
    zg_port=7998
    if ! zg_on_out=$(zg server on --listen "127.0.0.1:$zg_port" 2>&1); then
      printf '%s\n' "$zg_on_out" >&2
      warn "  zg daemon (127.0.0.1:$zg_port) failed to start"
    fi
    if zg_out=$(ZVEC_GREP_SERVER_URL="http://127.0.0.1:$zg_port/mcp" \
        zg install "${zg_args[@]}" --mcp-transport http --yes 2>&1); then
      printf '%s\n' "$zg_out"
    else
      printf '%s\n' "$zg_out" >&2
      warn "  zg install failed (see zg output above)"
    fi
    # 交互式 CLI 默认连 7999（穿透到 Windows daemon、看不到 WSL 路径 → ROOT_NOT_FOUND），
    # 把 client.serverUrl 持久化到 ~/.zvec-grep/config.json，指向 WSL daemon(7998)。幂等 merge。
    ZVEC_GREP_SERVER_URL="http://127.0.0.1:$zg_port/mcp" node -e '
      const fs = require("fs");
      const p = require("path").join(process.env.HOME, ".zvec-grep", "config.json");
      let cfg = { version: 1 };
      try { cfg = JSON.parse(fs.readFileSync(p, "utf8")); } catch {}
      cfg.client = { ...(cfg.client || {}), serverUrl: process.env.ZVEC_GREP_SERVER_URL };
      fs.mkdirSync(require("path").dirname(p), { recursive: true });
      fs.writeFileSync(p, JSON.stringify(cfg, null, 2) + "\n");
    '
  else
    if zg_out=$(zg install "${zg_args[@]}" --yes 2>&1); then
      printf '%s\n' "$zg_out"
    else
      case "$zg_out" in
        *EADDRINUSE*)
          log "  zg daemon already running — daemon start skipped";;
        *)
          printf '%s\n' "$zg_out" >&2
          warn "  zg install failed (see zg output above)";;
      esac
    fi
  fi
fi

# Codex — oh-my-codex. `omx setup --scope user` wires the plugin + hooks into the
# user's codex config (idempotent; re-run keeps it current).
#
# stdin + stdout are detached from the TTY because `omx setup` only prompts when
# BOTH are terminals (persisted-preference review, legacy vs plugin skill
# delivery). Detached, it reuses the choices recorded in ./.omx/setup-scope.json,
# so an existing install is kept as-is instead of blocking on a prompt that the
# redirection below would hide.
if cmd_exists_local codex && cmd_exists_local omx; then
  log "Wiring oh-my-codex into Codex (omx setup --scope user; keeping recorded choices)"
  # Capture stderr so a real failure (e.g. a corrupted OMX hook trust state in
  # config.toml) is visible instead of a bare warning.
  omx_err="$(omx setup --scope user </dev/null 2>&1)"
  if [ $? -ne 0 ]; then
    if [ -n "$omx_err" ]; then
      warn "  omx setup --scope user failed: $omx_err"
    else
      warn "  omx setup --scope user failed"
    fi
  fi
else
  warn "codex/omx not on PATH -- skipping oh-my-codex setup (re-run after oh-my-codex is installed)"
fi

# dsh — DeepSeek Harness plugins (package.json dsh.bundle → cordis.patch.yml).
# dshmarket: in-harness plugin marketplace; dsh-context: context insight panel;
# dsh-browser-use: Browser Use Cloud bridge (removed; no 0.2.0-rc-compatible release);
# yunxing: local skill bundle via GitHub shorthand; modlens: vision/tools bundle
# (image → structured JSON evidence); dsh-agent-teams: multi-agent team
# collaboration tools + web tree monitor (@nanmicoder/dsh-agent-teams);
# dsh-engineering-skill-pack: 28 engineering/stack/UI/writing skills in one bundle.
# dsh-skills-manager: install/manage skills (global or workspace scope); dsh-mnemon:
# composable view-based context/memory; dsh-image-gen: image generation (Gemini/OpenAI/
# Seedream/DashScope/ComfyUI); dsh-im: unified IM bridge (session/command/notify/approval);
# dsh-bot: headless agent runner (cron/webhooks/queues, run logs, retries, CI exit codes).
# The filesystem skill provider (@deepseek-ai/dsh-skill-filesystem) that reads
# ~/.dsh/skills is already built into dsh via @deepseek-ai/dsh-base, so it is
# not added here (its npm `latest` is a stale 0.0.1-rc.3 library, not a bundle).
# Each bundle is installed if absent and updated to latest if present.
#
# Profiles install per directory, so a profile booted without these skill bundles
# composes no yunxing/modlens skill provider and its sessions list no yunxing or
# modlens skills. The bundles therefore go into every CLI profile already on disk — the
# earlier `web`-only loop left the TUI profile, the everyday entry point, skill-less.
# Re-run after creating a new profile. The web/UI plugins stay on `web`.
#
# dsh-tui is the exception: its profile is bootstrapped lazily by the launcher on
# first `dst` run, so it isn't on disk when this loop scans. Pre-install the skill
# bundles into it explicitly, or the TUI boots skill-less until the next re-run.
# Canonical name under which a spec is recorded in package.json, used to detect an
# installed plugin. `github:user/repo` installs under the bare repo name; scoped
# (`@scope/name`) and bare npm specs keep their own name.
dsh_plugin_name() {
  case "$1" in
    github:*) printf '%s' "${1##*/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Install a plugin if absent, otherwise update it to latest. `dsh plugin add`
# delegates to pnpm add — fine for registry specs, but git specs pin a commit and
# re-adding retains that lock, so present plugins always go through
# `dsh plugin update <name> --latest`.
dsh_plugin_install_or_update() {
  local profile="$1" spec="$2" name
  name="$(dsh_plugin_name "$spec")"
  if dsh plugin --profile "$profile" list 2>/dev/null | grep -qF "$name@"; then
    log "Updating dsh plugin: $spec (profile: $profile)"
    dsh plugin --profile "$profile" update "$name" --latest >/dev/null 2>&1 \
      || warn "  dsh plugin update $name failed on $profile"
  else
    log "Installing dsh plugin: $spec (profile: $profile)"
    dsh plugin --profile "$profile" add "$spec" >/dev/null 2>&1 \
      || warn "  dsh plugin add $spec failed on $profile"
  fi
}

if cmd_exists_local dsh; then
  # CLI profiles keep their own skill/tool bundles. The official Desktop app
  # has no Linux release; its reserved profile cannot be managed by npm dsh.
  dsh_bundles="github:raptoravis/yunxing @liustack/modlens @nanmicoder/dsh-agent-teams github:lcx9451/dsh-engineering-skill-pack dsh-skills-manager dsh-mnemon dsh-image-gen dsh-im dsh-bot"
  dsh_profiles_seen=0
  dsh_tui_covered=0
  for dsh_profile_dir in "${DSH_HOME:-$HOME/.dsh}"/profiles/*/; do
    [ -f "${dsh_profile_dir}package.json" ] || continue
    dsh_profile="$(basename "$dsh_profile_dir")"
    [ "$dsh_profile" = "desktop" ] && continue
    dsh_profiles_seen=$((dsh_profiles_seen + 1))
    [ "$dsh_profile" = "dsh-tui" ] && dsh_tui_covered=1
    for dsh_bundle in $dsh_bundles; do
      dsh_plugin_install_or_update "$dsh_profile" "$dsh_bundle"
    done
  done
  if [ "$dsh_profiles_seen" -eq 0 ]; then
    # Fresh machine: no profile on disk yet — the plugin manager creates `web` on demand.
    for dsh_bundle in $dsh_bundles; do
      dsh_plugin_install_or_update web "$dsh_bundle"
    done
  fi
  if [ "$dsh_tui_covered" -eq 0 ]; then
    for dsh_bundle in $dsh_bundles; do
      dsh_plugin_install_or_update dsh-tui "$dsh_bundle"
    done
  fi

  for plugin in dshmarket dsh-context; do
    dsh_plugin_install_or_update web "$plugin"
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
# guard with `grok plugin list`: installed → update, absent → install.
if cmd_exists_local grok; then
  if grok plugin list 2>/dev/null | grep -q 'yunxing'; then
    log "Updating yunxing Grok plugin"
    grok plugin update yunxing >/dev/null 2>&1 \
      || warn "  grok plugin update failed"
  else
    log "Installing yunxing Grok plugin (raptoravis/yunxing)"
    grok plugin install raptoravis/yunxing --trust >/dev/null 2>&1 \
      || warn "  grok plugin install failed"
  fi
else
  warn "grok CLI not on PATH -- skipping Grok plugin install (re-run after grok is installed)"
fi

# Cursor & omp — no scriptable plugin install; symlink promoted skills into
# ~/.cursor/skills/ and omp's global skills dir ~/.omp/agent/skills (one level
# deep). YUNXING_SRC is ensured above (shared with the Codex plugin version check).
if [ -d "$YUNXING_SRC/skills" ]; then
  log "Linking yunxing skills into ~/.cursor/skills and ~/.omp/agent/skills"
  mkdir -p "$HOME/.cursor/skills" "$HOME/.omp/agent/skills"
  for skill in "$YUNXING_SRC"/skills/engineering/*/SKILL.md "$YUNXING_SRC"/skills/productivity/*/SKILL.md; do
    [ -e "$skill" ] || continue
    name="$(basename "$(dirname "$skill")")"
    ln -sfn "$(dirname "$skill")" "$HOME/.cursor/skills/$name"
    ln -sfn "$(dirname "$skill")" "$HOME/.omp/agent/skills/$name"
  done
fi

# ---------------------------------------------------------------------------
# 8e) herdr agent skill — install the release-matched herdr SKILL.md into each
#     coding agent's global skills dir. `herdr --skill` prints the copy bundled
#     with the installed binary (no network, always matches the running version).
#     Written directly per-agent: grok isn't covered by the `npx skills` CLI.
# ---------------------------------------------------------------------------
if command -v herdr >/dev/null 2>&1; then
  log "Installing herdr skill into coding agents (claude/codex/grok/opencode/cursor/omp)"
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
  herdr_skill_dir "$HOME/.omp/agent/skills/herdr"
else
  warn "herdr CLI not on PATH -- skipping herdr agent skill (re-run after herdr is installed)"
fi

# ---------------------------------------------------------------------------
# 8e2) chinese-novelist skill (raptoravis/chinese-novelist-skill) — a plain
#      directory skill (SKILL.md + references/ + scripts/) installed into each
#      coding agent's global skills dir as a symlink to a shared checkout.
#      dsh reads ~/.dsh/skills via its filesystem skill provider (dsh-base).
# ---------------------------------------------------------------------------
CHINESE_NOVELIST_SRC="${XDG_DATA_HOME:-$HOME/.local/share}/chinese-novelist-skill"
if command -v git >/dev/null 2>&1; then
  if [ -d "$CHINESE_NOVELIST_SRC/.git" ]; then
    log "Updating chinese-novelist-skill checkout"
    if ! git -C "$CHINESE_NOVELIST_SRC" pull --ff-only --quiet 2>/dev/null; then
      warn "  chinese-novelist-skill pull failed — re-cloning"
      rm -rf "$CHINESE_NOVELIST_SRC"
    fi
  fi
  if [ ! -d "$CHINESE_NOVELIST_SRC/.git" ]; then
    log "Cloning chinese-novelist-skill into $CHINESE_NOVELIST_SRC"
    mkdir -p "$(dirname "$CHINESE_NOVELIST_SRC")"
    git clone --depth=1 --quiet https://github.com/raptoravis/chinese-novelist-skill.git "$CHINESE_NOVELIST_SRC" \
      || warn "  chinese-novelist-skill clone failed"
  fi
  if [ -f "$CHINESE_NOVELIST_SRC/SKILL.md" ]; then
    log "Linking chinese-novelist skill into coding agents (claude/codex/grok/dsh/opencode/cursor/omp)"
    for dest in \
      "$HOME/.claude/skills/chinese-novelist" \
      "${CODEX_HOME:-$HOME/.codex}/skills/chinese-novelist" \
      "$HOME/.grok/skills/chinese-novelist" \
      "${DSH_HOME:-$HOME/.dsh}/skills/chinese-novelist" \
      "$HOME/.config/opencode/skills/chinese-novelist" \
      "$HOME/.cursor/skills/chinese-novelist" \
      "$HOME/.omp/agent/skills/chinese-novelist"; do
      mkdir -p "$(dirname "$dest")"
      rm -rf "$dest"
      ln -sfn "$CHINESE_NOVELIST_SRC" "$dest"
    done
  else
    warn "  chinese-novelist-skill/SKILL.md missing — skipping agent links"
  fi
else
  warn "git not on PATH -- skipping chinese-novelist skill (re-run after git is installed)"
fi

# ---------------------------------------------------------------------------
# 8e3) taste-skill (Leonxlnx/taste-skill) — anti-slop frontend design skills
#      (design taste, image-to-code, image generation, redesign, output
#      discipline). Multi-skill repo: every skills/<folder>/SKILL.md is linked
#      one level deep into each coding agent's global skills dir, named after
#      the frontmatter `name:` — the upstream install name, which differs from
#      the folder (taste-skill -> design-taste-frontend, soft-skill ->
#      high-end-visual-design) — falling back to the folder name.
#      dsh reads ~/.dsh/skills through its filesystem skill provider
#      (@deepseek-ai/dsh-base); the dst (dsh-tui) profile bundles dsh-base too,
#      so a single link covers both.
# ---------------------------------------------------------------------------
TASTE_SKILL_SRC="${XDG_DATA_HOME:-$HOME/.local/share}/taste-skill"
if command -v git >/dev/null 2>&1; then
  if [ -d "$TASTE_SKILL_SRC/.git" ]; then
    log "Updating taste-skill checkout"
    if ! git -C "$TASTE_SKILL_SRC" pull --ff-only --quiet 2>/dev/null; then
      warn "  taste-skill pull failed — re-cloning"
      rm -rf "$TASTE_SKILL_SRC"
    fi
  fi
  if [ ! -d "$TASTE_SKILL_SRC/.git" ]; then
    log "Cloning taste-skill into $TASTE_SKILL_SRC"
    mkdir -p "$(dirname "$TASTE_SKILL_SRC")"
    git clone --depth=1 --quiet https://github.com/Leonxlnx/taste-skill.git "$TASTE_SKILL_SRC" \
      || warn "  taste-skill clone failed"
  fi
  taste_skill_dests=(
    "$HOME/.claude/skills"
    "${CODEX_HOME:-$HOME/.codex}/skills"
    "$HOME/.grok/skills"
    "${DSH_HOME:-$HOME/.dsh}/skills"
    "$HOME/.config/opencode/skills"
    "$HOME/.cursor/skills"
    "$HOME/.omp/agent/skills"
  )
  taste_skill_names=" "
  taste_skill_count=0
  for taste_skill_md in "$TASTE_SKILL_SRC"/skills/*/SKILL.md; do
    [ -e "$taste_skill_md" ] || continue
    taste_skill_dir="$(dirname "$taste_skill_md")"
    # Frontmatter `name:` is the upstream install name; fall back to the folder
    # name when it is missing or unusable as a path component.
    taste_skill_name="$(awk 'NR>1 && /^---[[:space:]]*$/ {exit} /^name:[[:space:]]*/ {sub(/^name:[[:space:]]*/, ""); print; exit}' "$taste_skill_md" | tr -d '\r"' | sed 's/[[:space:]]*$//')"
    case "$taste_skill_name" in
      ''|*[!A-Za-z0-9._-]*) taste_skill_name="$(basename "$taste_skill_dir")" ;;
    esac
    taste_skill_names="$taste_skill_names$taste_skill_name "
    for dest in "${taste_skill_dests[@]}"; do
      mkdir -p "$dest"
      rm -rf "$dest/$taste_skill_name"
      ln -sfn "$taste_skill_dir" "$dest/$taste_skill_name"
    done
    taste_skill_count=$((taste_skill_count + 1))
  done
  if [ "$taste_skill_count" -eq 0 ]; then
    warn "  taste-skill/skills/*/SKILL.md missing — skipping agent links"
  else
    log "Linked $taste_skill_count taste-skill skills into claude/codex/grok/dsh(dst)/opencode/cursor/omp"
    # Drop links left by an earlier run for a skill upstream no longer ships: a
    # removed/renamed skill would stay behind as a dangling symlink and the
    # agent would then list a skill it cannot read.
    for dest in "${taste_skill_dests[@]}"; do
      for dest_entry in "$dest"/*; do
        [ -L "$dest_entry" ] || continue
        case "$(readlink "$dest_entry" 2>/dev/null)" in
          "$TASTE_SKILL_SRC"/*) ;;
          *) continue ;;
        esac
        case "$taste_skill_names" in
          *" $(basename "$dest_entry") "*) ;;
          *) rm -f "$dest_entry"; log "  removed stale taste-skill link: ${dest_entry##*/}" ;;
        esac
      done
    done
  fi
else
  warn "git not on PATH -- skipping taste-skill (re-run after git is installed)"
fi

# ---------------------------------------------------------------------------
# 8f) Codex subagents (awesome-codex-subagents) — clone/update into $HOME and
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
# 9) WSL-only: deploy /etc/wsl.conf and (optionally) set hostname
# ---------------------------------------------------------------------------
if (( IS_WSL )); then
  WSL_CONF_SRC="$DOTFILES_DIR/windows/wsl/wsl.conf"
  if [[ -f "$WSL_CONF_SRC" ]]; then
    if [[ -f /etc/wsl.conf ]] && cmp -s "$WSL_CONF_SRC" /etc/wsl.conf; then
      log "wsl.conf already up to date — skipping"
    else
      log "Deploying $WSL_CONF_SRC -> /etc/wsl.conf"
      sudo cp "$WSL_CONF_SRC" /etc/wsl.conf
    fi
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
  # Proxy — set only while 127.0.0.1:7890 answers; clear a stale dotfiles value
  # otherwise (git honours http.proxy even when nothing listens → every fetch
  # fails with "Failed to connect ... via 127.0.0.1").
  if proxy_port_reachable; then
    set_git http.proxy  "$PROXY_URL"
    set_git https.proxy "$PROXY_URL"
  else
    for _k in http.proxy https.proxy; do
      case "$(git config --global --get "$_k" 2>/dev/null)" in
        *127.0.0.1:7890*) git config --global --unset "$_k" 2>/dev/null \
          && log "cleared git $_k (7890 proxy unreachable)";;
      esac
    done
    unset _k
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
  # --force: overwrite stray non-symlink targets (e.g. `zg install` writes
  # AGENTS.md as regular files before dotter runs) so symlinks always win.
  ( cd "$DOTFILES_DIR" && dotter -v --force ) || warn "dotter exited with errors"
else
  warn "dotter not on PATH — skipping symlinks. Open a new shell so \$HOME/.cargo/bin is loaded, then re-run."
fi

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
