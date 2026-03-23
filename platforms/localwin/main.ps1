# ============================================================
# ENVIRONMENT
# ============================================================
$env:ENVIRONMENT = "localwin"

# Resolve username
$USER_NAME = $env:USERNAME
if (-not $USER_NAME) {
    $USER_NAME = whoami
}


# Storage paths
# ============================================================
# ENSURE DIRECTORIES EXIST
# ============================================================
$BASE_DRIVE = "D:\550017924"
$env:ENV_STORAGE_BASE  = "$BASE_DRIVE\.env\workspace"
$env:VENV_BASE         = "$env:ENV_STORAGE_BASE\envbase"
$env:PROJ_STORAGE_BASE = "$BASE_DRIVE\projects"
$env:EXP_STORAGE_BASE  = "$BASE_DRIVE\experiment_storage"
$env:VENV_DIR          = Join-Path $env:VENV_BASE "pytorch_39_cuda_12"

$dirs = @(
    $env:ENV_STORAGE_BASE,
    $env:VENV_BASE,
    $env:PROJ_STORAGE_BASE,
    $env:EXP_STORAGE_BASE
)

foreach ($dir in $dirs) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

# ============================================================
# PYTHON / PIP / POETRY CONFIG
# ============================================================
$env:PIP_NO_CACHE_DIR = "1"
$env:PIP_COMPILE = "1"
$env:PIP_NO_WARN_SCRIPT_LOCATION = "1"
$env:PIP_NO_WARN_CONFLICTS = "1"
$env:SSL_CERT_FILE = ""
$env:REQUESTS_CA_BUNDLE = ""
$env:POETRY_VIRTUALENVS_CREATE = "false"
$env:POETRY_VIRTUALENVS_PREFER_ACTIVE = "true"
$env:GIT_CONFIG_GLOBAL = "$env:ENV_STORAGE_BASE\files\gitconfig"
$env:CONDA_VERBOSITY = "0"
conda config --set ssl_verify false


# ============================================================
# GPU DETECTION
# ============================================================
$global:has_gpu = $false
if (Get-Command "nvidia-smi" -ErrorAction SilentlyContinue) {
    try {
        nvidia-smi -L | Out-Null
        $global:has_gpu = $true
    } catch {}
}

# ============================================================
# Activate environment (conda if available)
# ============================================================
if (Get-Command conda -ErrorAction SilentlyContinue) {
    try {
        $CONDA_BASE = conda info --base 2>$null

        if ($CONDA_BASE -and (Test-Path "$CONDA_BASE\shell\condabin\conda-hook.ps1")) {
            & "$CONDA_BASE\shell\condabin\conda-hook.ps1"

            try {
                conda activate $env:VENV_DIR
            } catch {
                Write-Host "[env] WARNING: conda activate failed, using current python"
            }
        }
    } catch {
        Write-Host "[env] WARNING: conda not properly available"
    }
}

# ============================================================
# Python Path setup (only pymods)
# ============================================================
$PYMODS_PATH = "$env:ENV_STORAGE_BASE\programs\pymods"

if (-not $env:PYTHONPATH) {
    $env:PYTHONPATH = $PYMODS_PATH
} else {
    $paths = $env:PYTHONPATH -split ';'
    if ($paths -notcontains $PYMODS_PATH) {
        $env:PYTHONPATH = "$PYMODS_PATH;$env:PYTHONPATH"
    }
}

# ============================================================
#  HELPERS
# ============================================================
$helper1 = "$env:ENV_STORAGE_BASE\platforms\localwin\helper.ps1"
if (Test-Path $helper1) { . $helper1 }

# ============================================================
# ALIASES (AFTER FUNCTIONS)
# ============================================================
Set-Alias ws workspace_helper -Scope Global
Set-Alias env_updater localwin_env_updater -ErrorAction SilentlyContinue
Set-Alias set_ps set_ps_localwin -ErrorAction SilentlyContinue

# ============================================================
# WORKSPACE DISPATCHER
# ============================================================
function workspace_helper {
    param(
        [string]$sub,
        [Parameter(ValueFromRemainingArguments = $true)]
        $args
    )

    # Safe argument extraction
    $arg0 = if ($args -and $args.Count -gt 0) { $args[0] } else { $null }
    $arg1 = if ($args -and $args.Count -gt 1) { $args[1] } else { $null }

    switch ($sub) {

        "t" { start_tmux }

        "env" { env_updater $arg0 $arg1 }

        "show" {
            switch ($arg0) {
                "exp" { python -m manager show experiments }
                "r"   { python -m manager show remotes }
                default { python -m manager show experiments }
            }
        }

        "scan"   { python -m manager experiment scan }
        "sync"   { python -m manager experiment sync @args }
        "update" { python -m manager update @args }
        "ref"    { python -m manager experiment refresh }
       
        "sel" {
            $cmd = (python -m manager experiment sel @args | Out-String).Trim()
            if ($cmd) { Invoke-Expression $cmd }
        }

        "go" {
            $cmd = (python -m manager experiment go @args | Out-String).Trim()

            if (-not $cmd) { return }

            # -------- extract repo --------
            $repo = $null
            if ($cmd -match 'REPO_DIR="?([^"\r\n]+)"?') {
                $repo = $matches[1]
            }

            # -------- key mapping --------
            $keyMap = @{
                "mmodelvstudy" = "$env:USERPROFILE\.ssh\ge_gitlab"
                "workspace"    = "$env:USERPROFILE\.ssh\github_ge_desktop"
            }

            # -------- set SSH key --------
            if ($repo -and $keyMap.ContainsKey($repo)) {
                $keyPath = $keyMap[$repo]
                $env:GIT_SSH_COMMAND = "ssh -i `"$keyPath`""
            }

            # -------- run command --------
            Invoke-Expression $cmd
        }


        default {
@"
Workspace Helper

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
"@ | Write-Host
        }
    }
}


# ============================================================
# STATUS
# ============================================================
Write-Host "[env] GPU=$global:has_gpu"
py -m mlflow_server
py -m workspace_repo_sync
