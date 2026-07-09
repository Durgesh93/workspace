#!/usr/bin/env bash

# ============================================================
# JOB MANAGEMENT OLIVIA
# ============================================================
delete_olivia_job() {
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

watch_olivia_resources() {
  i=1
  while [ "$i" -le 60 ]; do
    clear
    squeue --me
    i=$((i + 1))
    sleep 60
  done
}

safe_name_olivia() {
  printf '%s' "$1" | sed 's#[/ ]#_#g'
}

olivia_current_log_dir() {
  repo_safe="$(safe_name_olivia "${REPO_DIR:-manual}")"
  branch_safe="$(safe_name_olivia "${BRANCH_NAME:-default}")"

  printf '%s\n' "${EXP_STORAGE_BASE}/logs/${repo_safe}/${branch_safe}"
}

olivia_log_by_rank() {
  rank="${1:-1}"
  log_dir="$(olivia_current_log_dir)"

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

stream_file_olivia() {
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

stream_olivia_job_log() {
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
      stream_file_olivia "$target"
      continue
    fi

    if printf '%s' "$target" | grep -Eq '^[0-9]+$'; then
      # If it is a current Slurm job id, stream by job id.
      if scontrol show job "$target" >/dev/null 2>&1; then
        log_file="$(scontrol show job "$target" -o 2>/dev/null | tr ' ' '\n' | awk -F= '$1=="StdOut"{print $2}')"

        if [ -n "$log_file" ]; then
          stream_file_olivia "$log_file"
          continue
        fi
      fi

      # Otherwise treat the number as rank: 1 latest, 2 second latest, etc.
      log_file="$(olivia_log_by_rank "$target")"

      if [ -z "$log_file" ]; then
        echo "No log found for rank:"
        echo "$target"
        echo "Log directory:"
        olivia_current_log_dir
        return 1
      fi

      stream_file_olivia "$log_file"
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

stream_olivia_job_log_until_done() {
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
olivia_env_updater() {
  action="${1:-}"

  ENV_YML="${ENV_YML:-$ENV_STORAGE_BASE/files/env_cuda.yml}"
  VENV_DIR="${VENV_BASE}/${VENV_NAME}_${ENV_TYPE}"

  setup_vars() {
    export http_proxy="http://10.63.2.48:3128/"
    export https_proxy="http://10.63.2.48:3128/"
    export HTTP_PROXY="$http_proxy"
    export HTTPS_PROXY="$https_proxy"

    export TMPDIR="${DATA_STORAGE_BASE}/tmp"
    mkdir -p "$TMPDIR"

    unset PYTHONNOUSERSITE
    export PYTHONUSERBASE="$TMPDIR/pip_userbase"
    export PIP_CACHE_DIR="$TMPDIR/pip-cache"

    mkdir -p "$PYTHONUSERBASE" "$PIP_CACHE_DIR"

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

  init_modules() {
    if ! command -v module >/dev/null 2>&1 && ! command -v ml >/dev/null 2>&1; then
      [[ -f /etc/profile.d/lmod.sh ]] && source /etc/profile.d/lmod.sh
      [[ -f /usr/share/lmod/lmod/init/bash ]] && source /usr/share/lmod/lmod/init/bash
      [[ -f /cluster/software/Modules/init/bash ]] && source /cluster/software/Modules/init/bash
    fi
  }

  load_one_module_quiet() {
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
    init_modules

    load_one_module_quiet "${OLIVIA_STACK_MODULE:-NRIS/GPU}" || true

    # Only load Python module when creating a new venv.
    if [ "$action" = "new" ] && [ -n "${OLIVIA_PYTHON_MODULE:-}" ]; then
      load_one_module_quiet "$OLIVIA_PYTHON_MODULE" || {
        echo "WARNING: Could not load $OLIVIA_PYTHON_MODULE"
        echo "Try:"
        echo "  module spider $OLIVIA_PYTHON_MODULE"
      }
    fi
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

  get_python_bin() {
    if command -v python3 >/dev/null 2>&1; then
      PYBIN="python3"
    elif command -v python >/dev/null 2>&1; then
      PYBIN="python"
    else
      echo "ERROR: neither python3 nor python found"
      return 1
    fi

    export PYBIN
  }

  check_python_version_for_new_env() {
    get_python_bin || return 1

    PYVER="$("$PYBIN" - <<'PY'
import sys
print(f"{sys.version_info.major}.{sys.version_info.minor}")
PY
)"

    case "$PYVER" in
      3.10|3.11|3.12|3.13|3.14)
        echo "Using $PYBIN Python $PYVER"
        ;;
      *)
        echo "ERROR: Refusing to create venv with Python $PYVER"
        echo ""
        echo "Current python:"
        which "$PYBIN"
        "$PYBIN" --version
        echo ""
        echo "Load a newer Python module first:"
        echo "  module reset"
        echo "  module load NRIS/GPU"
        echo "  module avail Python"
        return 1
        ;;
    esac
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

  extract_pip_from_env_yml() {
    tmp_req="$1"

    awk '
      BEGIN {in_pip=0}
      /^[[:space:]]*- pip:/ {
        in_pip=1
        next
      }
      in_pip==1 && /^[[:space:]]*-[[:space:]]/ {
        line=$0
        sub(/^[[:space:]]*-[[:space:]]*/, "", line)
        gsub(/^["'\'']|["'\'']$/, "", line)
        if (line != "" && line !~ /^pip$/) print line
        next
      }
      in_pip==1 && /^[^[:space:]]/ {
        in_pip=0
      }
    ' "$ENV_YML" > "$tmp_req"
  }

  install_from_env_yml_with_pip() {
    if [ ! -f "$ENV_YML" ]; then
      echo "Environment YAML not found:"
      echo "$ENV_YML"
      return 0
    fi

    echo "Using environment YAML:"
    echo "$ENV_YML"

    tmp_req="$(mktemp /tmp/olivia_pip_requirements.XXXXXX.txt)"
    extract_pip_from_env_yml "$tmp_req"

    if [ -s "$tmp_req" ]; then
      echo "Installing pip dependencies extracted from env_cuda.yml:"
      cat "$tmp_req"

      python -m pip install -r "$tmp_req" || {
        rm -f "$tmp_req"
        return 1
      }
    else
      echo "No pip section found in env_cuda.yml."
      echo "No extra pip packages installed from YAML."
    fi

    rm -f "$tmp_req"
  }

  case "$action" in

    new)
      setup_vars
      load_modules
      clean_path

      echo "Creating fresh Python environment:"
      echo "$VENV_DIR"

      if [ -d "$VENV_DIR" ]; then
        echo "Removing existing environment:"
        echo "$VENV_DIR"
        rm -rf "$VENV_DIR"
      fi

      check_python_version_for_new_env || return 1

      mkdir -p "$(dirname "$VENV_DIR")"

      "$PYBIN" -m venv "$VENV_DIR" || return 1

      setup_vars
      activate_env || return 1

      python -m pip install --upgrade pip setuptools wheel || return 1
      install_from_env_yml_with_pip || return 1

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
        python -m pip install -U $packages || return 1
      else
        install_from_env_yml_with_pip || return 1
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
        --name venv_pt_olivia \
        --display-name "Python PyTorch Olivia"
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
print("http_proxy:", os.environ.get("http_proxy"))
print("https_proxy:", os.environ.get("https_proxy"))
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
    print("cuda available:", torch.cuda.is_available())
    print("cuda version:", torch.version.cuda)
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
      echo "  olivia_env_updater new"
      echo "  olivia_env_updater update [packages]"
      echo "  olivia_env_updater reset"
      echo "  olivia_env_updater kernel"
      echo "  olivia_env_updater check"
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
# PROMPT
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

set_ps_olivia() {
  p="${REPO_DIR:-None}"
  e="${BRANCH_NAME:-None}"

  j="${NUM_JOBS:-1}"
  n="${NUM_NODES:-1}"
  c="${NUM_CPUS:-4}"
  g="${NUM_GPUS:-0}"
  part="${JOB_TYPE:-small}"
  t="${JOB_DURH:-5 Hrs}"

  cur="$(shortpwd)"

  PS1="${C_HDR}[Dsk]${C_RST} \
H:${C_VAL}${HOME_USE_PCT}${C_RST} \
P:${C_VAL}${PROJECT_USE_PCT}${C_RST} \
W:${C_VAL}${WORK_USE_PCT}${C_RST}\n\
${C_HDR}[exp]${C_RST} \
P:${C_VAL}${p}${C_RST} \
E:${C_VAL}${e}${C_RST}\n\
${C_HDR}[job]${C_RST} \
J:${C_VAL}${j}${C_RST} N:${C_VAL}${n}${C_RST}  C:${C_VAL}${c}${C_RST}  G:${C_VAL}${g}${C_RST}  P:${C_VAL}${part}${C_RST} T:${C_VAL}${t}${C_RST}\n\
${C_TAG}[$ENVIRONMENT]${C_RST} ${cur} $ "

  export PS1
}

cd() {
  command cd "$@" || return
  set_ps_olivia
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
# GPU CONFIG
# ============================================================
set_gpu_config_olivia() {
  export http_proxy="http://10.63.2.48:3128/"
  export https_proxy="http://10.63.2.48:3128/"
  export HTTP_PROXY="$http_proxy"
  export HTTPS_PROXY="$https_proxy"

  export TMPDIR="${DATA_STORAGE_BASE}/tmp"
  mkdir -p "$TMPDIR"

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

  export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-1}"
  export TOKENIZERS_PARALLELISM=false
}

# ============================================================
# JOB CONFIG + SUBMISSION
# ============================================================
default_job_conf_olivia() {
  : "${NUM_JOBS:=1}"
  : "${NUM_NODES:=1}"
  : "${NUM_CPUS:=4}"
  : "${NUM_GPUS:=0}"
  : "${JOB_TYPE:=small}"
  : "${JOB_DUR:=0-05:00:00}"
  : "${JOB_DURH:=5 Hrs}"
  : "${MEM_PER_CPU:=4G}"

  export NUM_JOBS NUM_NODES NUM_CPUS NUM_GPUS JOB_TYPE JOB_DUR JOB_DURH MEM_PER_CPU
}

set_job_conf_olivia() {
  # Usage:
  #   ws conf gpu5 [num_jobs]
  #   ws conf gpu10 [num_jobs]
  #   ws conf gpu20 [num_jobs]
  #   ws conf gpu2_5 [num_jobs]
  #   ws conf gpu2_10 [num_jobs]
  #   ws conf gpu2_20 [num_jobs]
  #
  # Also supported:
  #   ws conf gpu 5 [num_jobs]
  #   ws conf gpu 10 [num_jobs]
  #   ws conf gpu 20 [num_jobs]
  #   ws conf gpu2 5 [num_jobs]
  #   ws conf gpu2 10 [num_jobs]
  #   ws conf gpu2 20 [num_jobs]

  conf="${1:-}"
  time_arg="${2:-}"
  jobs_arg="${3:-1}"

  case "$conf" in

    # --------------------------------------------------------
    # 1 GPU presets
    # --------------------------------------------------------
    gpu5)
      export NUM_JOBS="${2:-1}"
      export NUM_NODES=1
      export NUM_CPUS=8
      export NUM_GPUS=1
      export JOB_TYPE="accel"
      export JOB_DUR="0-05:00:00"
      export JOB_DURH="5 Hrs"
      export MEM_PER_CPU="8G"
      ;;

    gpu10)
      export NUM_JOBS="${2:-1}"
      export NUM_NODES=1
      export NUM_CPUS=8
      export NUM_GPUS=1
      export JOB_TYPE="accel"
      export JOB_DUR="0-10:00:00"
      export JOB_DURH="10 Hrs"
      export MEM_PER_CPU="8G"
      ;;

    gpu20)
      export NUM_JOBS="${2:-1}"
      export NUM_NODES=1
      export NUM_CPUS=8
      export NUM_GPUS=1
      export JOB_TYPE="accel"
      export JOB_DUR="0-20:00:00"
      export JOB_DURH="20 Hrs"
      export MEM_PER_CPU="8G"
      ;;

    # --------------------------------------------------------
    # 2 GPU presets
    # --------------------------------------------------------
    gpu2_5|gpu2-5)
      export NUM_JOBS="${2:-1}"
      export NUM_NODES=1
      export NUM_CPUS=16
      export NUM_GPUS=2
      export JOB_TYPE="accel"
      export JOB_DUR="0-05:00:00"
      export JOB_DURH="5 Hrs"
      export MEM_PER_CPU="8G"
      ;;

    gpu2_10|gpu2-10)
      export NUM_JOBS="${2:-1}"
      export NUM_NODES=1
      export NUM_CPUS=16
      export NUM_GPUS=2
      export JOB_TYPE="accel"
      export JOB_DUR="0-10:00:00"
      export JOB_DURH="10 Hrs"
      export MEM_PER_CPU="8G"
      ;;

    gpu2_20|gpu2-20)
      export NUM_JOBS="${2:-1}"
      export NUM_NODES=1
      export NUM_CPUS=16
      export NUM_GPUS=2
      export JOB_TYPE="accel"
      export JOB_DUR="0-20:00:00"
      export JOB_DURH="20 Hrs"
      export MEM_PER_CPU="8G"
      ;;

    # --------------------------------------------------------
    # Dynamic style: ws conf gpu 5 / gpu 10 / gpu 20
    # --------------------------------------------------------
    gpu)
      case "$time_arg" in
        ""|5)
          export JOB_DUR="0-05:00:00"
          export JOB_DURH="5 Hrs"
          export NUM_JOBS="${3:-1}"
          ;;
        10)
          export JOB_DUR="0-10:00:00"
          export JOB_DURH="10 Hrs"
          export NUM_JOBS="${3:-1}"
          ;;
        20)
          export JOB_DUR="0-20:00:00"
          export JOB_DURH="20 Hrs"
          export NUM_JOBS="${3:-1}"
          ;;
        *)
          echo "Usage:"
          echo "  ws conf gpu 5 [num_jobs]"
          echo "  ws conf gpu 10 [num_jobs]"
          echo "  ws conf gpu 20 [num_jobs]"
          return 2
          ;;
      esac

      export NUM_NODES=1
      export NUM_CPUS=8
      export NUM_GPUS=1
      export JOB_TYPE="accel"
      export MEM_PER_CPU="8G"
      ;;

    # --------------------------------------------------------
    # Dynamic style: ws conf gpu2 5 / gpu2 10 / gpu2 20
    # --------------------------------------------------------
    gpu2)
      case "$time_arg" in
        ""|5)
          export JOB_DUR="0-05:00:00"
          export JOB_DURH="5 Hrs"
          export NUM_JOBS="${3:-1}"
          ;;
        10)
          export JOB_DUR="0-10:00:00"
          export JOB_DURH="10 Hrs"
          export NUM_JOBS="${3:-1}"
          ;;
        20)
          export JOB_DUR="0-20:00:00"
          export JOB_DURH="20 Hrs"
          export NUM_JOBS="${3:-1}"
          ;;
        *)
          echo "Usage:"
          echo "  ws conf gpu2 5 [num_jobs]"
          echo "  ws conf gpu2 10 [num_jobs]"
          echo "  ws conf gpu2 20 [num_jobs]"
          return 2
          ;;
      esac

      export NUM_NODES=1
      export NUM_CPUS=16
      export NUM_GPUS=2
      export JOB_TYPE="accel"
      export MEM_PER_CPU="8G"
      ;;

    # --------------------------------------------------------
    # CPU presets
    # --------------------------------------------------------
    cpu|small)
      export NUM_JOBS="${2:-1}"
      export NUM_NODES=1
      export NUM_CPUS=4
      export NUM_GPUS=0
      export JOB_TYPE="small"
      export JOB_DUR="0-05:00:00"
      export JOB_DURH="5 Hrs"
      export MEM_PER_CPU="4G"
      ;;

    large)
      export NUM_JOBS="${2:-1}"
      export NUM_NODES=1
      export NUM_CPUS=32
      export NUM_GPUS=0
      export JOB_TYPE="large"
      export JOB_DUR="0-12:00:00"
      export JOB_DURH="12 Hrs"
      export MEM_PER_CPU="4G"
      ;;

    devel)
      export NUM_JOBS="${2:-1}"
      export NUM_NODES=1
      export NUM_CPUS=4
      export NUM_GPUS=0
      export JOB_TYPE="devel"
      export JOB_DUR="0-02:00:00"
      export JOB_DURH="2 Hrs"
      export MEM_PER_CPU="4G"
      ;;

    *)
      echo "Usage:"
      echo "  ws conf gpu5 [num_jobs]"
      echo "  ws conf gpu10 [num_jobs]"
      echo "  ws conf gpu20 [num_jobs]"
      echo ""
      echo "  ws conf gpu2_5 [num_jobs]"
      echo "  ws conf gpu2_10 [num_jobs]"
      echo "  ws conf gpu2_20 [num_jobs]"
      echo ""
      echo "  ws conf gpu 5 [num_jobs]"
      echo "  ws conf gpu 10 [num_jobs]"
      echo "  ws conf gpu 20 [num_jobs]"
      echo ""
      echo "  ws conf gpu2 5 [num_jobs]"
      echo "  ws conf gpu2 10 [num_jobs]"
      echo "  ws conf gpu2 20 [num_jobs]"
      echo ""
      echo "  ws conf cpu [num_jobs]"
      echo "  ws conf large [num_jobs]"
      echo "  ws conf devel [num_jobs]"
      return 2
      ;;
  esac

  set_ps_olivia
}


