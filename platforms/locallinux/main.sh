#!/bin/sh
# Portable bootstrap for NRIS/Slurm environments (POSIX /bin/sh)

# ============================================================
# ENVIRONMENT
# ============================================================
ENVIRONMENT="locallinux"; export ENVIRONMENT

# Resolve username
USER_NAME="${USER:-$(whoami)}"; export USER_NAME


# Storage paths
# ============================================================
# ENSURE DIRECTORIES EXIST
# ============================================================
ENV_STORAGE_BASE="$HOME/workspace/.env/workspace"; export ENV_STORAGE_BASE
VENV_BASE="$ENV_STORAGE_BASE/envbase"; export VENV_BASE
VENV_DIR="$VENV_BASE/pytorch_39_cuda_12"; export VENV_DIR
PROJ_STORAGE_BASE="$HOME/workspace/projects"; export PROJ_STORAGE_BASE
EXP_STORAGE_BASE="$HOME/workspace/experiment_storage"; export EXP_STORAGE_BASE

mkdir -p \
  "$ENV_STORAGE_BASE" \
  "$VENV_BASE" \
  "$PROJ_STORAGE_BASE" \
  "$EXP_STORAGE_BASE"

# ============================================================
# PYTHON / PIP / POETRY CONFIG
# ============================================================

export PIP_NO_CACHE_DIR="1"
export PIP_COMPILE="1"
export PIP_NO_WARN_SCRIPT_LOCATION="1"
export PIP_NO_WARN_CONFLICTS="1"
export SSL_CERT_FILE=""
export REQUESTS_CA_BUNDLE=""
export POETRY_VIRTUALENVS_CREATE="false"
export POETRY_VIRTUALENVS_PREFER_ACTIVE="true"
export GIT_CONFIG_GLOBAL="$ENV_STORAGE_BASE/files/gitconfig"

# Conda config (if available)
if command -v conda >/dev/null 2>&1; then
  conda config --set ssl_verify false >/dev/null 2>&1
fi

# ============================================================
# GPU DETECTION
# ============================================================

has_gpu=false
if command -v nvidia-smi >/dev/null 2>&1; then
  if nvidia-smi -L >/dev/null 2>&1; then
    has_gpu=true
  fi
fi

# ============================================================
# Activate environment (conda if available)
# ============================================================
if command -v conda >/dev/null 2>&1; then
  CONDA_BASE="$(conda info --base 2>/dev/null)"
  if [ -n "$CONDA_BASE" ] && [ -f "$CONDA_BASE/etc/profile.d/conda.sh" ]; then
    . "$CONDA_BASE/etc/profile.d/conda.sh"
    conda activate "$VENV_DIR" 2>/dev/null || \
      echo "[env] WARNING: conda activate failed, using current python"
  fi
fi

# ============================================================
# Python Path setup (only pymods)
# ============================================================
PYMODS_PATH="$ENV_STORAGE_BASE/programs/pymods"

case ":${PYTHONPATH:-}:" in
  *":$PYMODS_PATH:"*) ;;
  *)
    if [ -n "${PYTHONPATH:-}" ]; then
      export PYTHONPATH="$PYMODS_PATH:$PYTHONPATH"
    else
      export PYTHONPATH="$PYMODS_PATH"
    fi
    ;;
esac


# ============================================================
# HELPERS
# ============================================================

[ -f "$ENV_STORAGE_BASE/platforms/locallinux/helper.sh" ] && . "$ENV_STORAGE_BASE/platforms/locallinux/helper.sh"
[ -f "$ENV_STORAGE_BASE/programs/linux/prog_alias.sh" ] && . "$ENV_STORAGE_BASE/programs/linux/prog_alias.sh"
[ -f "$ENV_STORAGE_BASE/programs/linux/useful_cmd.sh" ] && . "$ENV_STORAGE_BASE/programs/linux/useful_cmd.sh"

# ============================================================
# ALIASES (AFTER FUNCTIONS)
# ============================================================

alias set_ps='set_ps_locallinux'
alias env_updater='locallinux_env_updater'
alias ws='workspace_helper'

# ============================================================
# WORKSPACE DISPATCHER (POSIX SAFE)
# ============================================================

workspace_helper() {
  sub="$1"
  shift

  case "$sub" in

    t)
      start_tmux
      ;;

    env)
      env_updater "${1:-}" "${2:-}"
      ;;

    show)
      case "${1:-}" in
        exp) python -m manager show experiments ;;
        r)   python -m manager show remotes ;;
        *)   python -m manager show experiments ;;
      esac
      ;;

    scan)
      python -m manager experiment scan
      ;;

    sync)
      python -m manager experiment sync "$@"
      ;;

    update)
      python -m manager update "$@"
      ;;

    ref)
      python -m manager experiment refresh
      ;;

    sel)
      eval "$(python -m manager experiment sel "$@")"
      ;;

    go)
      eval "$(python -m manager experiment go "$@")"
      ;;
    *)
      cat <<EOF
Workspace Helper

Usage:
  ws <command> [options]

Commands:
  t                 Start tmux
  env               Update environment
  scan              Scan workspace
  sync              Sync experiments
  update            Run updates
  ref               Refresh experiments

  show exp          Show experiments
  show r            Show remotes

  sel <id>          Select experiment
  go <id>           Go to experiment
EOF
      ;;
  esac
}


# ============================================================
# STATUS
# ============================================================
echo "[env] GPU=$has_gpu"
py -m mlflow_server
eval "$(py -m ssh-agent)"
py -m workspace_repo_sync