#!/bin/sh
# Olivia cluster helper functions (POSIX /bin/sh).
# Source this file into your shell (e.g., `. ./olivia_helpers.sh`) to gain
# Slurm job utilities, environment management helpers, and prompt tools.

# ---------------------------------------------------------------------
# delete_olivia_job: cancel jobs by name, all, last, or Nth in your list
# ---------------------------------------------------------------------
delete_olivia_job() {
  if [ -z "${1:-}" ]; then
    # No arg: cancel by current $JOB_NAME (must be exported somewhere else).
    # Uses scancel -n (cancel by job *name*, not job id).
    if [ -n "${JOB_NAME:-}" ]; then
      scancel -n "$JOB_NAME"
    else
      echo "JOB_NAME not set"; return 1
    fi
    return 0
  fi

  # Prepare a simple list of *your* job IDs (no headers), one per line.
  MYJOBS="$(squeue --me -h -o '%i')"

  case "$1" in
    all)
      # Cancel every job ID in your personal queue.
      echo "$MYJOBS" | while IFS= read -r JOB; do
        [ -n "$JOB" ] && scancel "$JOB"
      done
      ;;
    last)
      # Cancel the last job in your current listing (roughly "most recent").
      JOB="$(printf '%s\n' "$MYJOBS" | tail -n 1)"
      [ -n "$JOB" ] && scancel "$JOB"
      ;;
    *)
      # Treat $1 as a 0-based *index* into your job-id list.
      # Optional $2 is kept for symmetry with earlier versions, default 0.
      idx="${2:-0}"
      # Convert 0-based to awk's 1-based record number.
      n=$((idx + 1))
      JOB="$(printf '%s\n' "$MYJOBS" | awk "NR==$n{print; exit}")"
      [ -n "$JOB" ] && scancel "$JOB"
      ;;
  esac
}

# ---------------------------------------------------------------------
# watch_olivia_resources: one-line dashboard showing your jobs repeatedly
# ---------------------------------------------------------------------
watch_olivia_resources() {
  # SQUEUE_FORMAT kept for future custom formatting if desired.
  SQUEUE_FORMAT="%.15F %.10i %24j %.2t %.12M %.12L %.4D   %R"
  i=1
  # Loop up to 60 minutes; Ctrl+C to exit early.
  while [ "$i" -le 60 ]; do
    clear
    # shellcheck disable=SC2030,SC2031  # Fine to reference env vars in loop
    squeue --me
    i=$((i + 1))
    sleep 60
  done
}

