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

  case "${1:-}" in

    new)
      module load LUMI
      module load lumi-container-wrapper

      export PIP_NO_CACHE_DIR=1
      export PIP_EXTRA_INDEX_URL="https://download.pytorch.org/whl/rocm6.0"

      VENV_DIR="$ENV_STORAGE_BASE/envbase/pytorch_311_rocm"
      ENV_YML="$ENV_STORAGE_BASE/files/condaenv/env_rocm.yml"

      if [ -d "$VENV_DIR" ]; then
        [ -n "$VENV_DIR" ] && [ "$VENV_DIR" != "/" ] || {
          echo "Refusing to remove '$VENV_DIR'"; return 1;
        }
        rm -rf -- "$VENV_DIR"
      fi

      mkdir -p -- "$VENV_DIR"
      conda-containerize new --prefix "$VENV_DIR" "$ENV_YML"

      module unload LUMI
      module unload lumi-container-wrapper
      ;;

    update)
      module load LUMI
      module load lumi-container-wrapper

      export PIP_NO_CACHE_DIR=1
      export PIP_EXTRA_INDEX_URL="https://download.pytorch.org/whl/rocm6.0"

      VENV_DIR="$ENV_STORAGE_BASE/envbase/pytorch_311_rocm"

      pkg_args="${*:2}"
      pkg_args=$(printf '%s' "$pkg_args" | tr ',' ' ')

      if [ -n "$pkg_args" ]; then
        tmpfile="$(mktemp /tmp/postinstall.XXXXXX.sh)"

        {
          printf 'pip install -U'
          for pkg in $pkg_args; do
            printf " '%s'" "$pkg"
          done
          printf '\n'
        } > "$tmpfile"

        conda-containerize update "$VENV_DIR" --post-install "$tmpfile"
        rm -f "$tmpfile"
      else
        conda-containerize update "$VENV_DIR"
      fi

      module unload LUMI
      module unload lumi-container-wrapper
      ;;

    *)
      echo "Usage: lumi_env_updater new|update [packages]"
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

use_only_rocm_python() {
  rocm_bin="$VENV_BASE/pytorch_311_rocm/bin"

  new_path=""
  OLD_IFS=$IFS
  IFS=":"
  for p in $PATH; do
    case "$p" in
      */python*/bin) ;;
      *)
        [ -z "$new_path" ] && new_path="$p" || new_path="$new_path:$p"
        ;;
    esac
  done
  IFS=$OLD_IFS

  PATH="$rocm_bin:$new_path"
  export PATH
  hash -r
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

  PS1="${C_HDR}[exp]${C_RST} \
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
  export TMPDIR="$VENV_BASE/tmp"
  export MIOPEN_DISABLE_CACHE=1
  export MIOPEN_USER_DB_PATH="$VENV_BASE/miopen"
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

  EXPERIMENT_NAME="$(python -m fake 2>&1)"
  TARGET_FILE="$1"

  sbatch --array="1-${NUM_JOBS:-1}" <<EOF
#!/bin/bash -l
#SBATCH --job-name=$EXPERIMENT_NAME
#SBATCH --partition=$GPU_PART
#SBATCH --time=$JOB_DUR
#SBATCH --nodes=$NUM_NODES
#SBATCH --gpus-per-node=$((NUM_GPUS/NUM_NODES))

set_rocm_config

python "$TARGET_FILE"
EOF
}

ps_init_colors