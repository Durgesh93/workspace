#!/usr/bin/env bash
# ============================================================
# ENVIRONMENT SETUP (LUMI)
# ============================================================
export ENVIRONMENT="lumi"
export SBATCH_ACCOUNT="project_465002860"

# NOTE: unlike Olivia, no proxy is configured here. Add http_proxy /
# https_proxy exports here (same pattern as Olivia) if your LUMI login
# or compute nodes require one for outbound internet access.

# Resolve username
USER_NAME="${USER:-$(whoami)}"
export USER_NAME

# Storage paths
# /project is persistent (quota-managed), /scratch is high-throughput
# but subject to purge policies - mirrors Olivia's DATA_STORAGE_BASE
# split across ephemeral vs persistent storage.
export DATA_STORAGE_BASE="/scratch/${SBATCH_ACCOUNT}/${USER_NAME}"
export VENV_NAME="python_venv"
export ENV_TYPE="pt"
export ENV_STORAGE_BASE="/project/${SBATCH_ACCOUNT}/${USER_NAME}/envs/workspace"
export VENV_BASE="${DATA_STORAGE_BASE}/envbase"
export PROJ_STORAGE_BASE="/project/${SBATCH_ACCOUNT}/${USER_NAME}/projects"
export EXP_STORAGE_BASE="${DATA_STORAGE_BASE}/experiment_storage"
export TRASH_STORAGE_BASE="${EXP_STORAGE_BASE}/.trash"
export TMPDIR="${DATA_STORAGE_BASE}/tmp"
export ENV_YML="${ENV_STORAGE_BASE}/files/condaenv/env_pt_rocm.yml"
export PROJECT_USE_PCT="$(df /project/$SBATCH_ACCOUNT --output=pcent 2>/dev/null | tail -n 1 | tr -d ' ')"
export SCRATCH_USE_PCT="$(df /scratch/$SBATCH_ACCOUNT --output=pcent 2>/dev/null | tail -n 1 | tr -d ' ')"

mkdir -p "$ENV_STORAGE_BASE"
mkdir -p "$ENV_STORAGE_BASE/platforms/lumi"
mkdir -p "$ENV_STORAGE_BASE/files/condaenv"
mkdir -p "$ENV_STORAGE_BASE/programs/linux"
mkdir -p "$VENV_BASE"
mkdir -p "$PROJ_STORAGE_BASE"
mkdir -p "$EXP_STORAGE_BASE"
mkdir -p "$TRASH_STORAGE_BASE"
mkdir -p "$TMPDIR"

# ============================================================
# MODULE INIT + LOAD
# ============================================================
if ! command -v module >/dev/null 2>&1 && ! command -v ml >/dev/null 2>&1; then
  [[ -f /etc/profile.d/lmod.sh ]] && source /etc/profile.d/lmod.sh
  [[ -f /usr/share/lmod/lmod/init/bash ]] && source /usr/share/lmod/lmod/init/bash
fi

