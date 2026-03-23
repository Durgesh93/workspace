#!/bin/sh
# Portable bootstrap for NRIS/Slurm environments (POSIX /bin/sh).

# --------- Environment / stack detection (POSIX) ---------
ENVIRONMENT="olivia"; export ENVIRONMENT           # Logical environment name
SBATCH_ACCOUNT="nn8104k"; export SBATCH_ACCOUNT    # Slurm project/account

# Resolve username portably
USER_NAME="${USER:-$(whoami)}"

# Root of your on-cluster workspace (envs, projects, experiments)
ENV_STORAGE_BASE="/cluster/work/projects/$SBATCH_ACCOUNT/$USER_NAME/envs/workspace"; export ENV_STORAGE_BASE
VENV_BASE="$ENV_STORAGE_BASE/envbase"; export VENV_BASE                    # Centralized env base
PROJ_STORAGE_BASE="/cluster/work/projects/$SBATCH_ACCOUNT/$USER_NAME/projects"; export PROJ_STORAGE_BASE
EXP_STORAGE_BASE="/cluster/work/projects/$SBATCH_ACCOUNT/$USER_NAME/experiment_storage"; export EXP_STORAGE_BASE

# Site proxies (cluster-local); remove if not needed
http_proxy="http://10.63.2.48:3128/"; export http_proxy
https_proxy="http://10.63.2.48:3128/"; export https_proxy

# ----- pip behavior pinned to cluster storage -----
export PIP_NO_CACHE_DIR=1    # pip cache dir
export PIP_COMPILE=1                                          # compile .pyc
export PIP_NO_WARN_SCRIPT_LOCATION=1                          # silence script dir warnings
export PIP_NO_WARN_CONFLICTS=1                                # silence conflict warnings


# ----- Poetry: reuse active interpreter instead of creating venvs -----
export POETRY_VIRTUALENVS_CREATE=false
export POETRY_VIRTUALENVS_PREFER_ACTIVE=true
export GIT_CONFIG_GLOBAL="$ENV_STORAGE_BASE/files/gitconfig"


git config --global user.name "durgesh.olivia"
git config --global user.email "durgesh080793@gmail.com.olivia"

# Detect if we're in a Slurm job step/allocation
is_slurm_session=false
[ -n "${SLURM_JOB_ID:-}" ] && is_slurm_session=true

# Detect GPU presence (either via nvidia-smi or Slurm GPU request)
has_gpu=false
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi -L >/dev/null 2>&1 && has_gpu=true
fi
if $is_slurm_session && [ -n "${SLURM_GPUS:-}${SLURM_JOB_GPUS:-}${SLURM_JOB_GRES:-}" ]; then
  has_gpu=true
fi

# Reset PATH to a sane baseline (system default) before layering shims/modules
PATH="$(getconf PATH)"; export PATH

# Choose CPU/GPU module stack based on detection above
OLIVIA_STACK="NRIS/CPU"
if $is_slurm_session && $has_gpu; then
  OLIVIA_STACK="NRIS/GPU"
fi
export OLIVIA_STACK

# Initialize environment modules if available
if command -v module >/dev/null 2>&1; then
  module --force purge                                  # clean module state
  module load "$OLIVIA_STACK"                           # load CPU or GPU stack
  module load hpc-container-wrapper 2>/dev/null || true # optional helper
fi

# Prepend prebuilt env bin dirs if present (toolchain shims)
if [ "${OLIVIA_STACK:-NRIS/CPU}" = "NRIS/GPU" ]; then
  if [ -d "$VENV_BASE/pytorch_311_cuda/bin" ]; then
    path_prepend "$VENV_BASE/pytorch_311_cuda/bin"
    export TMPDIR="${SLURM_TMPDIR:-${TMPDIR:-/tmp}}"
    export PYTHONUSERBASE="$(mktemp -d -p "$TMPDIR" pyuserbase.XXXXXX)"
    export PYTHONPATH="$(python -c 'import site; print(site.getusersitepackages())'):$ENV_STORAGE_BASE/programs/pymods"
  fi
else
  if [ -d "$VENV_BASE/python_311_cpu/bin" ]; then
    path_prepend "$VENV_BASE/python_311_cpu/bin"
    export TMPDIR="${SLURM_TMPDIR:-${TMPDIR:-/tmp}}"
    export PYTHONUSERBASE="$(mktemp -d -p "$TMPDIR" pyuserbase.XXXXXX)"
    export PYTHONPATH="$(python -c 'import site; print(site.getusersitepackages())'):$ENV_STORAGE_BASE/programs/pymods"
  fi
fi

# Source optional site-level helper scripts (no errors if missing)
[ -f "$ENV_STORAGE_BASE/platforms/olivia/helper.sh" ] && . "$ENV_STORAGE_BASE/platforms/olivia/helper.sh"
[ -f "$ENV_STORAGE_BASE/programs/linux/prog_alias.sh" ] && . "$ENV_STORAGE_BASE/programs/linux/prog_alias.sh"
[ -f "$ENV_STORAGE_BASE/programs/linux/useful_cmd.sh" ] && . "$ENV_STORAGE_BASE/programs/linux/useful_cmd.sh"


# Aliases for common workflows (defined in sourced helpers)
alias conf_selector='set_job_conf_olivia'
alias job_runner='create_job_with_slurm_olivia'
alias runner='create_run_olivia'
alias job_watcher='watch_olivia_resources'
alias job_deleter='delete_olivia_job'
alias set_ps='set_ps_olivia'
alias env_updater='olivia_env_updater'
alias job_logger='show_olivia_job_log'
alias ws='workspace_helper'

# Force UTF-8 locales so prompts and tmux render correctly
export LANG=${LANG:-C.UTF-8}
export LC_ALL=${LC_ALL:-C.UTF-8}
export LC_CTYPE=${LC_CTYPE:-C.UTF-8}

# Friendly status banner
# echo "[env] STACK=$OLIVIA_STACK | SLURM_JOB_ID=${SLURM_JOB_ID:-none} | GPU=$has_gpu"


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

    scan)   python -m manager scan ;;
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


ps_init_colors
start_tmux
eval "$(python -m ssh-agent)"
