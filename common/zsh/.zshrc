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

# mise (runtime version manager)
eval "$(mise activate zsh)"

# tmux auto-start (interactive shell, not nested, not in editor terminals).
# Skipped inside WezTerm on every platform: WezTerm has its own tabs/panes,
# a shared `main` session would make every WezTerm tab attach to the same
# shell, and tmux doesn't forward clipboard image bytes (breaks Claude Code
# image paste). tmux still auto-starts under Moshi / plain SSH / other
# terminals. Set FORCE_TMUX=1 to opt back in inside WezTerm.
if (( $+commands[tmux] )) \
   && [[ -o interactive ]] \
   && [[ -z "$TMUX" ]] \
   && [[ -z "$VSCODE_INJECTION" ]] \
   && [[ -z "$INSIDE_EMACS" ]] \
   && [[ "$TERM_PROGRAM" != "vscode" ]] \
   && [[ -z "$NO_TMUX" ]] \
   && { [[ -z "$WEZTERM_PANE" && "$TERM_PROGRAM" != "WezTerm" ]] || [[ -n "$FORCE_TMUX" ]]; }; then
  # Attach to "main" if exists, else create. No `exec` — exit returns to shell.
  tmux attach -t main 2>/dev/null || tmux new -s main
fi