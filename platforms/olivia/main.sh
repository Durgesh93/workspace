#!/usr/bin/env bash

# ============================================================
# ENVIRONMENT SETUP (OLIVIA)
# ============================================================
export ENVIRONMENT="olivia"
export SBATCH_ACCOUNT="nn8104k"

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

export DATA_STORAGE_BASE="/cluster/work/projects/${SBATCH_ACCOUNT}/${USER_NAME}"
export ENV_STORAGE_BASE="${DATA_STORAGE_BASE}/envs/workspace"
export VENV_BASE="${DATA_STORAGE_BASE}/envbase"
export PROJ_STORAGE_BASE="${DATA_STORAGE_BASE}/projects"
export EXP_STORAGE_BASE="${DATA_STORAGE_BASE}/experiment_storage"

export TMPDIR="${DATA_STORAGE_BASE}/tmp"
export ENV_YML="${ENV_STORAGE_BASE}/files/env_cuda.yml"

export HOME_USE_PCT="$(df /cluster/home/$USER_NAME --output=pcent 2>/dev/null | tail -n 1 | tr -d ' ')"
export WORK_USE_PCT="$(df /cluster/work/projects/$SBATCH_ACCOUNT --output=pcent 2>/dev/null | tail -n 1 | tr -d ' ')"
export PROJECT_USE_PCT="$WORK_USE_PCT"

mkdir -p "$ENV_STORAGE_BASE"
mkdir -p "$ENV_STORAGE_BASE/platforms/olivia"
mkdir -p "$ENV_STORAGE_BASE/files"
mkdir -p "$ENV_STORAGE_BASE/programs/linux"
mkdir -p "$VENV_BASE"
mkdir -p "$PROJ_STORAGE_BASE"
mkdir -p "$EXP_STORAGE_BASE"
mkdir -p "$TMPDIR"

# ============================================================
# MODULE INIT + LOAD
# ============================================================
if ! command -v module >/dev/null 2>&1 && ! command -v ml >/dev/null 2>&1; then
  [[ -f /etc/profile.d/lmod.sh ]] && source /etc/profile.d/lmod.sh
  [[ -f /usr/share/lmod/lmod/init/bash ]] && source /usr/share/lmod/lmod/init/bash
  [[ -f /cluster/software/Modules/init/bash ]] && source /cluster/software/Modules/init/bash
fi

load_module_olivia_quiet() {
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

export OLIVIA_STACK_MODULE="${OLIVIA_STACK_MODULE:-NRIS/GPU}"
export OLIVIA_PYTHON_MODULE="${OLIVIA_PYTHON_MODULE:-Python/3.11.5-GCCcore-13.2.0}"

# Quietly load stack only. Python module is loaded only by helper.sh during ws env new.
load_module_olivia_quiet "$OLIVIA_STACK_MODULE" || true

# ============================================================
# WORKSPACE LINUX TOOLS
# ============================================================
export WORKSPACE_LINUX_PROGRAMS="$ENV_STORAGE_BASE/programs/linux"
export WORKSPACE_TOOLS_BIN="$WORKSPACE_LINUX_PROGRAMS"

mkdir -p "$WORKSPACE_LINUX_PROGRAMS"

case ":$PATH:" in
  *":$WORKSPACE_TOOLS_BIN:"*) ;;
  *) export PATH="$WORKSPACE_TOOLS_BIN:$PATH" ;;
esac

workspace_download_file() {
  url="$1"
  out="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -L --fail "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$out" "$url"
  elif command -v python >/dev/null 2>&1; then
    python - "$url" "$out" <<'PY'
import sys
import urllib.request
urllib.request.urlretrieve(sys.argv[1], sys.argv[2])
PY
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$url" "$out" <<'PY'
import sys
import urllib.request
urllib.request.urlretrieve(sys.argv[1], sys.argv[2])
PY
  else
    echo "ERROR: no curl, wget, python, or python3 available for download"
    return 1
  fi
}

workspace_python_cmd() {
  if command -v python >/dev/null 2>&1; then
    echo "python"
  elif command -v python3 >/dev/null 2>&1; then
    echo "python3"
  else
    return 1
  fi
}

workspace_tool_arch() {
  case "$(uname -m)" in
    aarch64|arm64) echo "arm64" ;;
    x86_64|amd64) echo "amd64" ;;
    *)
      echo "ERROR: unsupported architecture: $(uname -m)"
      return 1
      ;;
  esac
}

install_gh_workspace() {
  [ -x "$WORKSPACE_TOOLS_BIN/gh" ] && return 0

  arch="$(workspace_tool_arch)" || return 1
  pycmd="$(workspace_python_cmd)" || return 1

  case "$arch" in
    arm64) gh_asset="linux_arm64.tar.gz" ;;
    amd64) gh_asset="linux_amd64.tar.gz" ;;
  esac

  echo "Installing gh into $WORKSPACE_TOOLS_BIN"

  tmp_dir="$(mktemp -d /tmp/gh_install.XXXXXX)"

  gh_url="$("$pycmd" - "$gh_asset" <<'PY'
