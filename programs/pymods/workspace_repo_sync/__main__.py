from .git import GitManager as Git 
from pathlib import Path
import os

if __name__ == "__main__":
    workspace_repo_path = Path(os.environ['ENV_STORAGE_BASE'].replace('\\','/'))
    git = Git(workspace_repo_path)
    git.git('fetch','origin')
    git.git('reset','--hard','origin/main')
    os.makedirs(workspace_repo_path / "db",exist_ok=True)
    