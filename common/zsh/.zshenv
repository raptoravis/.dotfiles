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
# macOS: Clash runs on this Mac. WSL2: works because .wslconfig has
# networkingMode=mirrored, so 127.0.0.1 reaches the Windows host's loopback.
# Comment out the exports below to disable auto-enable; use proxy_on /
# proxy_off (autoloaded functions) to toggle at runtime.
# ---------------------------------------------------------------------------
export PROXY_URL="http://127.0.0.1:7890"
export http_proxy="$PROXY_URL"
export https_proxy="$PROXY_URL"
export all_proxy="$PROXY_URL"
export HTTP_PROXY="$PROXY_URL"
export HTTPS_PROXY="$PROXY_URL"
export ALL_PROXY="$PROXY_URL"