# ---------------------------------------------------------------------
# olivia_env_updater: create/update a containerized env via conda-containerize
# - Chooses CPU/GPU flavor from $OLIVIA_STACK (NRIS/CPU|NRIS/GPU)
# - Uses $VENV_BASE and $ENV_STORAGE_BASE to locate env and YAML
# ---------------------------------------------------------------------
olivia_env_updater() {
  case "${1:-}" in
    new)
      # Build a fresh environment under $VENV_DIR using a YAML spec.
      export PIP_NO_CACHE_DIR=1
      if [ "${OLIVIA_STACK:-NRIS/CPU}" = "NRIS/GPU" ]; then
        # Use PyTorch CUDA wheels index for GPU envs.
        export PIP_EXTRA_INDEX_URL="https://download.pytorch.org/whl/cu129"
        VENV_DIR="$VENV_BASE/pytorch_311_cuda"
        ENV_YML="$ENV_STORAGE_BASE/files/condaenv/env_cuda.yml"
      else
        # CPU envs should not use the CUDA extra index.
        unset PIP_EXTRA_INDEX_URL 2>/dev/null || true
        VENV_DIR="$VENV_BASE/python_311_cpu"
        ENV_YML="$ENV_STORAGE_BASE/files/condaenv/env_cpu.yml"
      fi

      # Safety: refuse to rm '/' or empty path; then recreate $VENV_DIR.
      if [ -d "$VENV_DIR" ]; then
        [ -n "$VENV_DIR" ] && [ "$VENV_DIR" != "/" ] || { echo "Refusing to remove '$VENV_DIR'"; return 1; }
        rm -rf -- "$VENV_DIR"
      fi
      mkdir -p -- "$VENV_DIR"

      rm -rf $VENV_DIR
      # Create environment inside the prefix using conda-containerize.
      conda-containerize new --prefix "$VENV_DIR" "$ENV_YML"
      ;;
    update)
      # Update an existing env; optionally post-install a single pip package.
      # Use CUDA wheels index only on GPU stacks.
      if [ "${OLIVIA_STACK:-NRIS/CPU}" = "NRIS/GPU" ]; then
        export PIP_EXTRA_INDEX_URL="https://download.pytorch.org/whl/cu129"
      else
        unset PIP_EXTRA_INDEX_URL 2>/dev/null || true
      fi
      export PIP_NO_CACHE_DIR=1

      # Resolve $VENV_DIR: explicit > infer from $OLIVIA_STACK.
      if [ -n "${VENV_DIR:-}" ]; then
        : # Use explicit VENV_DIR.
      else
        if [ "${OLIVIA_STACK:-NRIS/CPU}" = "NRIS/GPU" ]; then
          VENV_DIR="$VENV_BASE/pytorch_311_cuda"
        else
          VENV_DIR="$VENV_BASE/python_311_cpu"
        fi
      fi

      # Create a disposable post-install script for pip updates.
      tmpfile="$(mktemp /tmp/postinstall.XXXXXX.sh)"
      # NOTE: Supports only one package via $2. Change to "$@" to support many.
      pkg="${2:-}"
      {
        echo '#!/bin/sh'
        echo 'set -e'
        if [ -n "$pkg" ]; then
          # Intentionally expand $pkg at runtime inside the env.
          # shellcheck disable=SC2016
          echo "pip install -U -- '$pkg'"
        else
          echo 'echo "No package given to update"; exit 1'
        fi
      } > "$tmpfile"
      chmod +x "$tmpfile"

      # Run env update with post-install step; then clean up temp file.
      conda-containerize update "$VENV_DIR" --post-install "$tmpfile"
      rm -f -- "$tmpfile"
      ;;
    *)
      echo "Usage: olivia_env_updater new|update [package]"
      return 2
      ;;
  esac
}

# ---------------------------------------------------------------------
# shortpwd: compact pretty-printer for $PWD used in the prompt
# - Collapses $HOME to ~
# - Shows <=4 trailing components, otherwise prefixes with an ellipsis …
# ---------------------------------------------------------------------
shortpwd() {
  p="${PWD:-.}"
  # Replace $HOME prefix with '~' if applicable.
  if [ -n "${HOME:-}" ] && [ "${p#"$HOME"}" != "$p" ]; then
    p="~${p#"$HOME"}"
  fi

  # Use awk to split path and collapse it nicely.
  printf '%s\n' "$p" | awk -F/ '
    {
      tilde = ""
      s = $0
      # Handle leading ~ separately so we can re-add it later.
      if (substr(s,1,1) == "~") {
        tilde = "~"
        sub(/^~/,"",s)
      }
      n = split(s, a, "/")
      # When path begins with /, first field is empty; skip it.
      start = (a[1] == "" ? 2 : 1)
      count = n - start + 1

      # Prefix indicates absolute (/), tilde (~), or nothing (relative).
      if (tilde != "") {
        prefix = tilde
      } else if (a[1] == "") {
        prefix = "/"
      } else {
        prefix = ""
      }

      if (count <= 4) {
        # Keep the whole (short) path.
        out = prefix
        for (i = start; i <= n; i++) {
          if (out != "" && substr(out, length(out), 1) != "/") out = out "/"
          out = out a[i]
        }
        print (out == "" ? "/" : out)
      } else {
        # Collapse the head, keep the last 4 components.
        out = (prefix == "" ? "" : prefix) "…"
        for (i = n-3; i <= n; i++) out = out "/" a[i]
        print out
      }
    }
  '
}

