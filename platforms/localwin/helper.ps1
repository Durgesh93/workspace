# ------------------------------------------------------------
# localwin_env_updater
# ------------------------------------------------------------
function localwin_env_updater {
    
    param(
        [Parameter(Position=0)]
        [string]$mode,

        [Parameter(Position=1)]
        [string]$pkg
    )

    # ------------------------------------------------------------
    # Common config
    # ------------------------------------------------------------
    $ENV_YML  = Join-Path $env:ENV_STORAGE_BASE "files\condaenv\env_cuda.yml"
    switch ($mode) {

        # ============================================================
        # NEW ENV
        # ============================================================
        "new" {

            Write-Host "[env] Creating environment: $env:VENV_DIR"
            Write-Host "[debug] ENV_YML: $ENV_YML"

            
            conda update -n base -c defaults conda

            # ---- Remove existing env (correct flag) ----
            conda remove --prefix "$env:VENV_DIR" --all -y 2>$null

            # ---- Create env ----
            conda env create `
                --prefix "$env:VENV_DIR" `
                --file "$ENV_YML"

        
            # ---- Verify env exists ----
            if (!(Test-Path "$env:VENV_DIR\python.exe")) {
                Write-Host "[env] ERROR: environment not created"
                return
            }

            # ---- Activate ----
            conda activate "$env:VENV_DIR"

            if ($LASTEXITCODE -ne 0) {
                Write-Host "[env] ERROR: activation failed"
                return
            }

            Write-Host "[env] Environment created and activated"
        }
        # ============================================================
        # UPDATE ENV
        # ============================================================
        "update" {

            if (-not (conda env list | Select-String $env:VENV_DIR)) {
                Write-Host "[env] Environment not found: $env:VENV_DIR" -ForegroundColor Red
                return
            }

            conda activate $env:VENV_DIR
            if ($pkg) {
                if (pip show $pkg 2>$null) {
                    Write-Host "[env] Package '$pkg' already installed"
                } else {
                    Write-Host "[env] Installing $pkg"
                    pip install -U $pkg -v
                }
            } else {
                Write-Host "[env] No package specified"
            }
        }

        # ============================================================
        # DEFAULT
        # ============================================================
        default {
            Write-Host ""
            Write-Host "Usage:"
            Write-Host "  env_updater new"
            Write-Host "  env_updater update <package>"
            Write-Host ""
        }
    }
}

# ============================================================
# PROMPT COLORS
# ============================================================

function ps_init_colors {
    if ($env:PS_NO_COLOR -eq "1") {
        $global:C_HDR = ""
        $global:C_KEY = ""
        $global:C_VAL = ""
        $global:C_TAG = ""
        $global:C_RST = ""
        return
    }

    $global:C_HDR = "`e[35m"
    $global:C_KEY = "`e[36m"
    $global:C_VAL = "`e[32m"
    $global:C_TAG = "`e[34m"
    $global:C_RST = "`e[0m"
}

# ============================================================
# PATH DISPLAY
# ============================================================

function shortpwd {
    $p = (Get-Location).Path

    if ($env:USERPROFILE -and $p.StartsWith($env:USERPROFILE)) {
        $p = "~" + $p.Substring($env:USERPROFILE.Length)
    }

    $parts = $p -split '[\\/]'

    if ($parts.Count -le 4) {
        return $p
    }
    else {
        return "…\" + ($parts[-4..-1] -join "\")
    }
}

# ============================================================
# PROMPT
# ============================================================

function prompt {

    $p = if ($env:REPO_DIR) { $env:REPO_DIR } else { "None" }
    $e = if ($env:BRANCH_NAME) { $env:BRANCH_NAME } else { "None" }

    $cur = shortpwd

    return @"
${C_HDR}[exp]${C_RST} P:${C_VAL}$p${C_RST} E:${C_VAL}$e${C_RST}
${C_TAG}[$env:ENVIRONMENT]${C_RST} $cur > 
"@
}

function cd {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        $args
    )

    # Call original Set-Location (cd)
    Microsoft.PowerShell.Management\Set-Location @args

    if ($?) {
        set_ps_locallinux
    }
}

function py {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        $args
    )

    # Build repo path
    $repo = $env:REPO_DIR
    $branch = $env:BRANCH_NAME

    if ($repo) {
        $target = if ($branch) {
            Join-Path $env:PROJ_STORAGE_BASE $repo $branch
        } else {
            Join-Path $env:PROJ_STORAGE_BASE $repo
        }

        if (Test-Path $target) {

            # Append to PYTHONPATH safely
            if ($env:PYTHONPATH) {
                if ($env:PYTHONPATH -notlike "*$target*") {
                    $env:PYTHONPATH = "$target;$env:PYTHONPATH"
                }
            } else {
                $env:PYTHONPATH = $target
            }
        }
    }

    # Run python with all arguments
    python @args
}

# ============================================================
# INIT
# ============================================================

ps_init_colors