import json
import sys
import urllib.request

asset = sys.argv[1]
url = "https://api.github.com/repos/cli/cli/releases/latest"

with urllib.request.urlopen(url) as r:
    data = json.load(r)

for a in data["assets"]:
    if asset in a["name"]:
        print(a["browser_download_url"])
        break
else:
    raise SystemExit(f"No gh asset found for {asset}")
PY
)" || {
    rm -rf "$tmp_dir"
    return 1
  }

  workspace_download_file "$gh_url" "$tmp_dir/gh.tar.gz" || {
    rm -rf "$tmp_dir"
    return 1
  }

  tar -xzf "$tmp_dir/gh.tar.gz" -C "$tmp_dir" || {
    rm -rf "$tmp_dir"
    return 1
  }

  gh_src="$(find "$tmp_dir" -type f -path '*/bin/gh' | head -n 1)"

  if [ -z "$gh_src" ]; then
    echo "ERROR: gh binary not found"
    rm -rf "$tmp_dir"
    return 1
  fi

  rm -f "$WORKSPACE_TOOLS_BIN/gh"
  cp "$gh_src" "$WORKSPACE_TOOLS_BIN/gh"
  chmod +x "$WORKSPACE_TOOLS_BIN/gh"

  rm -rf "$tmp_dir"
}

install_rclone_workspace() {
  [ -x "$WORKSPACE_TOOLS_BIN/rclone" ] && return 0

  arch="$(workspace_tool_arch)" || return 1
  pycmd="$(workspace_python_cmd)" || return 1

  case "$arch" in
    arm64) rclone_arch="arm64" ;;
    amd64) rclone_arch="amd64" ;;
  esac

  echo "Installing rclone into $WORKSPACE_TOOLS_BIN"

  tmp_dir="$(mktemp -d /tmp/rclone_install.XXXXXX)"
  rclone_url="https://downloads.rclone.org/rclone-current-linux-${rclone_arch}.zip"

  workspace_download_file "$rclone_url" "$tmp_dir/rclone.zip" || {
    rm -rf "$tmp_dir"
    return 1
  }

  if command -v unzip >/dev/null 2>&1; then
    unzip -q "$tmp_dir/rclone.zip" -d "$tmp_dir" || {
      rm -rf "$tmp_dir"
      return 1
    }
  else
    "$pycmd" - "$tmp_dir/rclone.zip" "$tmp_dir" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as z:
    z.extractall(sys.argv[2])
PY
  fi

  rclone_src="$(find "$tmp_dir" -type f -name rclone | head -n 1)"

  if [ -z "$rclone_src" ]; then
    echo "ERROR: rclone binary not found"
    rm -rf "$tmp_dir"
    return 1
  fi

  rm -f "$WORKSPACE_TOOLS_BIN/rclone"
  cp "$rclone_src" "$WORKSPACE_TOOLS_BIN/rclone"
  chmod +x "$WORKSPACE_TOOLS_BIN/rclone"

  rm -rf "$tmp_dir"
}

install_azcopy_workspace() {
  [ -x "$WORKSPACE_TOOLS_BIN/azcopy" ] && return 0

  arch="$(workspace_tool_arch)" || return 1

  case "$arch" in
    arm64) azcopy_url="https://aka.ms/downloadazcopy-v10-linux-arm64" ;;
    amd64) azcopy_url="https://aka.ms/downloadazcopy-v10-linux" ;;
  esac

  echo "Installing azcopy into $WORKSPACE_TOOLS_BIN"

  tmp_dir="$(mktemp -d /tmp/azcopy_install.XXXXXX)"

  workspace_download_file "$azcopy_url" "$tmp_dir/azcopy.tar.gz" || {
    rm -rf "$tmp_dir"
    return 1
  }

  tar -xzf "$tmp_dir/azcopy.tar.gz" -C "$tmp_dir" || {
    rm -rf "$tmp_dir"
    return 1
  }

  azcopy_src="$(find "$tmp_dir" -type f -name azcopy | head -n 1)"

  if [ -z "$azcopy_src" ]; then
    echo "ERROR: azcopy binary not found"
    rm -rf "$tmp_dir"
    return 1
  fi

  rm -f "$WORKSPACE_TOOLS_BIN/azcopy"
  cp "$azcopy_src" "$WORKSPACE_TOOLS_BIN/azcopy"
  chmod +x "$WORKSPACE_TOOLS_BIN/azcopy"

  rm -rf "$tmp_dir"
}

install_workspace_linux_tools() {
  # Remove old bin folder from previous versions. No symlinks.
  rm -rf "$WORKSPACE_LINUX_PROGRAMS/bin"

  install_gh_workspace || echo "WARNING: gh install failed"
  install_rclone_workspace || echo "WARNING: rclone install failed"
  install_azcopy_workspace || echo "WARNING: azcopy install failed"

  hash -r 2>/dev/null || true
}

install_workspace_linux_tools

