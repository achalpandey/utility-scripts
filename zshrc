# If you come from bash you might have to change your $PATH.
# export PATH=$HOME/bin:$HOME/.local/bin:/usr/local/bin:$PATH

# Path to your Oh My Zsh installation.
export ZSH="$HOME/.oh-my-zsh"

# Set name of the theme to load --- if set to "random", it will
# load a random theme each time Oh My Zsh is loaded, in which case,
# to know which specific one was loaded, run: echo $RANDOM_THEME
# See https://github.com/ohmyzsh/ohmyzsh/wiki/Themes
ZSH_THEME="robbyrussell"

# Set list of themes to pick from when loading at random
# Setting this variable when ZSH_THEME=random will cause zsh to load
# a theme from this variable instead of looking in $ZSH/themes/
# If set to an empty array, this variable will have no effect.
# ZSH_THEME_RANDOM_CANDIDATES=( "robbyrussell" "agnoster" )

# Uncomment the following line to use case-sensitive completion.
# CASE_SENSITIVE="true"

# Uncomment the following line to use hyphen-insensitive completion.
# Case-sensitive completion must be off. _ and - will be interchangeable.
# HYPHEN_INSENSITIVE="true"

# Uncomment one of the following lines to change the auto-update behavior
# zstyle ':omz:update' mode disabled  # disable automatic updates
# zstyle ':omz:update' mode auto      # update automatically without asking
# zstyle ':omz:update' mode reminder  # just remind me to update when it's time

# Uncomment the following line to change how often to auto-update (in days).
# zstyle ':omz:update' frequency 13

# Uncomment the following line if pasting URLs and other text is messed up.
# DISABLE_MAGIC_FUNCTIONS="true"

# Uncomment the following line to disable colors in ls.
# DISABLE_LS_COLORS="true"

# Uncomment the following line to disable auto-setting terminal title.
# DISABLE_AUTO_TITLE="true"

# Uncomment the following line to enable command auto-correction.
# ENABLE_CORRECTION="true"

# Uncomment the following line to display red dots whilst waiting for completion.
# You can also set it to another string to have that shown instead of the default red dots.
# e.g. COMPLETION_WAITING_DOTS="%F{yellow}waiting...%f"
# Caution: this setting can cause issues with multiline prompts in zsh < 5.7.1 (see #5765)
# COMPLETION_WAITING_DOTS="true"

# Uncomment the following line if you want to disable marking untracked files
# under VCS as dirty. This makes repository status check for large repositories
# much, much faster.
# DISABLE_UNTRACKED_FILES_DIRTY="true"

# Uncomment the following line if you want to change the command execution time
# stamp shown in the history command output.
# You can set one of the optional three formats:
# "mm/dd/yyyy"|"dd.mm.yyyy"|"yyyy-mm-dd"
# or set a custom format using the strftime function format specifications,
# see 'man strftime' for details.
# HIST_STAMPS="mm/dd/yyyy"

# Would you like to use another custom folder than $ZSH/custom?
# ZSH_CUSTOM=/path/to/new-custom-folder

# Which plugins would you like to load?
# Standard plugins can be found in $ZSH/plugins/
# Custom plugins may be added to $ZSH_CUSTOM/plugins/
# Example format: plugins=(rails git textmate ruby lighthouse)
# Add wisely, as too many plugins slow down shell startup.
plugins=(git)

source $ZSH/oh-my-zsh.sh

# User configuration

# export MANPATH="/usr/local/man:$MANPATH"

# You may need to manually set your language environment
# export LANG=en_US.UTF-8

# Preferred editor for local and remote sessions
# if [[ -n $SSH_CONNECTION ]]; then
#   export EDITOR='vim'
# else
#   export EDITOR='nvim'
# fi

# Compilation flags
# export ARCHFLAGS="-arch $(uname -m)"

