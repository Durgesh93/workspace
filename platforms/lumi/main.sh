#!/usr/bin/env bash

# ============================================================
# ENVIRONMENT SETUP (LUMI)
# ============================================================
export ENVIRONMENT="lumi"
export SBATCH_ACCOUNT="project_465002274"

# Resolve username
USER_NAME="${USER:-$(whoami)}"

# Storage paths
export ENV_STORAGE_BASE="/project/${SBATCH_ACCOUNT}/${USER_NAME}/envs/workspace"
export VENV_BASE="${ENV_STORAGE_BASE}/envbase"
export PROJ_STORAGE_BASE="/project/${SBATCH_ACCOUNT}/${USER_NAME}/projects"
export EXP_STORAGE_BASE="/scratch/${SBATCH_ACCOUNT}/${USER_NAME}/experiment_storage"

# ============================================================
# SLURM + GPU DETECTION
# ============================================================
is_slurm_session=false
[[ -n "${SLURM_JOB_ID:-}" ]] && is_slurm_session=true

has_gpu=false

# ROCm detection (LUMI)
if command -v rocm-smi >/dev/null 2>&1; then
  rocm-smi -L >/dev/null 2>&1 && has_gpu=true
fi

# Slurm GPU allocation detection
if $is_slurm_session && [[ -n "${SLURM_GPUS:-}${SLURM_JOB_GPUS:-}${SLURM_JOB_GRES:-}" ]]; then
  has_gpu=true
fi

# Stack selection
export LUMI_STACK="CPU"
if $is_slurm_session && $has_gpu; then
  export LUMI_STACK="GPU"
fi

# ============================================================
# OPTIONAL HELPERS (SAFE SOURCE)
# ============================================================
[[ -f "$ENV_STORAGE_BASE/platforms/lumi/helper.sh" ]] && source "$ENV_STORAGE_BASE/platforms/lumi/helper.sh"
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
export PYTHONPATH="$(python -c 'import site; print(site.getusersitepackages())'):$ENV_STORAGE_BASE/programs/pymods"

# ============================================================
# GIT CONFIG (USER)
# ============================================================
git config --global user.name "durgesh.lumi"
git config --global user.email "durgesh080793@gmail.com.lumi"

# ============================================================
# ALIASES
# ============================================================
alias conf_selector='set_job_conf_lumi'
alias job_runner='create_job_with_slurm_lumi'
alias job_watcher='watch_lumi_resources'
alias job_deleter='delete_lumi_job'
alias job_logger='show_lumi_job_log'

alias set_ps='set_ps_lumi'
alias env_updater='lumi_env_updater'
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

  default_job_conf_lumi
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
          create_wandb_sweep_job_with_slurm_lumi "${3}"
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

    # ---------------- HELP ----------------
    *)
      cat <<EOF
Workspace Helper (LUMI)

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
set_rocm_config
use_only_rocm_python
# Start SSH agent
eval "$(python -m ssh-agent)"
py -m workspace_repo_sync