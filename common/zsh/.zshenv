export EDITOR="nvim"
export VISUAL="nvim"
export XDG_CONFIG_HOME="$HOME/.config"
export ZSH="${ZDOTDIR:-$XDG_CONFIG_HOME/zsh}/ohmyzsh"

# Telemetry Opt-Out (wide spread list, might not have tools installed)
# Last updated: 2026-02-11

export DO_NOT_TRACK=1
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export HOMEBREW_NO_ANALYTICS=1
export NEXT_TELEMETRY_DISABLED=1
export ASTRO_TELEMETRY_DISABLED=1
export NUXT_TELEMETRY_DISABLED=1
export CHECKPOINT_DISABLE=1
export GATSBY_TELEMETRY_DISABLED=1
export TURBO_TELEMETRY_DISABLED=1
export STORYBOOK_DISABLE_TELEMETRY=1
export STORYBOOK_ENABLE_CRASH_REPORTS=0
export WRANGLER_SEND_METRICS=false
export SAM_CLI_TELEMETRY=0
export AZURE_CORE_COLLECT_TELEMETRY=0
export FUNCTIONS_CORE_TOOLS_TELEMETRY_OPTOUT=1
export PP_TOOLS_TELEMETRY_OPTOUT=1
export DOTNET_HTTPREPL_TELEMETRY_OPTOUT=1
export ALGOLIA_CLI_TELEMETRY=0
export GOTELEMETRY=off
export AUTOMATEDLAB_TELEMETRY_OPTOUT=1
export POWERSHELL_TELEMETRY_OPTOUT=1

# ---------------------------------------------------------------------------
# Proxy (Clash / mihomo default port 7890)
# Auto-enabled only while 7890 actually answers. macOS runs Clash on this Mac;
# under WSL, 127.0.0.1 is the Windows host's loopback only with mirrored
# networking (.wslconfig: networkingMode=mirrored). Under NAT — or with Clash
# stopped — a forced 127.0.0.1:7890 proxy makes curl/go/npm/git fail with
# "connection refused", so fall back to direct and drop any stale value this
# file exported earlier. proxy_on / proxy_off (autoloaded) toggle at runtime.
# ---------------------------------------------------------------------------
export PROXY_URL="http://127.0.0.1:7890"
if zmodload zsh/net/tcp 2>/dev/null && ztcp 127.0.0.1 7890 2>/dev/null; then
  ztcp -c $REPLY 2>/dev/null
  export http_proxy="$PROXY_URL"
  export https_proxy="$PROXY_URL"
  export all_proxy="$PROXY_URL"
  export HTTP_PROXY="$PROXY_URL"
  export HTTPS_PROXY="$PROXY_URL"
  export ALL_PROXY="$PROXY_URL"

  # global-agent (native-module installers like onnxruntime-node / node-llama-cpp)
  # reads its own GLOBAL_AGENT_* namespace, not http(s)_proxy; without these the
  # download bypasses the proxy and hangs under TUN mode.
  export GLOBAL_AGENT_HTTP_PROXY="$PROXY_URL"
  export GLOBAL_AGENT_HTTPS_PROXY="$PROXY_URL"
  export GLOBAL_AGENT_NO_PROXY="localhost,127.0.0.1"
  # Node's built-in fetch (undici) ignores http(s)_proxy by default; this makes it honor them.
  export NODE_USE_ENV_PROXY=1
else
  # Drop only the value this file sets; leave a proxy the caller configured.
  for _v in http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY \
            GLOBAL_AGENT_HTTP_PROXY GLOBAL_AGENT_HTTPS_PROXY; do
    case "${(P)_v:-}" in *127.0.0.1:7890*) unset "$_v" ;; esac
  done
  unset _v GLOBAL_AGENT_NO_PROXY NODE_USE_ENV_PROXY
fi