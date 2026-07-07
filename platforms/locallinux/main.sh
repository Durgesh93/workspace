#!/usr/bin/env bash

# ============================================================
# ENVIRONMENT SETUP (OLIVIA)
# ============================================================
export ENVIRONMENT="olivia"
export SBATCH_ACCOUNT="nn8104k"

# Site proxies
export http_proxy="http://10.63.2.48:3128/"
export https_proxy="http://10.63.2.48:3128/"
export HTTP_PROXY="$http_proxy"
export HTTPS_PROXY="$https_proxy"

# Resolve username
USER_NAME="${USER:-$(whoami)}"
export USER_NAME


# Storage paths
export VENV_NAME="python_venv"
export ENV_TYPE="pt"

export DATA_STORAGE_BASE="/cluster/work/projects/${SBATCH_ACCOUNT}/dsi014"

export ENV_STORAGE_BASE="${DATA_STORAGE_BASE}/envs/workspace"
export VENV_BASE="${DATA_STORAGE_BASE}/envbase"
export PROJ_STORAGE_BASE="${DATA_STORAGE_BASE}/projects"
export EXP_STORAGE_BASE="${DATA_STORAGE_BASE}/experiment_storage"
export TMPDIR="${DATA_STORAGE_BASE}/tmp"

export HOME_USE_PCT="$(df /cluster/home/$USER_NAME --output=pcent 2>/dev/null | tail -n 1 | tr -d ' ')"
export WORK_USE_PCT="$(df /cluster/work/projects/$SBATCH_ACCOUNT --output=pcent 2>/dev/null | tail -n 1 | tr -d ' ')"
export PROJECT_USE_PCT="$WORK_USE_PCT"

mkdir -p "$ENV_STORAGE_BASE"
mkdir -p "$ENV_STORAGE_BASE/platforms/olivia"
mkdir -p "$ENV_STORAGE_BASE/files"
mkdir -p "$ENV_STORAGE_BASE/files/requirements"
mkdir -p "$VENV_BASE"
mkdir -p "$PROJ_STORAGE_BASE"
mkdir -p "$EXP_STORAGE_BASE"
mkdir -p "$TMPDIR"

# ============================================================
# SLURM + GPU DETECTION
# ============================================================
is_slurm_session=false
[[ -n "${SLURM_JOB_ID:-}" ]] && is_slurm_session=true

has_gpu=false

# NVIDIA detection Olivia / GH200
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi -L >/dev/null 2>&1 && has_gpu=true
fi

# Slurm GPU allocation detection
if $is_slurm_session && [[ -n "${SLURM_GPUS:-}${SLURM_JOB_GPUS:-}${SLURM_GPUS_ON_NODE:-}${CUDA_VISIBLE_DEVICES:-}" ]]; then
  has_gpu=true
fi

# Stack selection
export OLIVIA_STACK="CPU"
if $is_slurm_session && $has_gpu; then
  export OLIVIA_STACK="GPU"
fi

# ============================================================
# OPTIONAL HELPERS (SAFE SOURCE)
# ============================================================
[[ -f "$ENV_STORAGE_BASE/platforms/olivia/helper.sh" ]] && source "$ENV_STORAGE_BASE/platforms/olivia/helper.sh"
[[ -f "$ENV_STORAGE_BASE/programs/linux/prog_alias.sh" ]] && source "$ENV_STORAGE_BASE/programs/linux/prog_alias.sh"
[[ -f "$ENV_STORAGE_BASE/programs/linux/useful_cmd.sh" ]] && source "$ENV_STORAGE_BASE/programs/linux/useful_cmd.sh"

# ============================================================
# PYTHON / PIP CONFIG
# ============================================================
export PIP_NO_CACHE_DIR=1
export PIP_COMPILE=1
export PIP_NO_WARN_SCRIPT_LOCATION=1
export PIP_NO_WARN_CONFLICTS=1

export GIT_CONFIG_GLOBAL="$ENV_STORAGE_BASE/files/gitconfig"
export PYTHONPATH="$(python3 -c 'import site; print(site.getusersitepackages())' 2>/dev/null):$ENV_STORAGE_BASE/programs/pymods"

export HF_HOME="${DATA_STORAGE_BASE}/.cache/huggingface"
export TRANSFORMERS_CACHE="$HF_HOME"
export TORCH_HOME="${DATA_STORAGE_BASE}/.cache/torch"
export WANDB_DIR="${DATA_STORAGE_BASE}/wandb"

mkdir -p "$HF_HOME"
mkdir -p "$TORCH_HOME"
mkdir -p "$WANDB_DIR"

# ============================================================
# GIT CONFIG (USER)
# ============================================================
git config --global user.name "durgesh.olivia"
git config --global user.email "durgesh080793@gmail.com.olivia"

# ============================================================
# ALIASES
# ============================================================
alias conf_selector='set_job_conf_olivia'
alias job_runner='create_job_with_slurm_olivia'
alias job_watcher='watch_olivia_resources'
alias job_deleter='delete_olivia_job'
alias job_logger='show_olivia_job_log'

alias set_ps='set_ps_olivia'
alias env_updater='olivia_env_updater'
alias ws='workspace_helper'
alias wandb_sweep='ws sweep wandb'

# ============================================================
# LOCALE (UTF-8 SAFE)
# ============================================================
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"
export LC_CTYPE="${LC_CTYPE:-C.UTF-8}"

# ============================================================
# WORKSPACE COMMAND DISPATCHER
# ============================================================
workspace_helper() {

  default_job_conf_olivia
  set_ps

  sub="$1"

  case "$sub" in

    # ---------------- JOB OPS ----------------
    watch) job_watcher "${2:-}" ;;
    del)   job_deleter "${2:-}" ;;
    logs)  job_logger  "${2:-}" ;;

    # ---------------- SWEEPS ----------------
    sweep)
      case "${2:-}" in
        wandb)
          if [[ -z "${3:-}" ]]; then
            echo "Usage: ws sweep wandb <entity/project/sweep_id>"
            return
          fi
          create_wandb_sweep_job_with_slurm_olivia "${3}"
          ;;
        *)
          echo "Usage: ws sweep {wandb} <entity/project/sweep_id>"
          ;;
      esac
      ;;

    # ---------------- CORE ----------------
    t)    start_tmux ;;
    env)  env_updater "${2:-}" "${3:-}" ;;

    show)
      case "${2:-}" in
        exp) python -m manager show experiments ;;
        r)   python -m manager show remotes ;;
        *)   python -m manager show experiments ;;
      esac
      ;;

    scan)   python -m manager experiment scan ;;
    sync)   python -m manager experiment sync "${@:2}" ;;
    update) python -m manager update "${@:2}" ;;
    ref)    python -m manager experiment refresh ;;

    # ---------------- NAV ----------------
    sel) eval "$(python -m manager experiment sel "${@:2}")" ;;
    go)  eval "$(python -m manager experiment go  "${@:2}")" ;;
    run) job_runner "${@:2}";;
    conf) conf_selector "${@:2}";;

    # ---------------- HELP ----------------
    *)
      cat <<EOF
Workspace Helper (OLIVIA)

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

  watch [job]       Monitor job
  del [job]         Delete job
  logs [job]        View logs

  sweep wandb <entity/project/sweep_id>

EOF
      ;;
  esac
}

# ============================================================
# FINAL BOOTSTRAP
# ============================================================
set_gpu_config_olivia
VENV_DIR="${VENV_BASE}/${VENV_NAME}_${ENV_TYPE}"
export VENV_DIR

ws env reset

# Start SSH agent
eval "$(py -m ssh-agent 2>/dev/null)"