# --------- tmux session ---------
start_tmux() {
  # Create/attach a 2x2 tmux workspace named 'workspace' and optional site config
  if command -v tmux >/dev/null 2>&1; then
    tmux has-session -t workspace 2>/dev/null
    if [ $? -ne 0 ]; then
      tmux new-session -d -s workspace -n main
      tmux split-window -h
      tmux split-window -v
      tmux select-pane -t 0
    fi
    if [ -n "$ENV_STORAGE_BASE" ] && [ -f "$ENV_STORAGE_BASE/config/tmux/tmux.conf" ]; then
      tmux source-file "$ENV_STORAGE_BASE/config/tmux/tmux.conf"
    fi
    tmux attach-session -t workspace
  else
    echo "tmux not found; install tmux to use 'ws t'" >&2
    return 1
  fi
}


# --------- tiny helpers ---------
path_prepend() {
  # Prepend $1 to PATH iff it's not already present.
  case ":$PATH:" in *":$1:"*) ;; *) PATH="$1${PATH:+:$PATH}";; esac
  export PATH
}

# ---------------------------------------------------------------------
# ps_init_colors: initialize ANSI color sequences for prompts
# - Disables colors if PS_NO_COLOR=1, stdout not a TTY, or TERM=dumb
# ---------------------------------------------------------------------
ps_init_colors() {
  if [ "${PS_NO_COLOR:-0}" = "1" ] || [ ! -t 1 ] || [ "${TERM:-dumb}" = "dumb" ]; then
    C_HDR= C_KEY= C_VAL= C_TAG= C_RST=
    return
  fi
  C_HDR=$'\e[35m'  # Magenta-ish header
  C_KEY=$'\e[36m'  # Cyan keys
  C_VAL=$'\e[32m'  # Green values
  C_TAG=$'\e[34m'  # Blue tag prefix
  C_RST=$'\e[0m'   # Reset
}

cd() {
  command cd "$@" || return
  set_ps
}

# ---------------------------------------------------------------------
# set_ps_olivia: a two-line prompt showing project/experiment and Slurm knobs
# - Uses shortpwd() for the path line
# - Reads $REPO_DIR, $BRANCH_NAME, $NUM_* and other envs if available
# ---------------------------------------------------------------------
set_ps_olivia() {
  p="${REPO_DIR:-None}"
  e="${BRANCH_NAME:-None}"
  stack_line="${C_HDR}[stack]${C_RST} ${C_KEY}${OLIVIA_STACK}${C_RST}"
  exp_line="${C_HDR}[exp details]${C_RST} ${C_KEY}P:${C_RST}${C_VAL}${p}${C_RST}  ${C_KEY}E:${C_RST}${C_VAL}${e}${C_RST}"
  j="${NUM_JOBS:-1}"
  n="${NUM_NODES:-1}"
  g="${NUM_GPUS:-1}"
  part="${GPU_PART:=accel}"
  t="${JOB_DURH:-1}"
  job_line="${C_HDR}[job details]${C_RST} ${C_KEY}J:${C_RST}${C_VAL}${j}${C_RST}  ${C_KEY}N:${C_RST}${C_VAL}${n}${C_RST}  ${C_KEY}G:${C_RST}${C_VAL}${g}${C_RST}  ${C_KEY}P:${C_RST}${C_VAL}${part}${C_RST}  ${C_KEY}T:${C_RST}${C_VAL}${t}${C_RST}"
  cur="$(shortpwd)"
  # Final PS1 includes two info lines and a third line with the working dir.
  PS1="${stack_line}\n${exp_line}\n${job_line}\n${C_TAG}[OLIVIA]${C_RST} ${cur} $ "
  export PS1
}

# ---------------------------------------------------------------------
# show_olivia_job_log: stream Slurm's StdOut/StdErr for a given job ID
# - Looks up files via `scontrol show job <id>`
# - Tails both files; Ctrl+C to stop, handled by cleanup()
# ---------------------------------------------------------------------
show_olivia_job_log() {
  if [ -z "${1:-}" ]; then
    echo "Usage: show_olivia_job_log <job_id>"; return 2
  fi
  job_id="$1"

  # Extract StdOut and StdErr file paths from scontrol output.
  stdout_file="$(scontrol show job "$job_id" | awk -F= '/StdOut/ {print $2}')"
  stderr_file="$(scontrol show job "$job_id" | awk -F= '/StdErr/ {print $2}')"

  if [ -z "$stdout_file" ] || [ -z "$stderr_file" ]; then
    echo "Log files not found for job $job_id"; return 1
  fi

  echo "Streaming logs for Job ID: $job_id"
  echo "stdout: $stdout_file"
  echo "stderr: $stderr_file"

  # Start both tails in background, remember their PIDs for cleanup().
  tail -f "$stdout_file" &
  TAIL1_PID=$!
  tail -f "$stderr_file" &
  TAIL2_PID=$!

  # Stop both tails on INT/TERM.
  trap 'cleanup' INT TERM

  # Block until tails exit (usually on Ctrl+C).
  wait
}