# ============================================================
# SLURM + GPU DETECTION
# ============================================================
is_slurm_session=false
[[ -n "${SLURM_JOB_ID:-}" ]] && is_slurm_session=true

has_gpu=false

if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi -L >/dev/null 2>&1 && has_gpu=true
fi

if $is_slurm_session && [[ -n "${SLURM_GPUS:-}${SLURM_JOB_GPUS:-}${SLURM_GPUS_ON_NODE:-}${CUDA_VISIBLE_DEVICES:-}" ]]; then
  has_gpu=true
fi

export OLIVIA_STACK="CPU"
if $is_slurm_session && $has_gpu; then
  export OLIVIA_STACK="GPU"
fi

# ============================================================
# OPTIONAL HELPERS
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

if command -v python >/dev/null 2>&1; then
  export PYTHONPATH="$(python -c 'import site; print(site.getusersitepackages())' 2>/dev/null):$ENV_STORAGE_BASE/programs/pymods"
elif command -v python3 >/dev/null 2>&1; then
  export PYTHONPATH="$(python3 -c 'import site; print(site.getusersitepackages())' 2>/dev/null):$ENV_STORAGE_BASE/programs/pymods"
else
  export PYTHONPATH="$ENV_STORAGE_BASE/programs/pymods"
fi

# Cache locations
export HF_HOME="${DATA_STORAGE_BASE}/.cache/huggingface"
export TRANSFORMERS_CACHE="$HF_HOME"
export TORCH_HOME="${DATA_STORAGE_BASE}/.cache/torch"
export WANDB_DIR="${DATA_STORAGE_BASE}/wandb"

mkdir -p "$HF_HOME" "$TORCH_HOME" "$WANDB_DIR"

# ============================================================
# GIT CONFIG
# ============================================================
git config --global user.name "durgesh.olivia"
git config --global user.email "durgesh080793@gmail.com.olivia"

# ============================================================
# ALIASES
# ============================================================
alias conf_selector='set_job_conf_olivia'
alias job_runner='create_job_with_slurm_olivia'
alias job_streamer='stream_olivia_job_log'
alias job_watcher='watch_olivia_resources'
alias job_deleter='delete_olivia_job'
alias job_logger='stream_olivia_job_log'

alias set_ps='set_ps_olivia'
alias env_updater='olivia_env_updater'
alias ws='workspace_helper'
alias wandb_sweep='ws sweep wandb'

# ============================================================
# LOCALE
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
  shift || true

  case "$sub" in
    watch)  watch_olivia_resources "$@" ;;
    del)    delete_olivia_job "$@" ;;
    logs)   stream_olivia_job_log "$@" ;;
    stream) stream_olivia_job_log "$@" ;;

    sweep)
      case "${1:-}" in
        wandb)
          shift || true
          if [[ -z "${1:-}" ]]; then
            echo "Usage: ws sweep wandb <entity/project/sweep_id>"
            return 2
          fi
          create_wandb_sweep_job_with_slurm_olivia "$1"
          ;;
        *) echo "Usage: ws sweep {wandb} <entity/project/sweep_id>" ;;
      esac
      ;;

    t)    start_tmux ;;
    env)  olivia_env_updater "$@" ;;

    show)
      case "${1:-}" in
        exp) python -m manager show experiments ;;
        r)   python -m manager show remotes ;;
        *)   python -m manager show experiments ;;
      esac
      ;;

    scan)   python -m manager experiment scan ;;
    sync)   python -m manager experiment sync "$@" ;;
    update) python -m manager update "$@" ;;
    ref)    python -m manager experiment refresh ;;

    sel)  eval "$(python -m manager experiment sel "$@")" ;;
    go)   eval "$(python -m manager experiment go  "$@")" ;;
    run)  create_job_with_slurm_olivia "$@" ;;
    conf) set_job_conf_olivia "$@" ;;

    *)
      cat <<EOF
Workspace Helper (OLIVIA)

Usage:
  ws <command> [options]

Commands:
  t                       Start tmux
  env                     Environment helper
  scan                    Scan workspace
  sync                    Sync experiments
  update                  Run updates
  ref                     Refresh experiments

  show exp                Show experiments
  show r                  Show remotes

  sel <id>                Select experiment
  go <id>                 Go to experiment

  conf cpu|gpu|gpu2       Set job config
  run <file.py> [args...] Submit job and stream merged log
  stream [1|2|job_id|log] Stream latest/older/job/log
  logs [1|2|job_id|log]   Same as stream

  watch [job]             Monitor jobs
  del [job]               Delete job

  sweep wandb <entity/project/sweep_id>

Examples:
  ws conf gpu
  ws run engine.py arg1 arg2
  ws stream 1
  ws stream 2
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

if [[ -x "$VENV_DIR/bin/python" ]]; then
  workspace_helper env reset
else
  echo "Environment not active yet."
  echo "Create it with: ws env new"
fi

if command -v py >/dev/null 2>&1; then
  eval "$(py -m ssh-agent 2>/dev/null)" || true
fi
