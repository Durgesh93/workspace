from __future__ import annotations
from ..view import print_table
from ..db import DB


class ShowMixin:

    def show_app_experiments(self) -> None:
        with DB(self._db()) as db:
            rows = db.execute("""
                                SELECT 
                                    e.id,
                                    e.repo,
                                    e.branch,
                                    e.tag,
                                    e.dep,
                                    r.url AS url,
                                    e.remote_id
                                FROM experiments e
                                LEFT JOIN remotes r
                                    ON e.remote_id = r.remote_id
                            """)                
            out = []
            for item in rows:
                out.append({
                    "ID": item['id'],
                    "Repo.Branch": str(item["repo"])+"."+str(item['branch']),
                    "Tag Name": item['tag'],
                    "Dependency (Stack)": item['dep'],
                    "Remote": item['url'],
                })
            
            print_table(out, title='List of Experiments',headers=["ID", "Repo.Branch", "Tag Name","Dependency (Stack)","Remote"])

    def show_app_remotes(self) -> None:
        with DB(self._db()) as db:
            rows = db.execute("""
                                SELECT 
                                    remote_id,
                                    url
                                FROM remotes r
                            """)                         
            out = []
            for item in rows:
                repo_name = item['url'].split("/")[-1].replace(".git", "")
                out.append({
                    "Remote ID": item['remote_id'],
                    "Repo":repo_name,
                    "URL": item['url'],
                })
            print_table(out,title='List of Remotes', headers=["Remote ID", "Repo","URL"])