# ---------------------------------------------------------------------
# cleanup: helper for show_olivia_job_log to stop both tail processes
# ---------------------------------------------------------------------
cleanup() {
  if [ -n "${TAIL1_PID:-}" ] && [ -n "${TAIL2_PID:-}" ]; then
    echo "Stopping logs..."
    kill "$TAIL1_PID" "$TAIL2_PID" 2>/dev/null
    # optional: clear
    # clear
  fi
  unset TAIL1_PID TAIL2_PID
}


# ---------------------------------------------------------------------
# set_job_conf: validate and derive Slurm resource parameters (GPU-centric)
# Usage: set_job_conf <NUM_JOBS> <GPUS_PER_JOB> <JOB_HRS>
# - Exports: NUM_JOBS, NUM_NODES, NUM_GPUS, NTASKS, JOB_HRS, JOB_DUR, JOB_DURH
#            GPU_PART, CPUS_PER_TASK, MEM_PER_GPU
# ---------------------------------------------------------------------
set_job_conf_olivia() {
  # Ensure at least one argument is provided.
  if [[ -z "$1" ]]; then
    echo "Error: No input provided. Expected format: NUM_JOBS.GPUS_PER_JOB.REQ_HRS"
    return 1
  fi

  # Split the input by dot (.)
  IFS='.' read -r NUM_JOBS GPUS_PER_JOB REQ_HRS <<< "$1"

  # Default values for missing arguments.
  NUM_JOBS="${NUM_JOBS:-1}"
  GPUS_PER_JOB="${GPUS_PER_JOB:-1}"   # Enforced >=1 for GPU-only workflows
  REQ_HRS="${REQ_HRS:-1}"

  # Basic integer validation.
  case "$NUM_JOBS" in ''|*[!0-9]*) echo "NUM_JOBS must be an integer"; return 2;; esac
  case "$GPUS_PER_JOB" in ''|*[!0-9]*) echo "GPUS_PER_JOB must be an integer"; return 2;; esac
  case "$REQ_HRS" in ''|*[!0-9]*) echo "REQ_HRS must be an integer"; return 2;; esac

  if [ "$GPUS_PER_JOB" -lt 1 ]; then
    echo "This setup is GPU-only: GPUS_PER_JOB must be >= 1"; return 2
  fi

  # QoS/partition policy derived from requested hours.
  if [ "$REQ_HRS" -le 2 ]; then
    GPU_PART="accel"
    MAX_HOURS=2
    MAX_GPUS=16
  else
    GPU_PART="accel"
    MAX_HOURS=168   # 7 days
    MAX_GPUS=32
  fi

  # Clamp hours to max; compute Slurm D-HH:MM:SS and human string.
  if [ "$REQ_HRS" -gt "$MAX_HOURS" ]; then JOB_HRS="$MAX_HOURS"; else JOB_HRS="$REQ_HRS"; fi
  days=$(( JOB_HRS / 24 )); hrs=$(( JOB_HRS % 24 ))
  JOB_DUR="${days}-${hrs}:00:00"
  if   [ "$days" -gt 0 ] && [ "$hrs" -gt 0 ]; then JOB_DURH="${days} Days, ${hrs} Hrs"
  elif [ "$days" -gt 0 ]; then JOB_DURH="${days} Days"
  else JOB_DURH="${hrs} Hrs"; fi

  # Enforce GPU cap for selected QoS.
  if [ "$GPUS_PER_JOB" -gt "$MAX_GPUS" ]; then
    echo "Requested $GPUS_PER_JOB GPUs exceeds $MAX_GPUS limit for this QoS; clamping."
    GPUS_PER_JOB="$MAX_GPUS"
  fi

  # Derive node count (assumes 2 GPUs per node; ceil division).
  NUM_GPUS="$GPUS_PER_JOB"
  NUM_NODES=$(( (GPUS_PER_JOB + 1) / 2 ))
  [ "$NUM_NODES" -lt 1 ] && NUM_NODES=1

  # Tasks per job equals requested GPUs (simple GPU-per-task mapping).
  NTASKS="$GPUS_PER_JOB"
  : "${CPUS_PER_TASK:=8}"    # Default CPU cores per task if not set.
  : "${MEM_PER_GPU:=64G}"    # Default memory per GPU if not set.

  # Export for downstream functions (create_job_with_slurm, prompt, etc.).
  export NUM_JOBS NUM_NODES NUM_GPUS NTASKS JOB_HRS JOB_DUR JOB_DURH
  export GPU_PART CPUS_PER_TASK MEM_PER_GPU
}

