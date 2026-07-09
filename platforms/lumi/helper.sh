#!/usr/bin/env bash
# ============================================================
# JOB MANAGEMENT LUMI
# ============================================================
delete_lumi_job() {
  if [ -z "${1:-}" ]; then
    if [ -n "${JOB_NAME:-}" ]; then
      scancel -n "$JOB_NAME"
    else
      echo "JOB_NAME not set"
      return 1
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

watch_lumi_resources() {
  i=1
  while [ "$i" -le 60 ]; do
    clear
    squeue --me
    i=$((i + 1))
    sleep 60
  done
}

safe_name_lumi() {
  printf '%s' "$1" | sed 's#[/ ]#_#g'
}

lumi_current_log_dir() {
  repo_safe="$(safe_name_lumi "${REPO_DIR:-manual}")"
  branch_safe="$(safe_name_lumi "${BRANCH_NAME:-default}")"
  printf '%s\n' "${EXP_STORAGE_BASE}/logs/${repo_safe}/${branch_safe}"
}

lumi_log_by_rank() {
  rank="${1:-1}"
  log_dir="$(lumi_current_log_dir)"
  if ! printf '%s' "$rank" | grep -Eq '^[0-9]+$'; then
    echo "ERROR: stream rank must be a number, for example:"
    echo "  ws stream 1"
    echo "  ws stream 2"
    return 1
  fi
  find "$log_dir" -type f -name "*.log" -printf "%T@ %p\n" 2>/dev/null \
    | sort -nr \
    | awk -v r="$rank" 'NR==r {sub(/^[^ ]+ /,""); print; exit}'
}

stream_file_lumi() {
  log_file="$1"
  if [ -z "$log_file" ]; then
    echo "No log file specified."
    return 1
  fi
  if [ ! -f "$log_file" ]; then
    echo "Log file not found yet:"
    echo "$log_file"
    echo "Waiting for it..."
    while [ ! -f "$log_file" ]; do
      sleep 2
    done
  fi
  echo "Streaming:"
  echo "$log_file"
  echo "Press Ctrl+C to stop streaming; job will continue."
  echo ""
  tail -n +1 -F "$log_file"
}

stream_lumi_job_log() {
  if [ "$#" -eq 0 ]; then
    set -- 1
  fi
  for target in "$@"; do
    case "$target" in
      last)
        target=1
        ;;
      second)
        target=2
        ;;
    esac
    if [ -f "$target" ]; then
      stream_file_lumi "$target"
      continue
    fi
    if printf '%s' "$target" | grep -Eq '^[0-9]+$'; then
      # If it is a current Slurm job id, stream by job id.
      if scontrol show job "$target" >/dev/null 2>&1; then
        log_file="$(scontrol show job "$target" -o 2>/dev/null | tr ' ' '\n' | awk -F= '$1=="StdOut"{print $2}')"
        if [ -n "$log_file" ]; then
          stream_file_lumi "$log_file"
          continue
        fi
      fi
      # Otherwise treat the number as rank: 1 latest, 2 second latest, etc.
      log_file="$(lumi_log_by_rank "$target")"
      if [ -z "$log_file" ]; then
        echo "No log found for rank:"
        echo "$target"
        echo "Log directory:"
        lumi_current_log_dir
        return 1
      fi
      stream_file_lumi "$log_file"
      continue
    fi
    echo "Unknown stream target:"
    echo "$target"
    echo ""
    echo "Usage:"
    echo "  ws stream"
    echo "  ws stream 1"
    echo "  ws stream 2"
    echo "  ws stream <job_id>"
    echo "  ws stream /path/to/file.log"
    return 2
  done
}

