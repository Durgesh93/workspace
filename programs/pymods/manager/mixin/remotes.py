
from __future__ import annotations
from shlex import quote
import re
import networkx as nx 
from ..db import DB
from ..view import log_message
from ..git import GitManager as Git
from ..template import Template
from ..utils import detect_shell, need_env

class RemotesMixin:

    def remotes_app_scan_remotes(self):
        project_base = self._pb()

        found_remotes = set()

        # ---------------------------------------------------------
        # scan filesystem
        # ---------------------------------------------------------
        for repo_dir in project_base.iterdir():

            if not repo_dir.is_dir():
                continue

            if not (repo_dir / ".git").exists():
                continue

            git = Git(repo_path=repo_dir)

            try:
                remote_url = git.git("remote", "get-url", "origin").strip()
                if remote_url:
                    found_remotes.add(remote_url)

            except Exception as e:
                log_message("workspace", f"git: [WARNING] {repo_dir} → {e}")
                continue

        # ---------------------------------------------------------
        # reset table + sequence
        # ---------------------------------------------------------
        with DB(self._db()) as db:

            # -------- delete all --------
            db.execute("DELETE FROM remotes")

            # -------- reset auto-increment --------
            db.execute("DELETE FROM sqlite_sequence WHERE name='remotes'")

            # -------- insert fresh --------
            for url in found_remotes:
                db.execute(
                    "INSERT INTO remotes (url) VALUES (?)",
                    (url,)
                )
                log_message("workspace", f"remotes: added {url}")

        log_message("workspace", f"remotes: rebuilt {len(found_remotes)} entries")