# ---------------------------------------------------------------------
# create_job_with_slurm: submit a minimal sbatch array from current context
# - Derives JOB_NAME from `python -m fake` (placeholder CLI)
# - Uses exported knobs from set_job_conf()
# - NOTE: This is intentionally a skeleton; add #SBATCH time/partition/etc.
# ---------------------------------------------------------------------
create_job_with_slurm_olivia() {
  export EXPERIMENT_NAME="$(python -m fake 2>&1)"
  export TARGET_FILE="${1:-}"   # pass full path: ENTITY/PROJECT/SWEEP_ID

  sbatch --array="1-${NUM_JOBS:-1}" <<EOF
#!/bin/sh -l
#SBATCH --job-name=$EXPERIMENT_NAME
#SBATCH --output=./dirs/files/$EXPERIMENT_NAME.o
#SBATCH --error=./dirs/files/$EXPERIMENT_NAME.e
#SBATCH --partition=${GPU_PART}
#SBATCH --time=${JOB_DUR}
#SBATCH --ntasks=$NTASKS
#SBATCH --cpus-per-task=${CPUS_PER_TASK}
#SBATCH --gpus-per-task=1
#SBATCH --mem-per-gpu=${MEM_PER_GPU}
#SBATCH --network=single_node_vni

source "\$HOME/.bashrc"

cd "$PROJ_STORAGE_BASE/$REPO_DIR/$BRANCH_NAME" || exit 1
python -m pip install -e . -qqq --user --upgrade

# Context banner
echo "JOB_NAME=$EXPERIMENT_NAME NUM_JOBS=${NUM_JOBS:-1} NUM_TASKS=${NUM_TASKS:-1} NUM_GPU=${NUM_GPUS:-1} JOB_DUR=${JOB_DUR:-?} NUM_NODES=${NUM_NODES:-1} SLURM_ACCOUNT=\${SBATCH_ACCOUNT} GPU_PART=${GPU_PART}"

# Minimal DDP-ish env
export NUM_NODES=\${NUM_NODES:-1}
export NUM_GPUS=\${NUM_GPUS:-1}
export MASTER_ADDR="\${MASTER_ADDR:-localhost}"
export MASTER_PORT="\${MASTER_PORT:-29500}"

# Slurm awareness (POSIX)
if [ -n "\${SLURM_JOB_ID:-}" ]; then
  MASTER_ADDR="\$(scontrol show hostnames "\${SLURM_JOB_NODELIST}" | head -n1)"
  export MASTER_ADDR
  export NODE_RANK="\${SLURM_NODEID}"
  export WORLD_SIZE="\$NTASKS"
  export RANK="\${SLURM_PROCID}"
  export LOCAL_RANK="\${SLURM_LOCALID}"
else
  export NODE_RANK="\${NODE_RANK:-0}"
  export WORLD_SIZE="\$NTASKS"
  export RANK="\${RANK:-0}"
  export LOCAL_RANK="\${LOCAL_RANK:-0}"
fi

python $TARGET_FILE

# ---- epilog ----
rm -rf "\$PYTHONUSERBASE" 2>/dev/null || true
EOF
}