stream_lumi_job_log_until_done() {
  job_id="$1"
  log_file="$2"
  echo ""
  echo "Submitted job: $job_id"
  echo "Log file:"
  echo "$log_file"
  echo ""
  echo "Waiting for log file..."
  while [ ! -f "$log_file" ]; do
    # Keep waiting while job is pending/running.
    if ! squeue -j "$job_id" -h >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  touch "$log_file"
  echo "Streaming log. Press Ctrl+C to stop streaming; job will continue."
  echo ""
  tail -n +1 -F "$log_file" &
  tail_pid=$!
  trap 'kill "$tail_pid" 2>/dev/null; trap - INT TERM; return 130' INT TERM
  while squeue -j "$job_id" -h >/dev/null 2>&1; do
    sleep 5
  done
  sleep 2
  kill "$tail_pid" 2>/dev/null
  wait "$tail_pid" 2>/dev/null
  trap - INT TERM
  echo ""
  echo "Job finished or left queue:"
  echo "$job_id"
  echo "Final log:"
  echo "$log_file"
}

# ============================================================
# ENVIRONMENT MANAGEMENT
# ============================================================
lumi_env_updater() {
  action="${1:-}"
  ENV_YML="${ENV_YML:-$ENV_STORAGE_BASE/files/condaenv/env_pt_rocm.yml}"
  VENV_DIR="${VENV_BASE}/${VENV_NAME}_pt"

  setup_vars() {
    export TMPDIR="${DATA_STORAGE_BASE}/tmp"
    mkdir -p "$TMPDIR"
    unset PYTHONNOUSERSITE
    export PYTHONUSERBASE="$TMPDIR/pip_userbase"
    export PIP_CACHE_DIR="$TMPDIR/pip-cache"
    mkdir -p "$PYTHONUSERBASE" "$PIP_CACHE_DIR"
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
    export HF_HOME="${DATA_STORAGE_BASE}/.cache/huggingface"
    export TRANSFORMERS_CACHE="$HF_HOME"
    export TORCH_HOME="${DATA_STORAGE_BASE}/.cache/torch"
    export WANDB_DIR="${DATA_STORAGE_BASE}/wandb"
    mkdir -p "$HF_HOME" "$TORCH_HOME" "$WANDB_DIR"
    if [ -n "${WORKSPACE_TOOLS_BIN:-}" ]; then
      case ":$PATH:" in
        *":$WORKSPACE_TOOLS_BIN:"*) ;;
        *) export PATH="$WORKSPACE_TOOLS_BIN:$PATH" ;;
      esac
    fi
  }

  load_one_module_lumi_quiet() {
    mod="$1"
    if command -v module >/dev/null 2>&1; then
      module is-loaded "$mod" >/dev/null 2>&1 && return 0
      module --silent load "$mod" >/dev/null 2>&1 && return 0
    elif command -v ml >/dev/null 2>&1; then
      ml is-loaded "$mod" >/dev/null 2>&1 && return 0
      ml --silent load "$mod" >/dev/null 2>&1 && return 0
    fi
    return 1
  }

  load_modules() {
    load_one_module_lumi_quiet "${LUMI_STACK_MODULE:-LUMI}" || true
    load_one_module_lumi_quiet "${LUMI_CONTAINER_MODULE:-lumi-container-wrapper}" || true
  }

  clean_path() {
    PATH="$(echo "$PATH" | tr ':' '\n' \
      | grep -v "$VENV_BASE" \
      | awk '!seen[$0]++' \
      | paste -sd: -)"
    export PATH
    if [ -n "${WORKSPACE_TOOLS_BIN:-}" ]; then
      case ":$PATH:" in
        *":$WORKSPACE_TOOLS_BIN:"*) ;;
        *) export PATH="$WORKSPACE_TOOLS_BIN:$PATH" ;;
      esac
    fi
  }

  activate_env() {
    clean_path
    if [ ! -x "$VENV_DIR/bin/python" ]; then
      echo "Environment not found:"
      echo "$VENV_DIR"
      echo "Run: ws env new"
      return 1
    fi
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
      activate_env || return 1
      echo "Done."
      ;;
    update)
      setup_vars
      load_modules
      clean_path
      shift
      packages="$*"
      activate_env || return 1
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
      load_modules
      activate_env
      ;;
    kernel)
      setup_vars
      load_modules
      activate_env || return 1
      python -m ipykernel install --user \
        --name venv_pt_rocm \
        --display-name "Python PyTorch ROCm"
      ;;
    check)
      setup_vars
      load_modules
      activate_env || return 1
      python - <<'PY'
