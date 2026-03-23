#!/bin/sh
# LocalLinux helper functions (POSIX /bin/sh)

# ------------------------------------------------------------
# locallinux_env_updater
# ------------------------------------------------------------
locallinux_env_updater() {

  case "${1:-}" in

    new)
      ENV_YML="$ENV_STORAGE_BASE/files/condaenv/env_cuda.yml"

      conda update -n base -c defaults conda
      # Safe cleanup
      conda remove --prefix "$VENV_DIR" --all -y 2> /dev/null

      # Create env
      conda env create \
        --prefix "$VENV_DIR" \
        --file "$ENV_YML"

      # Activate (POSIX-safe)
      if command -v conda >/dev/null 2>&1; then
        . "$(conda info --base)/etc/profile.d/conda.sh"
        conda activate "$VENV_DIR"
      fi
      ;;

    update)
      ENV_YML="$ENV_STORAGE_BASE/files/condaenv/env_cuda.yml"
  
      conda update -n base -c defaults conda
      . "$(conda info --base)/etc/profile.d/conda.sh"
      conda activate "$VENV_DIR"

      export PIP_NO_CACHE_DIR=1
      export PIP_EXTRA_INDEX_URL="https://download.pytorch.org/whl/cu129"

      pkg="${2:-}"

      if [ -n "$pkg" ]; then
        if pip show "$pkg" >/dev/null 2>&1; then
          echo "Package '$pkg' already installed"
        else
          pip install -U "$pkg"
        fi
      fi
      ;;

    *)
      echo "Usage: locallinux_env_updater new|update [package]"
      return 2
      ;;
  esac
}

# ============================================================
# TMUX
# ============================================================

start_tmux() {
  if ! command -v tmux >/dev/null 2>&1; then
    echo "tmux not found"; return 1
  fi

  tmux has-session -t workspace 2>/dev/null || {
    tmux new-session -d -s workspace -n main
    tmux split-window -h
    tmux split-window -v
    tmux select-pane -t 0
  }

  if [ -f "$ENV_STORAGE_BASE/config/tmux/tmux.conf" ]; then
    tmux source-file "$ENV_STORAGE_BASE/config/tmux/tmux.conf"
  fi

  tmux attach-session -t workspace
}


# ============================================================
# PROMPT COLORS
# ============================================================

ps_init_colors() {
  if [ "${PS_NO_COLOR:-0}" = "1" ] || [ ! -t 1 ] || [ "${TERM:-dumb}" = "dumb" ]; then
    C_HDR= C_KEY= C_VAL= C_TAG= C_RST=
    return
  fi

  C_HDR=$(printf '\033[35m')
  C_KEY=$(printf '\033[36m')
  C_VAL=$(printf '\033[32m')
  C_TAG=$(printf '\033[34m')
  C_RST=$(printf '\033[0m')
}

# ============================================================
# PATH DISPLAY
# ============================================================

shortpwd() {
  p="${PWD:-.}"

  if [ -n "$HOME" ] && [ "${p#"$HOME"}" != "$p" ]; then
    p="~${p#"$HOME"}"
  fi

  printf '%s\n' "$p" | awk -F/ '
  {
    n=split($0,a,"/")
    if(n<=4){print $0}
    else print "…/"a[n-3]"/"a[n-2]"/"a[n-1]"/"a[n]
  }'
}

# ============================================================
# PROMPT
# ============================================================

set_ps_locallinux() {

  p="${REPO_DIR:-None}"
  e="${BRANCH_NAME:-None}"

  j="${NUM_JOBS:-1}"
  n="${NUM_NODES:-1}"
  g="${NUM_GPUS:-1}"
  part="${GPU_PART:-accel}"
  t="${JOB_DURH:-1}"

  cur="$(shortpwd)"

  PS1="${C_HDR}[exp]${C_RST} \
P:${C_VAL}${p}${C_RST} \
E:${C_VAL}${e}${C_RST}\n\
${C_TAG}[locallinux]${C_RST} ${cur} $ "

  export PS1
}

py() {
  repo="${REPO_DIR:-}"
  branch="${BRANCH_NAME:-}"

  if [ -n "$repo" ]; then
    if [ -n "$branch" ]; then
      target="$repo/$branch"
    else
      target="$repo"
    fi

    if [ -d "$target" ]; then

      # Append safely (no duplicates)
      case ":${PYTHONPATH:-}:" in
        *":$target:"*) ;;
        *)
          if [ -n "$PYTHONPATH" ]; then
            PYTHONPATH="$target:$PYTHONPATH"
          else
            PYTHONPATH="$target"
          fi
          export PYTHONPATH
          ;;
      esac
    fi
  fi

  # Run python with all arguments
  python "$@"
}

# Update prompt on directory change
cd() {
  command cd "$@" || return
  set_ps_locallinux
}

# Initialize colors
ps_init_colors