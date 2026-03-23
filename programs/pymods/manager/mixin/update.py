from __future__ import annotations
from pathlib import Path 
import re 

from ..db import DB
from ..utils import need_env
from ..view import log_message

class UpdateMixin:

    def update_dependency(self, q) -> None:

        experiment_deps = [int(id.strip()) for id in q.split('->')]
        
        for prev_id,next_id in zip(experiment_deps[:-1],experiment_deps[1:]):

            with DB(self._db()) as db:
                prev_exp = db.execute(
                    "SELECT * FROM experiments WHERE id = ?",
                    (prev_id,),
                    )          

                if not prev_exp:
                    log_message("workspace", f"experiment id {prev_id} not found", level="error", exit_on_error=True)

            with DB(self._db()) as db:
                next_exp = db.execute(
                    "SELECT * FROM experiments WHERE id = ?",
                    (next_id,),
                    )          

                if not next_exp:
                    log_message("workspace", f"experiment id {next_id} not found", level="error", exit_on_error=True)


            prev_exp   = prev_exp[0]
            next_exp   = next_exp[0] 

            with DB(self._db()) as db:
                db.execute(
                    "UPDATE experiments SET dep = ? WHERE id = ?",
                    (prev_exp["id"], next_exp["id"]),
                )
                
            log_message("workspace", f"experiment {prev_exp['id']}. {prev_exp['branch']} -> {next_exp['id']}. {next_exp['branch']} dependency updated ", level="info")

    def update_app_add_or_update_tag(self, target_id, tag_name) -> None:

        t = str(tag_name).strip().lower()
        clean_tag = None if t in ("", "none", "null") else str(tag_name).strip()

        with DB(self._db()) as db:

            rows = db.execute(
                "SELECT * FROM experiments WHERE id = ?",
                (target_id,),
            )

            if not rows:
                log_message(
                    "workspace",
                    f"experiment id {target_id} not found",
                    level="error",
                    exit_on_error=True
                )

            exp = rows[0]

            # -------- update --------
            db.execute(
                "UPDATE experiments SET tag = ? WHERE id = ?",
                (clean_tag, target_id),
            )

            log_message(
                "workspace",
                f"experiment {target_id}. {exp['branch']} tag {clean_tag} updated",
                level="info"
            )
         
    def update_app_add_remote(self, remote_path) -> None:
        """
        Sanitize git remote URL (SSH/HTTPS only) and insert if not exists.
        """

        # ---------------- sanitize ----------------
        url = str(remote_path).strip()

        https_pattern = re.compile(r"^https://[\w.\-]+/.+/.+(\.git)?$")
        ssh_pattern = re.compile(r"^git@[\w.\-]+:.+/.+(\.git)?$")

        if https_pattern.match(url) or ssh_pattern.match(url):
            if not url.endswith(".git"):
                url += ".git"
        else:
            log_message(
                "workspace",
                f"Invalid git URL: {url}",
                level="error",
                exit_on_error=True,
            )

        with DB(self._db()) as db:
            # 🔍 check if exists
            rows = db.execute(
                "SELECT remote_id FROM remotes WHERE url = ?",
                (url,),
            )

            if rows:
                log_message("workspace", f"already exists: {url}")
                return rows[0]["remote_id"] if isinstance(rows[0], dict) else rows[0][0]

            # ➕ insert
            remote_id = db.execute(
                "INSERT INTO remotes (url) VALUES (?)",
                (url,),
            )

        log_message("workspace",  f"added: {remote_id}. {remote_path}")
        return remote_id


    def update_app_del_remote(self,remote_id):
        with DB(self._db()) as db:
            rows = db.execute(
                "SELECT remote_id,url FROM remotes WHERE remote_id = ?",
                (remote_id,),
            )

            if not rows:
                log_message("workspace", f"id {remote_id} not found", level="error", exit_on_error=True)

            db.execute(
                "DELETE FROM remotes WHERE remote_id = ?",
                (remote_id,),
            )
        log_message("workspace", f"deleted: {remote_id}. {rows[0]['url']}")
        