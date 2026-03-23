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

function greset {
    param(
        [string]$RootBranch = "root",
        [int]$Jobs = $(if ($env:GRESET_JOBS) { [int]$env:GRESET_JOBS } else { 4 })
    )

    $repoRoot = (& git rev-parse --show-toplevel 2>$null)
    if (-not $repoRoot) {
        Write-Host "Not inside a git repository"
        return
    }

    $repoRoot = $repoRoot.Trim()
    Set-Location $repoRoot

    & git switch $RootBranch
    if ($LASTEXITCODE -ne 0) { return }

    # remove linked worktrees except main repo
    $worktrees = & git worktree list --porcelain |
        Where-Object { $_ -like "worktree *" } |
        ForEach-Object { ($_ -replace '^worktree\s+', '').Trim() }

    foreach ($wt in $worktrees) {
        if ([string]::IsNullOrWhiteSpace($wt)) { continue }
        if ($wt -ne $repoRoot) {
            Write-Host "Removing worktree: $wt"
            & git worktree remove $wt --force
            if ($LASTEXITCODE -ne 0) { return }
        }
    }

    & git worktree prune
    if ($LASTEXITCODE -ne 0) { return }

    # delete all local branches except root
    $localBranches = & git branch --format='%(refname:short)'
    foreach ($br in $localBranches) {
        $br = $br.Trim()
        if ([string]::IsNullOrWhiteSpace($br)) { continue }
        if ($br -ne $RootBranch) {
            Write-Host "Deleting local branch: $br"
            & git branch -D $br
            if ($LASTEXITCODE -ne 0) { return }
        }
    }

    & git fetch origin
    if ($LASTEXITCODE -ne 0) { return }

    # collect remote branches except root and HEAD
    $remoteBranches = & git branch -r |
        ForEach-Object { $_.Trim() } |
        Where-Object {
            $_ -like "origin/*" -and
            $_ -notmatch '->' -and
            $_ -ne "origin/$RootBranch"
        } |
        ForEach-Object { $_ -replace '^origin/', '' }

    # create worktrees sequentially
    foreach ($br in $remoteBranches) {
        if ([string]::IsNullOrWhiteSpace($br)) { continue }

        Write-Host "Creating worktree for $br"
        & git worktree add "$repoRoot\$br" -b $br "origin/$br"
        if ($LASTEXITCODE -ne 0) { return }
    }

    Write-Host "All worktrees created"

    # submodule init in parallel only
    $jobsList = @()
    foreach ($br in $remoteBranches) {
        if ([string]::IsNullOrWhiteSpace($br)) { continue }

        while ( ($jobsList | Where-Object { $_.State -eq 'Running' }).Count -ge $Jobs ) {
            Start-Sleep -Milliseconds 300
            $jobsList = $jobsList | Where-Object { $_.State -eq 'Running' }
        }

        $job = Start-Job -ArgumentList $repoRoot, $br -ScriptBlock {
            param($repoRoot, $br)
            Write-Output "Initializing submodules in $br"
            Set-Location (Join-Path $repoRoot $br)
            & git submodule update --init --recursive
            exit $LASTEXITCODE
        }

        $jobsList += $job
    }

    if ($jobsList.Count -gt 0) {
        Wait-Job $jobsList | Out-Null

        foreach ($job in $jobsList) {
            Receive-Job $job
            if ($job.State -ne 'Completed') {
                Write-Host "A submodule initialization job failed"
                Remove-Job $job -Force
                return
            }
            Remove-Job $job -Force
        }
    }
}

# ============================================================
# INIT
# ============================================================

ps_init_colors