import sys, site, os, platform, subprocess
print("sys.executable:", sys.executable)
print("python:", sys.version)
print("platform:", platform.platform())
print("machine:", platform.machine())
print("ENABLE_USER_SITE:", site.ENABLE_USER_SITE)
print("PYTHONNOUSERSITE:", os.environ.get("PYTHONNOUSERSITE"))
print("TMPDIR:", os.environ.get("TMPDIR"))
print("HF_HOME:", os.environ.get("HF_HOME"))
print("TORCH_HOME:", os.environ.get("TORCH_HOME"))
print("WANDB_DIR:", os.environ.get("WANDB_DIR"))
for mod in ["numpy", "pandas", "pyarrow", "datasets", "transformers"]:
    try:
        m = __import__(mod)
        print(f"{mod}:", getattr(m, "__version__", "ok"))
    except Exception as e:
        print(f"{mod} failed:", e)
try:
    import torch
    print("torch:", torch.__version__)
    print("hip:", torch.version.hip)
    print("cuda available:", torch.cuda.is_available())
    print("device count:", torch.cuda.device_count())
    if torch.cuda.is_available():
        print("device name:", torch.cuda.get_device_name(0))
except Exception as e:
    print("torch failed:", e)
for cmd in ["gh", "rclone", "azcopy"]:
    try:
        out = subprocess.check_output([cmd, "--version"], text=True, stderr=subprocess.STDOUT)
        print(f"{cmd}:", out.splitlines()[0])
    except Exception as e:
        print(f"{cmd} failed:", e)
PY
      ;;
    *)
      echo "Usage:"
      echo "  lumi_env_updater new"
      echo "  lumi_env_updater update [packages]"
      echo "  lumi_env_updater reset"
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
    C_HDR=
    C_KEY=
    C_VAL=
    C_TAG=
    C_RST=
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
  part="${GPU_PART:-small-g}"
  t="${JOB_DURH:-5 Hrs}"
  cur="$(shortpwd)"
  PS1="${C_HDR}[Dsk]${C_RST} \
P:${C_VAL}${PROJECT_USE_PCT}${C_RST} \
S:${C_VAL}${SCRATCH_USE_PCT}${C_RST}\n\
${C_HDR}[exp]${C_RST} \
P:${C_VAL}${p}${C_RST} \
E:${C_VAL}${e}${C_RST}\n\
${C_HDR}[job]${C_RST} \
J:${C_VAL}${j}${C_RST} N:${C_VAL}${n}${C_RST}  G:${C_VAL}${g}${C_RST}  P:${C_VAL}${part}${C_RST} T:${C_VAL}${t}${C_RST}\n\
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
  if command -v python >/dev/null 2>&1; then
    PYBIN_RUN="python"
  elif command -v python3 >/dev/null 2>&1; then
    PYBIN_RUN="python3"
  else
    echo "ERROR: neither python nor python3 found"
    return 1
  fi
  if [ -d "$BASE" ]; then
    PYTHONPATH="$BASE${PYTHONPATH:+:$PYTHONPATH}" "$PYBIN_RUN" "$@"
  else
    "$PYBIN_RUN" "$@"
  fi
}

# ============================================================
# ROCM CONFIG
# ============================================================
set_rocm_config() {
  export TMPDIR="${DATA_STORAGE_BASE}/tmp"
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
  export HF_HOME="${DATA_STORAGE_BASE}/.cache/huggingface"
  export TRANSFORMERS_CACHE="$HF_HOME"
  export TORCH_HOME="${DATA_STORAGE_BASE}/.cache/torch"
  export WANDB_DIR="${DATA_STORAGE_BASE}/wandb"
  export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-1}"
  export TOKENIZERS_PARALLELISM=false
  mkdir -p "$TMPDIR" "$MIOPEN_USER_DB_PATH" "$HF_HOME" "$TORCH_HOME" "$WANDB_DIR"
  if [ -n "${WORKSPACE_TOOLS_BIN:-}" ]; then
    case ":$PATH:" in
      *":$WORKSPACE_TOOLS_BIN:"*) ;;
      *) export PATH="$WORKSPACE_TOOLS_BIN:$PATH" ;;
    esac
  fi
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