load_module_lumi_quiet() {
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

export LUMI_STACK_MODULE="${LUMI_STACK_MODULE:-LUMI}"
export LUMI_CONTAINER_MODULE="${LUMI_CONTAINER_MODULE:-lumi-container-wrapper}"
load_module_lumi_quiet "$LUMI_STACK_MODULE" || true
load_module_lumi_quiet "$LUMI_CONTAINER_MODULE" || true

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
# EXPERIMENT TRASH
# ============================================================
workspace_trash_dir() {
  if [[ -z "${REPO_DIR:-}" ]]; then
    echo "ERROR: REPO_DIR is not set." >&2
    echo "Select an experiment before using: ws trash" >&2
    return 1
  fi

  if [[ -z "${BRANCH_NAME:-}" ]]; then
    echo "ERROR: BRANCH_NAME is not set." >&2
    echo "Select an experiment before using: ws trash" >&2
    return 1
  fi

  local repo_name
  local branch_name

  # REPO_DIR may be a repository name or a full repository path.
  repo_name="${REPO_DIR%/}"
  repo_name="${repo_name##*/}"

  # Preserve branch paths such as feature/new-model.
  branch_name="${BRANCH_NAME#/}"
  branch_name="${branch_name%/}"

  if [[ -z "$repo_name" ]]; then
    echo "ERROR: REPO_DIR resolved to an empty repository name." >&2
    return 1
  fi

  if [[ -z "$branch_name" ]]; then
    echo "ERROR: BRANCH_NAME resolved to an empty branch name." >&2
    return 1
  fi

  case "/$repo_name/" in
    */../*|*/./*)
      echo "ERROR: unsafe REPO_DIR: $REPO_DIR" >&2
      return 1
      ;;
  esac

  case "/$branch_name/" in
    */../*|*/./*)
      echo "ERROR: unsafe BRANCH_NAME: $BRANCH_NAME" >&2
      return 1
      ;;
  esac

  printf '%s/%s/%s\n' \
    "$TRASH_STORAGE_BASE" \
    "$repo_name" \
    "$branch_name"
}

workspace_validate_trash_prefix() {
  local prefix="$1"

  if [[ -z "$prefix" ]]; then
    echo "ERROR: trash prefix must not be empty." >&2
    return 1
  fi

  # A prefix is one directory name, not a path.
  case "$prefix" in
    .|..|*/*|*\\*|*$'\n'*|*$'\r'*)
      echo "ERROR: unsafe trash prefix: $prefix" >&2
      echo "Use one directory name without '/' or '\\'." >&2
      return 1
      ;;
  esac
}

workspace_trash_path() {
  local prefix="${1:-}"
  local trash_dir

  trash_dir="$(workspace_trash_dir)" || return 1

  if [[ -n "$prefix" ]]; then
    workspace_validate_trash_prefix "$prefix" || return 1
    trash_dir="$trash_dir/$prefix"
  fi

  mkdir -p "$trash_dir"
  printf '%s\n' "$trash_dir"
}

workspace_trash_list() {
  local prefix="${1:-}"
  local trash_dir
  local max_depth=1

  trash_dir="$(workspace_trash_path "$prefix")" || return 1

  if [[ -n "$prefix" ]]; then
    # prefix/YYYY-MM-DD/HH-MM-SS_nanoseconds/items
    max_depth=3
  fi

  echo "Trash directory:"
  echo "$trash_dir"
  echo

  if ! find "$trash_dir" \
    -mindepth 1 \
    -maxdepth "$max_depth" \
    ! -name '.trash.log' \
    -print -quit 2>/dev/null | grep -q .; then
    echo "Trash is empty."
    return 0
  fi

  find "$trash_dir" \
    -mindepth 1 \
    -maxdepth "$max_depth" \
    ! -name '.trash.log' \
    -printf '%TY-%Tm-%Td %TH:%TM:%TS  %P\n' \
    2>/dev/null | sort -r
}

workspace_trash_log() {
  local prefix="${1:-}"
  local trash_dir
  local log_file

  trash_dir="$(workspace_trash_path "$prefix")" || return 1
  log_file="$trash_dir/.trash.log"

  if [[ ! -s "$log_file" ]]; then
    echo "No trash history found."
    return 0
  fi

  cat "$log_file"
}

workspace_trash_usage() {
  cat <<'EOF_USAGE'
Usage:
  ws trash <file-or-directory> [...]
  ws trash --prefix <name> <file-or-directory> [...]
  ws trash --path [--prefix <name>]
  ws trash --list [--prefix <name>]
  ws trash --log  [--prefix <name>]

Without a prefix, files are moved to:

  $EXP_STORAGE_BASE/.trash/<repository>/<branch>/

With a prefix, files from the same command are grouped in:

  $EXP_STORAGE_BASE/.trash/<repository>/<branch>/<prefix>/<YYYY-MM-DD>/<HH-MM-SS_nanoseconds>/

Examples:
  ws trash output.log
  ws trash results checkpoints
  ws trash --prefix baseline output.log results
  ws trash -P inference predictions.csv masks
  ws trash --prefix baseline --path
  ws trash --prefix baseline --list
  ws trash --prefix baseline --log
EOF_USAGE
}

