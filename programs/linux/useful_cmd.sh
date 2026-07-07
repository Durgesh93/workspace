### Quality-of-life
alias ll='ls -alF'                 # long list, file types
alias la='ls -A'                   # all except . and ..
alias l='ls -CF'                   # columns
alias ..='cd ..'
alias ...='cd ../..'
alias ~='cd ~'
alias path='echo -e ${PATH//:/\n}' # print PATH lines

### Safer destructive ops
alias c='clear'
alias cls='clear'
alias mv='mv -i'                   # prompt before overwrite
alias cp='cp -i'                   # prompt before overwrite
alias rm='rm -I'                   # prompt if >3 files
alias rmd='rm -rf'                 # I know what I'm doing

### Search & filters
alias grep='grep --color=auto'
alias egrep='egrep --color=auto'
alias f='find . -type f -iname'    # f PATTERN
alias d='find . -type d -iname'    # d PATTERN

### Disk & system
alias du1='du -h --max-depth=1'
alias dfh='df -h'
alias freeh='free -h 2>/dev/null || vm_stat'  # linux/mac

### Networking
alias myip='curl -s ifconfig.me || curl -s ipinfo.io/ip'
alias ports='ss -tulpn 2>/dev/null || lsof -i -P -n'

### Archives
alias untar='tar -xvf'             # untar FILE.tar[.gz|.xz]
alias targz='tar -czvf'            # targz ARCHIVE.tar.gz DIR

### Processes & jobs
alias psa='ps auxf'
alias psg='ps aux | grep -i'       # psg python
alias watchq='watch -n 1 nvidia-smi || watch -n 1 squeue -u $USER'

### Git: readable status/log
alias gst='git status -sb'         # short, branch
alias gl='git log --oneline --graph --decorate --max-count=30'
alias gll='git log --pretty=format:"%C(auto)%h %ad %d %s %C(blue)<%an>" --date=short'

### Git: common actions
alias ga='git add'
alias gaa='git add -A'
alias gc='git commit'
alias gcm='git commit -m'
alias gca='git commit --amend --no-edit'
alias gcan='git commit --amend'
alias gco='git checkout'
alias gcb='git checkout -b'
alias gsw='git switch'
alias gswc='git switch -c'         # new branch

alias gd='git diff'
alias gds='git diff --staged'
alias gf='git fetch --all --prune'
alias gp='git push'
alias gpf!='git push --force-with-lease'     # safer force
alias gpl='git pull --ff-only'

### Git: stash / clean / prune
alias gsta='git stash push -u'     # stash incl. untracked
alias gstp='git stash pop'
alias gclean='git clean -xdf'      # ⚠ removes untracked/ignored
alias gprune='git remote prune origin'

### Git: rebase helpers
alias grc='git rebase --continue'
alias gra='git rebase --abort'
alias gri='git rebase -i HEAD~10'  # edit last 10

### Git: show me things
alias gbr='git branch -vv'
alias gt='git tag --list --sort=-creatordate'
alias gwho='git shortlog -sn'      # top committers

### Git: quick “what changed”
alias glast='git show --stat --oneline HEAD'
alias gblame='git blame -w -C -M'  # track moved code

### Tarball a repo (ignore git stuff)
alias gittar='git archive --format=tar.gz -o ../repo.tar.gz HEAD'

### Python / Pip (optional)
alias venv='python -m venv .venv && . .venv/bin/activate'
alias pipup='python -m pip install -U pip setuptools wheel'

### Slurm (optional HPC)
alias sq='squeue -u $USER'
alias sqa='squeue -A "${ACCOUNT_NAME:-$ACCOUNT:-}"'
alias sj='scontrol show job'
alias sacctme='sacct -u $USER --format=JobID,State,Elapsed,MaxRSS,MaxVMSize%'

### Small helpers
mkcd(){ mkdir -p "$1" && cd "$1"; }
cdf(){ cd "$(dirname "$1")"; }      # cdf /path/file -> cd to its dir
timer(){ SECONDS=0; "$@"; echo "⏱ ${SECONDS}s"; }

mtag() {
    MR_NUM=$1
    START_COMMIT=$2

    if [ -z "$MR_NUM" ] || [ -z "$START_COMMIT" ]; then
        echo "Usage: mr_tag <MR_NUMBER> <START_COMMIT>"
        return 1
    fi

    MR_TAG="[MR-${MR_NUM}]"

    git rebase ${START_COMMIT}^ --exec \
    "msg=\$(git log -1 --pretty=%B); clean=\$(printf \"%s\" \"\$msg\" | sed -E 's/^(\[MR-[0-9]+\] )+//'); git commit --amend --allow-empty -m \"${MR_TAG} \$clean\""
}

greset() {
  local root_branch="root"
  local repo_root
  local jobs="${GRESET_JOBS:-4}"
  local -a remote_branches=()

  repo_root="$(git rev-parse --show-toplevel)" || return 1
  cd "$repo_root" || return 1

  git switch "$root_branch" || return 1

  # remove linked worktrees except main repo
  while read -r wt; do
    [ -z "$wt" ] && continue
    if [ "$wt" != "$repo_root" ]; then
      echo "Removing worktree: $wt"
      git worktree remove "$wt" --force || return 1
    fi
  done < <(git worktree list --porcelain | awk '/^worktree /{print $2}')

  git worktree prune || return 1

  # delete all local branches except root
  while read -r br; do
    [ -z "$br" ] && continue
    if [ "$br" != "$root_branch" ]; then
      echo "Deleting local branch: $br"
      git branch -D "$br" || return 1
    fi
  done < <(git branch --format='%(refname:short)')

  git fetch origin || return 1

  # collect remote branches except root
  while read -r br; do
    [ -z "$br" ] && continue
    if [ "$br" != "$root_branch" ]; then
      remote_branches+=("$br")
    fi
  done < <(
    git branch -r \
      | sed 's/^[[:space:]]*//' \
      | grep '^origin/' \
      | grep -v -- '->' \
      | sed 's#^origin/##'
  )

  # create worktrees sequentially
  for br in "${remote_branches[@]}"; do
    echo "Creating worktree for $br"
    git worktree add "$repo_root/$br" -b "$br" "origin/$br" || return 1
  done

  echo "All worktrees created"

  # submodule init in parallel only
  printf '%s\n' "${remote_branches[@]}" | xargs -r -P "$jobs" -I{} bash -c '
    repo_root="$1"
    br="$2"
    echo "Initializing submodules in $br"
    cd "$repo_root/$br" &&
    git submodule update --init --recursive
  ' _ "$repo_root" "{}" || return 1
}