set_job_conf_lumi() {
  # Usage:
  #   ws conf dev [num_jobs]        -> dev-g,      1 GPU,  short jobs
  #   ws conf small [num_jobs]      -> small-g,    1 GPU
  #   ws conf small2 [num_jobs]     -> small-g,    2 GPUs
  #   ws conf standard [num_jobs]   -> standard-g, full node (8 GPUs)
  #   ws conf gpu 3|12|24 [num_jobs] -> small-g with a custom duration
  #
  # NOTE: partition names and time limits above are LUMI defaults as of
  # writing this script; verify them against your project's actual
  # allocation policy with `sinfo` / `scontrol show partition`.
  conf="${1:-}"
  time_arg="${2:-}"
  case "$conf" in
    dev)
      export NUM_JOBS="${2:-1}"
      export NUM_NODES=1
      export NUM_GPUS=1
      export GPU_PART="dev-g"
      export JOB_DUR="0-03:00:00"
      export JOB_DURH="3 Hrs"
      ;;
    small)
      export NUM_JOBS="${2:-1}"
      export NUM_NODES=1
      export NUM_GPUS=1
      export GPU_PART="small-g"
      export JOB_DUR="0-12:00:00"
      export JOB_DURH="12 Hrs"
      ;;
    small2)
      export NUM_JOBS="${2:-1}"
      export NUM_NODES=1
      export NUM_GPUS=2
      export GPU_PART="small-g"
      export JOB_DUR="0-12:00:00"
      export JOB_DURH="12 Hrs"
      ;;
    standard)
      export NUM_JOBS="${2:-1}"
      export NUM_NODES=1
      export NUM_GPUS=8
      export GPU_PART="standard-g"
      export JOB_DUR="1-00:00:00"
      export JOB_DURH="24 Hrs"
      ;;
    gpu)
      case "$time_arg" in
        ""|3)
          export JOB_DUR="0-03:00:00"
          export JOB_DURH="3 Hrs"
          ;;
        12)
          export JOB_DUR="0-12:00:00"
          export JOB_DURH="12 Hrs"
          ;;
        24)
          export JOB_DUR="1-00:00:00"
          export JOB_DURH="24 Hrs"
          ;;
        *)
          echo "Usage:"
          echo "  ws conf gpu 3 [num_jobs]"
          echo "  ws conf gpu 12 [num_jobs]"
          echo "  ws conf gpu 24 [num_jobs]"
          return 2
          ;;
      esac
      export NUM_JOBS="${3:-1}"
      export NUM_NODES=1
      export NUM_GPUS=1
      export GPU_PART="small-g"
      ;;
    *)
      echo "Usage:"
      echo "  ws conf dev [num_jobs]"
      echo "  ws conf small [num_jobs]"
      echo "  ws conf small2 [num_jobs]"
      echo "  ws conf standard [num_jobs]"
      echo "  ws conf gpu 3|12|24 [num_jobs]"
      return 2
      ;;
  esac
  set_ps
}