create_job_with_slurm_olivia() {
  default_job_conf_olivia

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

  repo_safe="$(safe_name_olivia "${REPO_DIR:-manual}")"
  branch_safe="$(safe_name_olivia "${BRANCH_NAME:-default}")"

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

  GPU_LINE=""
  if [ "${NUM_GPUS:-0}" -gt 0 ]; then
    GPU_LINE="#SBATCH --gpus=${NUM_GPUS}"
  fi

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
#SBATCH --partition=$JOB_TYPE
#SBATCH --time=$JOB_DUR
#SBATCH --nodes=$NUM_NODES
#SBATCH --cpus-per-task=$NUM_CPUS
#SBATCH --mem-per-cpu=$MEM_PER_CPU
#SBATCH --output=$LOG_FILE
#SBATCH --error=$LOG_FILE
#SBATCH --open-mode=append
${GPU_LINE}

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

source "$ENV_STORAGE_BASE/platforms/olivia/main.sh"

set_gpu_config_olivia

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

  stream_olivia_job_log_until_done "$job_id" "$LOG_FILE"
}

create_wandb_sweep_job_with_slurm_olivia() {
  default_job_conf_olivia

  SWEEP_ID="$1"

  if [ -z "$SWEEP_ID" ]; then
    echo "Usage: ws sweep wandb <entity/project/sweep_id>"
    return 2
  fi

  repo_safe="$(safe_name_olivia "${REPO_DIR:-manual}")"
  branch_safe="$(safe_name_olivia "${BRANCH_NAME:-default}")"

  LOG_DIR="${EXP_STORAGE_BASE}/logs/${repo_safe}/${branch_safe}"
  mkdir -p "$LOG_DIR"

  timestamp="$(date +%Y%m%d_%H%M%S)"
  LOG_FILE="${LOG_DIR}/wandb_sweep_${timestamp}.log"

  GPU_LINE=""
  if [ "${NUM_GPUS:-0}" -gt 0 ]; then
    GPU_LINE="#SBATCH --gpus=${NUM_GPUS}"
  fi

  sbatch_output="$(sbatch --parsable --array="1-${NUM_JOBS:-1}" <<EOF
#!/bin/bash -l
#SBATCH --account=$SBATCH_ACCOUNT
#SBATCH --job-name=wandb_sweep
#SBATCH --partition=$JOB_TYPE
#SBATCH --time=$JOB_DUR
#SBATCH --nodes=$NUM_NODES
#SBATCH --cpus-per-task=$NUM_CPUS
#SBATCH --mem-per-cpu=$MEM_PER_CPU
#SBATCH --output=$LOG_FILE
#SBATCH --error=$LOG_FILE
#SBATCH --open-mode=append
${GPU_LINE}

source "$ENV_STORAGE_BASE/platforms/olivia/main.sh"

set_gpu_config_olivia
wandb agent "$SWEEP_ID"
EOF
)"

  job_id="${sbatch_output%%;*}"

  if [ -z "$job_id" ]; then
    echo "ERROR: sbatch did not return a job id"
    echo "$sbatch_output"
    return 1
  fi

  stream_olivia_job_log_until_done "$job_id" "$LOG_FILE"
}

ps_init_colors