workspace_trash() {
  local prefix=""
  local action="trash"
  local -a paths=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --prefix|-P)
        if [[ $# -lt 2 || -z "${2:-}" ]]; then
          echo "ERROR: --prefix requires a value." >&2
          return 2
        fi
        prefix="$2"
        shift 2
        ;;

      --prefix=*)
        prefix="${1#--prefix=}"
        if [[ -z "$prefix" ]]; then
          echo "ERROR: --prefix requires a value." >&2
          return 2
        fi
        shift
        ;;

      --path|-p)
        action="path"
        shift
        ;;

      --list|-l)
        action="list"
        shift
        ;;

      --log)
        action="log"
        shift
        ;;

      --help|-h)
        action="help"
        shift
        ;;

      --)
        shift
        while [[ $# -gt 0 ]]; do
          paths+=("$1")
          shift
        done
        ;;

      -* )
        echo "ERROR: unknown ws trash option: $1" >&2
        workspace_trash_usage >&2
        return 2
        ;;

      *)
        paths+=("$1")
        shift
        ;;
    esac
  done

  if [[ -n "$prefix" ]]; then
    workspace_validate_trash_prefix "$prefix" || return 1
  fi

  case "$action" in
    help)
      workspace_trash_usage
      return 0
      ;;

    path)
      workspace_trash_path "$prefix"
      return
      ;;

    list)
      workspace_trash_list "$prefix"
      return
      ;;

    log)
      workspace_trash_log "$prefix"
      return
      ;;
  esac

  if [[ ${#paths[@]} -eq 0 ]]; then
    workspace_trash_usage >&2
    return 2
  fi

  local trash_root
  local trash_run_dir=""
  local log_file
  local source
  local source_without_slash
  local base
  local timestamp
  local destination
  local original_path
  local counter
  local date_folder
  local time_folder
  local moved_count=0
  local failed_count=0

  trash_root="$(workspace_trash_path "$prefix")" || return 1
  log_file="$trash_root/.trash.log"

  for source in "${paths[@]}"; do
    if [[ ! -e "$source" && ! -L "$source" ]]; then
      echo "WARNING: not found: $source" >&2
      failed_count=$((failed_count + 1))
      continue
    fi

    if command -v realpath >/dev/null 2>&1; then
      original_path="$(realpath -m -- "$source")"
    elif [[ "$source" = /* ]]; then
      original_path="$source"
    else
      original_path="$PWD/${source#./}"
    fi

    source_without_slash="${source%/}"
    base="$(basename -- "$source_without_slash")"

    if [[ -z "$base" || "$base" == "." || "$base" == ".." ]]; then
      echo "ERROR: refusing to trash unsafe path: $source" >&2
      failed_count=$((failed_count + 1))
      continue
    fi

    if [[ -n "$prefix" ]]; then
      # Create one date/time folder for all valid paths in this command.
      if [[ -z "$trash_run_dir" ]]; then
        date_folder="$(date +%Y-%m-%d)"
        time_folder="$(date +%H-%M-%S_%N)"
        trash_run_dir="$trash_root/$date_folder/$time_folder"
        counter=1

        while [[ -e "$trash_run_dir" || -L "$trash_run_dir" ]]; do
          trash_run_dir="$trash_root/$date_folder/${time_folder}_$counter"
          counter=$((counter + 1))
        done

        mkdir -p "$trash_run_dir" || {
          echo "ERROR: could not create trash folder: $trash_run_dir" >&2
          return 1
        }
      fi

      destination="$trash_run_dir/$base"
      counter=1

      while [[ -e "$destination" || -L "$destination" ]]; do
        destination="$trash_run_dir/${base}_$counter"
        counter=$((counter + 1))
      done
    else
      # Preserve the original no-prefix behaviour.
      timestamp="$(date +%Y%m%d_%H%M%S_%N)"
      destination="$trash_root/${timestamp}_${base}"
      counter=1

      while [[ -e "$destination" || -L "$destination" ]]; do
        destination="$trash_root/${timestamp}_${counter}_${base}"
        counter=$((counter + 1))
      done
    fi

    if mv -- "$source" "$destination"; then
      printf '%s\t%s\t%s\t%s\n' \
        "$(date --iso-8601=seconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')" \
        "${prefix:-<none>}" \
        "$original_path" \
        "$destination" \
        >>"$log_file"

      echo "Trashed:"
      echo "  From: $original_path"
      echo "  To:   $destination"

      moved_count=$((moved_count + 1))
    else
      echo "ERROR: could not move to trash: $source" >&2
      failed_count=$((failed_count + 1))
    fi
  done

  echo
  echo "Moved:  $moved_count"
  echo "Failed: $failed_count"
  echo "Trash:  ${trash_run_dir:-$trash_root}"

  if ((failed_count > 0)); then
    return 1
  fi

  return 0
}

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
git config --global user.name "durgesh.lumi"
git config --global user.email "durgesh080793@gmail.com.lumi"

# ============================================================
# ALIASES
# ============================================================
alias conf_selector='set_job_conf_lumi'
alias job_runner='create_job_with_slurm_lumi'
alias job_streamer='stream_lumi_job_log'
alias job_watcher='watch_lumi_resources'
alias job_deleter='delete_lumi_job'
alias job_logger='stream_lumi_job_log'
alias set_ps='set_ps_lumi'
alias env_updater='lumi_env_updater'
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
  default_job_conf_lumi
  set_ps
  sub="$1"
  shift || true
  case "$sub" in
    watch)  watch_lumi_resources "$@" ;;
    del)    delete_lumi_job "$@" ;;
    logs)   stream_lumi_job_log "$@" ;;
    stream) stream_lumi_job_log "$@" ;;
    sweep)
      case "${1:-}" in
        wandb)
          shift || true
          if [[ -z "${1:-}" ]]; then
            echo "Usage: ws sweep wandb <entity/project/sweep_id>"
            return 2
          fi
          create_wandb_sweep_job_with_slurm_lumi "$1"
          ;;
        *) echo "Usage: ws sweep {wandb} <entity/project/sweep_id>" ;;
      esac
      ;;
    t)     start_tmux ;;
    env)   lumi_env_updater "$@" ;;
    trash) workspace_trash "$@" ;;
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
    run)  create_job_with_slurm_lumi "$@" ;;
    conf) set_job_conf_lumi "$@" ;;
    *)
      cat <<EOF
Workspace Helper (LUMI)
Usage:
  ws <command> [options]
Commands:
  t                        Start tmux
  env                      Environment helper
  scan                     Scan workspace
  sync                     Sync experiments
  update                   Run updates
  ref                      Refresh experiments
  show exp                 Show experiments
  show r                   Show remotes
  sel <id>                 Select experiment
  go <id>                  Go to experiment
  trash <path...>          Move files/directories to experiment trash
  trash --path             Show current repository/branch trash path
  trash --list             List current repository/branch trash
  trash --log              Show current repository/branch trash history
  conf dev|small|standard  Set job config
  run <file.py> [args...]  Submit job and stream merged log
  stream [1|2|job_id|log]  Stream latest/older/job/log
  logs [1|2|job_id|log]    Same as stream
  watch [job]              Monitor jobs
  del [job]                Delete job
  sweep wandb <entity/project/sweep_id>
EOF
      ;;
  esac
}

# ============================================================
# FINAL BOOTSTRAP
# ============================================================
set_rocm_config
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