create_job_with_slurm_lumi() {
  default_job_conf_lumi
  TARGET_FILE="$1"
  shift || true
  TARGET_ARGS=("$@")
  if [ -z "$TARGET_FILE" ]; then
    echo "Usage:"
    echo "  ws run <file.py> [args...]"
    echo ""
    echo "Example:"
    echo "  ws run engine.py arg1 arg2"
    return 2
  fi
  if [ ! -f "$TARGET_FILE" ]; then
    echo "ERROR: file not found:"
    echo "$TARGET_FILE"
    return 1
  fi
  submit_dir="$PWD"
  repo_safe="$(safe_name_lumi "${REPO_DIR:-manual}")"
  branch_safe="$(safe_name_lumi "${BRANCH_NAME:-default}")"
  if [ -n "${REPO_DIR:-}" ] && [ -n "${BRANCH_NAME:-}" ]; then
    EXPERIMENT_NAME="${REPO_DIR}_${BRANCH_NAME}"
  else
    EXPERIMENT_NAME="$(basename "$TARGET_FILE" .py)"
  fi
  LOG_DIR="${EXP_STORAGE_BASE}/logs/${repo_safe}/${branch_safe}"
  mkdir -p "$LOG_DIR"
  timestamp="$(date +%Y%m%d_%H%M%S)"
  target_base="$(basename "$TARGET_FILE" .py)"
  LOG_FILE="${LOG_DIR}/${target_base}_${timestamp}.log"
  run_cmd=(py "$TARGET_FILE" "${TARGET_ARGS[@]}")
  printf -v run_cmd_quoted '%q ' "${run_cmd[@]}"
  echo "Submitting job:"
  echo "  file: $TARGET_FILE"
  echo "  args: ${TARGET_ARGS[*]:-}"
  echo "  log : $LOG_FILE"
  sbatch_output="$(sbatch --parsable --array="1-${NUM_JOBS:-1}" <<EOF
#!/bin/bash -l
#SBATCH --account=$SBATCH_ACCOUNT
#SBATCH --job-name=$EXPERIMENT_NAME
#SBATCH --partition=$GPU_PART
#SBATCH --time=$JOB_DUR
#SBATCH --nodes=$NUM_NODES
#SBATCH --gpus-per-node=$((NUM_GPUS/NUM_NODES))
#SBATCH --output=$LOG_FILE
#SBATCH --error=$LOG_FILE
#SBATCH --open-mode=append
echo "============================================================"
echo "Job started"
echo "Job ID: \${SLURM_JOB_ID}"
echo "Array task ID: \${SLURM_ARRAY_TASK_ID:-none}"
echo "Node: \$(hostname)"
echo "Submit dir: $submit_dir"
echo "Time: \$(date)"
echo "Command: $run_cmd_quoted"
echo "============================================================"
cd "$submit_dir" || exit 1
source "$ENV_STORAGE_BASE/platforms/lumi/main.sh"
set_rocm_config
$run_cmd_quoted
exit_code=\$?
echo "============================================================"
echo "Job finished"
echo "Exit code: \$exit_code"
echo "Time: \$(date)"
echo "============================================================"
exit \$exit_code
EOF
)"
  job_id="${sbatch_output%%;*}"
  if [ -z "$job_id" ]; then
    echo "ERROR: sbatch did not return a job id"
    echo "$sbatch_output"
    return 1
  fi
  stream_lumi_job_log_until_done "$job_id" "$LOG_FILE"
}

create_wandb_sweep_job_with_slurm_lumi() {
  default_job_conf_lumi
  SWEEP_ID="$1"
  if [ -z "$SWEEP_ID" ]; then
    echo "Usage: ws sweep wandb <entity/project/sweep_id>"
    return 2
  fi
  repo_safe="$(safe_name_lumi "${REPO_DIR:-manual}")"
  branch_safe="$(safe_name_lumi "${BRANCH_NAME:-default}")"
  LOG_DIR="${EXP_STORAGE_BASE}/logs/${repo_safe}/${branch_safe}"
  mkdir -p "$LOG_DIR"
  timestamp="$(date +%Y%m%d_%H%M%S)"
  LOG_FILE="${LOG_DIR}/wandb_sweep_${timestamp}.log"
  sbatch_output="$(sbatch --parsable --array="1-${NUM_JOBS:-1}" <<EOF
#!/bin/bash -l
#SBATCH --account=$SBATCH_ACCOUNT
#SBATCH --job-name=wandb_sweep
#SBATCH --partition=$GPU_PART
#SBATCH --time=$JOB_DUR
#SBATCH --nodes=$NUM_NODES
#SBATCH --gpus-per-node=$((NUM_GPUS/NUM_NODES))
#SBATCH --output=$LOG_FILE
#SBATCH --error=$LOG_FILE
#SBATCH --open-mode=append
source "$ENV_STORAGE_BASE/platforms/lumi/main.sh"
set_rocm_config
wandb agent "$SWEEP_ID"
EOF
)"
  job_id="${sbatch_output%%;*}"
  if [ -z "$job_id" ]; then
    echo "ERROR: sbatch did not return a job id"
    echo "$sbatch_output"
    return 1
  fi
  stream_lumi_job_log_until_done "$job_id" "$LOG_FILE"
}

ps_init_colors