# Set personal aliases, overriding those provided by Oh My Zsh libs,
# plugins, and themes. Aliases can be placed here, though Oh My Zsh
# users are encouraged to define aliases within a top-level file in
# the $ZSH_CUSTOM folder, with .zsh extension. Examples:
# - $ZSH_CUSTOM/aliases.zsh
# - $ZSH_CUSTOM/macos.zsh
# For a full list of active aliases, run `alias`.
#
# Example aliases
# alias zshconfig="mate ~/.zshrc"
# alias ohmyzsh="mate ~/.oh-my-zsh"

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
export PATH="$HOME/.local/bin:$PATH"

# The next line updates PATH for the Google Cloud SDK.
if [ -f '/Users/achalpandey/google-cloud-sdk/path.zsh.inc' ]; then . '/Users/achalpandey/google-cloud-sdk/path.zsh.inc'; fi

# The next line enables shell command completion for gcloud.
if [ -f '/Users/achalpandey/google-cloud-sdk/completion.zsh.inc' ]; then . '/Users/achalpandey/google-cloud-sdk/completion.zsh.inc'; fi

# worktree.zsh — git worktree helpers for the ~/Sandbox multi-agent setup
# Enable by adding this line to ~/.zshrc:
#   source ~/Sandbox/worktree.zsh

# --- wt: jump between worktrees of the current repo --------------------------
# Uses fzf if installed; falls back to a numbered menu otherwise.
wt() {
  local -a trees
  trees=("${(@f)$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')}")
  trees=(${trees:#})  # drop empty elements
  if (( ${#trees} == 0 )); then
    echo "wt: not inside a git repo" >&2
    return 1
  fi
  local dst
  if command -v fzf >/dev/null 2>&1; then
    dst=$(printf '%s\n' "${trees[@]}" | fzf --height 40% --reverse) || return 0
  else
    local PS3="worktree> "
    select dst in "${trees[@]}"; do break; done
    [[ -n "$dst" ]] || return 0
  fi
  cd "$dst"
}

# --- wts: jump to any worktree in any Sandbox repo ----------------------------
wts() {
  local sandbox="${SANDBOX_DIR:-$HOME/Sandbox}" repo
  local -a trees
  for repo in "$sandbox"/*/main(N/); do
    trees+=("${(@f)$(git -C "$repo" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')}")
  done
  trees=(${trees:#})  # drop empty elements
  if (( ${#trees} == 0 )); then
    echo "wts: no worktrees found under $sandbox" >&2
    return 1
  fi
  local dst
  if command -v fzf >/dev/null 2>&1; then
    dst=$(printf '%s\n' "${trees[@]}" | fzf --height 40% --reverse) || return 0
  else
    local PS3="worktree> "
    select dst in "${trees[@]}"; do break; done
    [[ -n "$dst" ]] || return 0
  fi
  cd "$dst"
}

# --- prompt marker: show ⌂ <worktree-dir> when inside a linked worktree -------
git_worktree_marker() {
  local gd gcd
  gd=$(git rev-parse --git-dir 2>/dev/null) || return
  gcd=$(git rev-parse --git-common-dir 2>/dev/null)
  if [[ "$gd" != "$gcd" ]]; then
    echo "%F{yellow}⌂ $(basename "$(git rev-parse --show-toplevel)")%f"
  fi
}
setopt PROMPT_SUBST
RPROMPT='$(git_worktree_marker)'"${RPROMPT:+ $RPROMPT}"

# --- prompt path: git-root-relative when inside a repo, basename otherwise ----
git_prompt_path() {
  local root
  if root=$(git rev-parse --show-toplevel 2>/dev/null); then
    print -r -- "%F{magenta}[${root:h:t}]%f %F{cyan}${PWD:t}%f"
  else
    print -rP -- "%F{cyan}%c%f"
  fi
}
PROMPT="%(?:%{$fg_bold[green]%}%1{➜%} :%{$fg_bold[red]%}%1{➜%} ) \$(git_prompt_path)%{$reset_color%}"
PROMPT+=' $(git_prompt_info)'

# --- convenience --------------------------------------------------------------
alias sbx="$HOME/Sandbox/sandbox.sh"
alias wtl="git worktree list"
