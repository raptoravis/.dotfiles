# Source environment variables and platform detection
source "$ZDOTDIR/.zshenv"
source "$ZDOTDIR/platform.zsh"

# Only set PATH once
if [ -z "$PATH_SET" ]; then
  if (( IS_MAC )); then
    export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin:$HOME/.local/bin:/usr/local/go/bin:$PATH"
  else
    export PATH="$HOME/.cargo/bin:$HOME/.local/bin:/usr/local/go/bin:$PATH"
    # Linuxbrew (if installed)
    [[ -d /home/linuxbrew/.linuxbrew ]] && export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"
  fi
  export GOPATH="$HOME/go"
  export PATH="$PATH:$GOPATH/bin"
  export PATH_SET=1
fi


# fpath setup (before compinit)
if (( IS_MAC )); then
  fpath+=("$(brew --prefix)/share/zsh/site-functions")
fi
_uv_comp_dir="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/completions"
mkdir -p "$_uv_comp_dir"
[[ ! -f "$_uv_comp_dir/_uv" ]] && uv generate-shell-completion zsh > "$_uv_comp_dir/_uv" 2>/dev/null
[[ ! -f "$_uv_comp_dir/_uvx" ]] && uvx --generate-shell-completion zsh > "$_uv_comp_dir/_uvx" 2>/dev/null
fpath=("$_uv_comp_dir" $fpath)

autoload -Uz compinit && compinit

# Homebrew
if (( IS_MAC )); then
  export HOMEBREW_NO_ENV_HINTS=1
  export HOMEBREW_NO_AUTO_UPDATE=1
  export HOMEBREW_NO_INSTALL_CLEANUP=1
fi

# Oh My Zsh
plugins=(
  git
  fzf-tab
  zsh-autosuggestions
  zsh-syntax-highlighting
  zsh-completions
)
source $ZSH/oh-my-zsh.sh

# fzf
[ -f "$HOME/.fzf.zsh" ] && source <(fzf --zsh)
export FZF_CTRL_T_OPTS="
  --walker-skip .git,node_modules,target
  --preview 'bat -n --color=always {}'
  --bind 'ctrl-/:change-preview-window(down|hidden|)'"
export FZF_DEFAULT_COMMAND='rg --hidden -l ""' # Include hidden files

# Load aliases
source "$HOME/.config/zsh/aliases.zsh"

# Autoload functions
fpath=($HOME/.config/zsh/functions $fpath)
for func_file in $HOME/.config/zsh/functions/*; do
  [[ -f "$func_file" ]] && autoload -Uz ${func_file:t}
done

# starship
(( $+commands[starship] )) && eval "$(starship init zsh)"

# OSC 9;9 — report CWD to Windows Terminal for duplicate tab/pane & session restore.
# Only runs inside Windows Terminal (WT_SESSION is set by WT) with wslpath available.
if [[ -n "$WT_SESSION" ]] && (( $+commands[wslpath] )); then
    _report_cwd_to_wt() {
        local win_path
        win_path=$(wslpath -w "$PWD" 2>/dev/null) || return
        print -Pn "\e]9;9;$win_path\e\\"
    }
    precmd_functions+=(_report_cwd_to_wt)
fi

# mise (runtime version manager)
eval "$(mise activate zsh)"

# herdr auto-start (interactive shell, not nested, not in editor terminals) —
# replaces the old tmux auto-start. Bare `herdr` attaches to the running
# session or starts one (server + attach, like tmux's attach-or-new).
# `HERDR_ENV=1` is set inside herdr terminals, so skip re-attaching when
# nested; also skip inside a manual tmux session (`moshi` still uses tmux).
# Runs in every terminal by default — herdr is the default session manager,
# and WezTerm (where installed) is just a plain terminal.
if (( $+commands[herdr] )) \
   && [[ -o interactive ]] \
   && [[ -z "$HERDR_ENV" ]] \
   && [[ -z "$TMUX" ]] \
   && [[ -z "$VSCODE_INJECTION" ]] \
   && [[ -z "$INSIDE_EMACS" ]] \
   && [[ "$TERM_PROGRAM" != "vscode" ]] \
   && [[ -z "$NO_HERDR" ]]; then
  # Attach to the running session if exists, else start one. No `exec` —
  # detaching (ctrl+b q) returns to the shell.
  herdr
fi
