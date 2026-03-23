#!/bin/sh

# ============================================================
# JOB MANAGEMENT LUMI code will beautify
# ============================================================
delete_lumi_job() {
  if [ -z "${1:-}" ]; then
    if [ -n "${JOB_NAME:-}" ]; then
      scancel -n "$JOB_NAME"
    else
      echo "JOB_NAME not set"; return 1
    fi
    return 0
  fi

  MYJOBS="$(squeue --me -h -o '%i')"

  case "$1" in
    all)
      printf '%s\n' "$MYJOBS" | while IFS= read -r job; do
        [ -n "$job" ] && scancel "$job"
      done
      ;;
    last)
      job="$(printf '%s\n' "$MYJOBS" | tail -n 1)"
      [ -n "$job" ] && scancel "$job"
      ;;
    *)
      idx="${2:-0}"
      n=$((idx + 1))
      job="$(printf '%s\n' "$MYJOBS" | awk "NR==$n{print; exit}")"
      [ -n "$job" ] && scancel "$job"
      ;;
  esac
}

# ------------------------------------------------------------
# LOG STREAMING
# ------------------------------------------------------------
show_lumi_job_log() {
  [ -z "${1:-}" ] && { echo "Usage: show_lumi_job_log <job_id>"; return 2; }

  job_id="$1"

  stdout_file="$(scontrol show job "$job_id" | awk -F= '/StdOut/ {print $2}')"
  stderr_file="$(scontrol show job "$job_id" | awk -F= '/StdErr/ {print $2}')"

  [ -z "$stdout_file" ] || [ -z "$stderr_file" ] && {
    echo "Logs not found for job $job_id"; return 1;
  }

  echo "Streaming logs for $job_id"
  echo "stdout: $stdout_file"
  echo "stderr: $stderr_file"

  tail -f "$stdout_file" &
  T1=$!
  tail -f "$stderr_file" &
  T2=$!

  trap 'kill "$T1" "$T2" 2>/dev/null' INT TERM
  wait
}

# ------------------------------------------------------------
# RESOURCE WATCHER
# ------------------------------------------------------------
watch_lumi_resources() {
  i=1
  while [ "$i" -le 60 ]; do
    clear
    squeue --me
    i=$((i + 1))
    sleep 60
  done
}

