from __future__ import annotations
from typing import Union
from pathlib import Path
import os
import shutil
import subprocess
import shutil
import getpass

from .utils import need_env
from .view import log_message


class GitManager:
   
    def __init__(self, repo_path: Union[str, Path]):
        self.repo_path = Path(repo_path)
      
    def _git_env(self) -> dict:
        """Prepare environment for subprocess git calls."""
        env = need_env()
        if os.name == "posix":
            env.setdefault("GIT_SSH_COMMAND", "ssh -F /dev/null")
        return env

    def _ensure_git_identity(self):
        """
        Ensure git user.name and user.email are set in this repo.
        Falls back to system user if not configured.
        """

        def _get(key):
            try:
                return self.git("config", "--get", key).strip()
            except:
                return None

        def _get_global(key):
            try:
                return self.git("config", "--global", "--get", key).strip()
            except:
                return None

        # priority: local → global → system
        name = _get("user.name") or _get_global("user.name") or getpass.getuser()
        email = _get("user.email") or _get_global("user.email") or f"{name}@noreply.local"

        # set locally (only if missing)
        self.git("config","user.name", name, cwd=self.repo_path)
        self.git("config", "user.email", email, cwd=self.repo_path)
        
    def git(
        self,
        *args,
        cwd=None
    ):
        repo_path = str(cwd if cwd else self.repo_path)
        cmd = ["git", "-C", repo_path, *[str(a) for a in args]]

        cmd_str = " ".join(cmd[2:])  # cleaner display

        result = subprocess.run(
            cmd,
            env=self._git_env(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        if result.stdout:
            for line in result.stdout.strip().splitlines():
                pass

        if result.returncode != 0:
            if result.stderr:
                for line in result.stderr.strip().splitlines():
                    log_message("git", line, level="info")
                    
            log_message(
                "git",
                f"command failed: {cmd_str}",
                level="error",
                exit_on_error=True,
                exit_code=result.returncode,
            )    
        return (result.stdout or "").strip()

    def setup_worktrees(self) -> list[tuple[str, str]]:
        
        ORPHAN_BRANCH = "root"
        
        def _list_worktrees():
            paths, branches = [], []
            out = self.git("worktree", "list", "--porcelain", cwd=self.repo_path)

            current_path = None
            for line in out.splitlines():
                if line.startswith("worktree "):
                    current_path = line.split(" ", 1)[1].strip()
                elif line.startswith("branch "):
                    br = line.split(" ", 1)[1].split("/")[-1]

                    if br == ORPHAN_BRANCH:
                        current_path = None
                        continue

                    if current_path:
                        paths.append(current_path)
                        branches.append(br)
            return list(zip(paths, branches))

        # ---------------- always prune first ----------------
        self.git("worktree", "prune", cwd=self.repo_path)

        # ---------------- detect local branches ----------------
        out = self.git("branch", "--format=%(refname:short)", cwd=self.repo_path)
        locals_ = set([l.strip() for l in out.splitlines() if l.strip()])

        if not locals_:
            log_message("worktrees", "No local branches found, creating from remotes")
            self.git("fetch", "--all", cwd=self.repo_path)

            out = self.git(
                "branch",
                "-r",
                "--format=%(refname:short)",
                cwd=self.repo_path,
            )

            remotes = [
                r.split("/", 1)[1]
                for r in out.splitlines()
                if r.startswith("origin/") and "HEAD" not in r
            ]

            for br in remotes:
                self.git(
                    "branch",
                    br,
                    f"origin/{br}",
                    cwd=self.repo_path,
                )
            locals_ = set(remotes)
            
        # ---------------- orphan root ----------------
        current = self.git("rev-parse", "--abbrev-ref", "HEAD", cwd=self.repo_path)

        if current != ORPHAN_BRANCH:
            self.git("checkout", "--orphan", ORPHAN_BRANCH, cwd=self.repo_path)

            for item in self.repo_path.iterdir():
                if item.name == ".git":
                    continue
                if item.is_dir():
                    shutil.rmtree(item)
                else:
                    item.unlink()

            self._ensure_git_identity()

            self.git(
                "commit",
                "--allow-empty",
                "-m",
                "Metadata-only root (do not use)",
                cwd=self.repo_path,
                
            )
        
        # ---------------- rename master → main ----------------
        if "master" in locals_ and "main" not in locals_:
            self.git("branch", "-m", "master", "main", cwd=self.repo_path)
            locals_.remove("master")
            locals_.add("main")

        # ---------------- determine base branch ----------------
        if "main" in locals_:
            base_branch = "main"
        elif "master" in locals_:
            base_branch = "master"
        else:
            log_message(
                "worktrees",
                "No main/master branch found",
                level="error"
            )

        # ---------------- create base worktree ----------------
        base_path = self.repo_path / base_branch
        
        if not base_path.exists():
            self.git(
                "worktree",
                "add",
                str(base_path),
                base_branch,
                cwd=self.repo_path,
                
            )

        
        # ---------------- bootstrap remaining branches ----------------
        for br in sorted(locals_):
            if br in (base_branch, ORPHAN_BRANCH):
                continue

            wt_path = self.repo_path / br
            if wt_path.exists():
                continue

            self.git("worktree", "add", str(wt_path), br, cwd=self.repo_path)

        return _list_worktrees()