# ============================================================
# ENVIRONMENT MANAGEMENT
# ============================================================
lumi_env_updater() {
  action="${1:-}"

  ENV_YML="$ENV_STORAGE_BASE/files/condaenv/env_pt_rocm.yml"
  VENV_DIR="${VENV_BASE}/${VENV_NAME}_pt"

  setup_vars() {
    export TMPDIR="/scratch/${SBATCH_ACCOUNT}/${USER_NAME}/tmp"
    mkdir -p "$TMPDIR"

    unset PYTHONNOUSERSITE
    export PYTHONUSERBASE="$TMPDIR/pip_userbase"
    export PIP_CACHE_DIR="$TMPDIR/pip-cache"
    mkdir -p "$PIP_CACHE_DIR"
    mkdir -p "$PYTHONUSERBASE"

    export MIOPEN_DISABLE_CACHE=0
    export MIOPEN_USER_DB_PATH="$TMPDIR/miopen"
    export MIOPEN_CUSTOM_CACHE_DIR="$TMPDIR/miopen"
    mkdir -p "$MIOPEN_USER_DB_PATH"

    export ROCM_PATH="/opt/rocm-6.3.4"
    export HIP_PATH="/opt/rocm-6.3.4"
    export DEVICE_LIB_PATH="/opt/rocm-6.3.4/lib/llvm/lib/clang/18/lib/amdgcn/bitcode"
    export LD_LIBRARY_PATH="/opt/rocm-6.3.4/lib:${LD_LIBRARY_PATH:-}"
    export AMD_LOG_LEVEL=0
    export MIOPEN_ENABLE_LOGGING=0
  }

  load_modules() {
    module is-loaded LUMI >/dev/null 2>&1 || module load LUMI
    module is-loaded lumi-container-wrapper >/dev/null 2>&1 || module load lumi-container-wrapper
  }

  clean_path() {
    PATH="$(echo "$PATH" | tr ':' '\n' \
      | grep -v "$VENV_BASE" \
      | awk '!seen[$0]++' \
      | paste -sd: -)"
    export PATH
  }

  activate_env() {
    clean_path
    export PATH="$VENV_DIR/bin:$PATH"
    export PYTHONNOUSERSITE=1

    echo "Active Python:"
    which python
    python --version
  }

  case "$action" in

    new)
      setup_vars
      load_modules
      clean_path

      echo "Creating PyTorch ROCm environment:"
      echo "$VENV_DIR"

      conda-containerize new --prefix "$VENV_DIR" "$ENV_YML" || return 1

      setup_vars
      activate_env

      echo "Done."
      ;;

    update)
      setup_vars
      load_modules
      clean_path

      shift
      packages="$*"

      if [ -n "$packages" ]; then
        tmpfile="$(mktemp /tmp/postinstall.XXXXXX.sh)"

        {
          echo '#!/usr/bin/env bash'
          echo 'export PYTHONNOUSERSITE=1'
          echo 'unset PIP_USER'
          echo 'unset PYTHONUSERBASE'
          echo "export PIP_CACHE_DIR=$PIP_CACHE_DIR"

          for pkg in $packages; do
            echo "python -m pip install -U $pkg"
          done
        } > "$tmpfile"

        chmod +x "$tmpfile"

        conda-containerize update "$VENV_DIR" --post-install "$tmpfile" || {
          rm -f "$tmpfile"
          return 1
        }

        rm -f "$tmpfile"
      else
        conda-containerize update "$VENV_DIR" || return 1
      fi

      setup_vars
      activate_env

      echo "Done."
      ;;

    reset)
      setup_vars
      activate_env
      ;;

    kernel)
      setup_vars
      activate_env

      python -m ipykernel install --user \
        --name venv_pt_rocm \
        --display-name "Python PyTorch ROCm"
      ;;

    check)
      setup_vars
      activate_env

      python - <<'PY'
import sys, site, os
print("sys.executable:", sys.executable)
print("ENABLE_USER_SITE:", site.ENABLE_USER_SITE)
print("PYTHONNOUSERSITE:", os.environ.get("PYTHONNOUSERSITE"))

import numpy as np
print("numpy:", np.__version__)

import torch
print("torch:", torch.__version__)
print("hip:", torch.version.hip)
print("cuda available:", torch.cuda.is_available())
print("device count:", torch.cuda.device_count())

try:
    import datasets
    print("datasets:", datasets.__version__)
except Exception as e:
    print("datasets failed:", e)

try:
    import transformers
    print("transformers:", transformers.__version__)
except Exception as e:
    print("transformers failed:", e)
PY
      ;;

    *)
      echo "Usage:"
      echo "  lumi_env_updater new"
      echo "  lumi_env_updater update [packages]"
      echo "  lumi_env_updater reste"
      echo "  lumi_env_updater kernel"
      echo "  lumi_env_updater check"
      return 2
      ;;
  esac
}



# ============================================================
# PATH + UTILITIES
# ============================================================

path_prepend() {
  case ":$PATH:" in
    *":$1:"*) ;;
    *) PATH="$1${PATH:+:$PATH}" ;;
  esac
  export PATH
}

# ============================================================
# PROMPT + UI
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

shortpwd() {
  p="${PWD:-.}"
  [ -n "$HOME" ] && p=$(printf '%s' "$p" | sed "s|^$HOME|~|")

  printf '%s\n' "$p" | awk -F/ '
  {
    n=split($0,a,"/")
    if(n<=4){print $0}
    else print "…/"a[n-3]"/"a[n-2]"/"a[n-1]"/"a[n]
  }'
}

set_ps_lumi() {

  p="${REPO_DIR:-None}"
  e="${BRANCH_NAME:-None}"

  j="${NUM_JOBS:-1}"
  n="${NUM_NODES:-1}"
  g="${NUM_GPUS:-1}"
  part="${GPU_PART:-accel}"
  t="${JOB_DURH:-1}"

  cur="$(shortpwd)"

  PS1="${C_HDR}[Dsk]${C_RST} \
P:${C_VAL}${PROJECT_USE_PCT}${C_RST} \
S:${C_VAL}${SCRATCH_USE_PCT}${C_RST}\n\
${C_HDR}[exp]${C_RST} \
P:${C_VAL}${p}${C_RST} \
E:${C_VAL}${e}${C_RST}\n\
${C_HDR}[job]${C_RST} \
J:${C_VAL}${j}${C_RST} N:${C_VAL}${n}${C_RST}  G:${C_VAL}${g}${C_RST}  P:${C_VAL}${g}${C_RST} T:${C_VAL}${t}${C_RST}\n\
${C_TAG}[$ENVIRONMENT]${C_RST} ${cur} $ "
  export PS1
}

cd() {
  command cd "$@" || return
  set_ps_lumi
}


# ============================================================
# PYTHON RUNNER
# ============================================================
py() {
  BASE="$PROJ_STORAGE_BASE/$REPO_DIR/$BRANCH_NAME"
  PYTHONPATH="$BASE${PYTHONPATH:+:$PYTHONPATH}" python "$@"
}

# ============================================================
# ROCM CONFIG
# ============================================================
set_rocm_config() {
  export TMPDIR="/scratch/${SBATCH_ACCOUNT}/${USER_NAME}/tmp"

  export ROCM_PATH="/opt/rocm-6.3.4"
  export HIP_PATH="/opt/rocm-6.3.4"
  export DEVICE_LIB_PATH="/opt/rocm-6.3.4/lib/llvm/lib/clang/18/lib/amdgcn/bitcode"

  case ":${LD_LIBRARY_PATH:-}:" in
    *":/opt/rocm-6.3.4/lib:"*) ;;
    *) export LD_LIBRARY_PATH="/opt/rocm-6.3.4/lib:${LD_LIBRARY_PATH:-}" ;;
  esac

  export XLA_FLAGS="--xla_gpu_cuda_data_dir=/opt/rocm-6.3.4"
  export TF_XLA_FLAGS="--tf_xla_auto_jit=0"

  export MIOPEN_DISABLE_CACHE=1
  export MIOPEN_USER_DB_PATH="$TMPDIR/miopen"

  mkdir -p "$TMPDIR" "$MIOPEN_USER_DB_PATH"
}

# ============================================================
# JOB CONFIG + SUBMISSION
# ============================================================

default_job_conf_lumi() {
  : "${NUM_JOBS:=1}"
  : "${NUM_NODES:=1}"
  : "${NUM_GPUS:=1}"
  : "${GPU_PART:=small-g}"
  : "${JOB_DUR:=0-05:00:00}"
  : "${JOB_DURH:=5 Hrs}"

  export NUM_JOBS NUM_NODES NUM_GPUS GPU_PART JOB_DUR JOB_DURH
}

create_job_with_slurm_lumi() {

  EXPERIMENT_NAME="$(py -m fake 2>&1)"
  TARGET_FILE="$1"

  sbatch --array="1-${NUM_JOBS:-1}" <<EOF
#!/bin/bash -l
#SBATCH --job-name=$EXPERIMENT_NAME
#SBATCH --partition=$GPU_PART
#SBATCH --time=$JOB_DUR
#SBATCH --nodes=$NUM_NODES
#SBATCH --gpus-per-node=$((NUM_GPUS/NUM_NODES))

set_rocm_config
py "$TARGET_FILE"
EOF
}

ps_init_colors