
from __future__ import annotations
from shlex import quote
import re
import networkx as nx 
from collections import Counter
from ..db import DB
from ..view import log_message
from ..git import GitManager as Git
from ..template import Template
from ..utils import detect_shell, need_env

class ExperimentMixin:

    def experiment_app_scan_experiments(self):
        project_base = self._pb()
        global_wtrees = []

        prev_exp_data_exists= False
        with DB(self._db()) as db:
            prev_exp_data_exists = bool(db.execute("SELECT id FROM experiments"))

        with DB(self._db()) as db:
            remotes = db.execute("SELECT remote_id, url FROM remotes")
            
            for item in remotes:
                remote_id = item["remote_id"]
                url = item["url"]

                repo_name = url.split("/")[-1].replace(".git", "")
                repo_path = project_base / repo_name

                git = Git(repo_path=repo_path)

                try:
                    if not (repo_path / ".git").exists():
                        log_message("git", f"cloning {url}")
                        git.git("clone", url, cwd=project_base)
                except Exception as e:
                    log_message("git", f"[WARNING] clone failed {url} → {e}")
                    continue

                try:
                    wtrees = [(*r, remote_id, repo_name) for r in git.setup_worktrees()]
                    global_wtrees.extend(wtrees)
                except Exception as e:
                    log_message("git", f"[WARNING] worktree failed {repo_name} → {e}")
                    continue
        
        if not prev_exp_data_exists:
            with DB(self._db()) as db:
                db.execute("DELETE FROM experiments")
                db.execute("DELETE FROM sqlite_sequence WHERE name='experiments'")
                for path, branch, remote_id, repo_name in global_wtrees:
                    db.execute(
                        "INSERT INTO experiments (branch, repo, remote_id) VALUES (?, ?, ?)",
                        (branch, repo_name, remote_id),
                    )
                    log_message("workspace", f"added {branch} → {path}")
        else:
            merge_graph = self._experiment_merge_dependency()
            new_nodes = []
            for path, branch, remote_id, repo_name in global_wtrees:
                new_nodes.append((repo_name,branch))
            new_nodes     = set(new_nodes)
            missing_nodes = set(merge_graph.nodes()) - new_nodes

            for node in missing_nodes:
                parents = list(merge_graph.predecessors(node))
                children = list(merge_graph.successors(node))
                if parents and children:
                    for p in parents:
                        for c in children:
                            if (p[0] == c[0]) and (p[1] == c[1]):
                                if not merge_graph.has_edge(p, c):
                                    merge_graph.add_edge(p, c)
                merge_graph.remove_node(node)

            dep_map = {}
            for path, branch, remote_id, repo_name in global_wtrees:
                node = (repo_name,branch)
                if node in merge_graph:
                    parents_node = list(merge_graph.predecessors(node))
                    if parents_node:
                        dep_map[node] = parents_node[0]
                else:
                    dep_map[node] = None

            tag_map = {}
            for path, branch, remote_id, repo_name in global_wtrees:
                node = (repo_name,branch)

                if node in merge_graph:
                    tag = merge_graph.nodes[node].get('tag')
                    tag_map[node] = tag

            with DB(self._db()) as db:
                db.execute("DELETE FROM experiments")
                db.execute("DELETE FROM sqlite_sequence WHERE name='experiments'")
                for path, branch, remote_id, repo_name in global_wtrees:
                    db.execute(
                        "INSERT INTO experiments (branch, repo, remote_id) VALUES (?, ?, ?)",
                        (branch, repo_name, remote_id),
                    )
                
                # -------- fetch mapping --------
                rows = db.execute("SELECT id, repo, branch FROM experiments")

                node_to_id = {
                    (row["repo"], row["branch"]): row["id"]
                    for row in rows
                }

                # -------- update loop --------
                for path, branch, remote_id, repo_name in global_wtrees:
                    node = (repo_name, branch)

                    # -------- tag --------
                    tag = tag_map.get(node)
                    if tag in ("", "None"):
                        tag = None

                    # -------- dependency --------
                    parent = dep_map.get(node)

                    if parent and parent in node_to_id:
                        dep = node_to_id[parent]
                    else:
                        if branch != "main":
                            dep = db.execute(
                                    "SELECT id FROM experiments WHERE repo = ? AND branch = ?",
                                    (repo_name, "main"),
                                )[0]["id"]
                        else:
                            dep = None
                                                    
                    # -------- update --------
                    db.execute(
                        """
                        UPDATE experiments
                        SET dep = ?, tag = ?
                        WHERE branch = ? AND repo = ?
                        """,
                        (dep, tag, branch, repo_name),
                    )
        
        log_message("workspace", value=f"scanned {len(global_wtrees)} entries")


    def _experiment_merge_dependency(self):
        with DB(self._db()) as db:
            G = nx.DiGraph()
            rows = db.execute(
                f"SELECT id, repo, branch, dep, tag FROM experiments"
            )

            id_to_key = {}
            for r in rows:
                if r['tag'] is not None:    
                    key = (r["repo"], r["branch"])
                    id_to_key[r["id"]] = key
                    G.add_node(
                        key,
                        repo=r["repo"],
                        branch=r["branch"],
                        tag=r["tag"]
                    )

            for r in rows:
                if r["dep"]:
                    parent_key = id_to_key.get(r["dep"])
                    child_key = (r["repo"], r["branch"])
                    if parent_key:
                        G.add_edge(parent_key, child_key)
            return G

    def experiment_app_refresh(self) -> None:
        with DB(self._db()) as db:
            rows = db.execute(
                "SELECT repo, branch FROM experiments"
            )
            for row in rows:
                repo = row['repo']
                branch = row['branch']
                tm = Template(repo, branch)
                tm.clean()
                tm.update()
                log_message(key='workspace', value=f"cleaned {branch}")

    def experiment_app_apply_tag(self) -> None:
        import re
        from collections import Counter

        project_base = self._pb()

        def _norm_msg(msg: str) -> str:
            return re.sub(r'^(\[[^]]+\]\s*)+', '', msg.strip())

        def _branch_ref(name: str) -> str:
            return f"refs/heads/{name}"

        def _commit_sig(git: Git, rev: str, cwd) -> tuple[str, tuple[str, ...]]:
            msg = git.git("show", "-s", "--format=%B", rev, cwd=cwd)
            files = git.git("show", "--pretty=", "--name-only", rev, cwd=cwd).splitlines()
            return (
                _norm_msg(msg),
                tuple(sorted(f.strip() for f in files if f.strip())),
            )

        def _rev_list(git: Git, rev: str, cwd) -> list[str]:
            out = git.git("rev-list", "--reverse", _branch_ref(rev), cwd=cwd).strip()
            return [x for x in out.splitlines() if x.strip()] if out else []

        def _logical_exclusive_commits(git: Git, parent_branch: str, branch: str, cwd) -> list[str]:
            parent_revs = _rev_list(git, parent_branch, cwd)
            branch_revs = _rev_list(git, branch, cwd)

            if not branch_revs:
                return []

            parent_sigs = [_commit_sig(git, rev, cwd) for rev in parent_revs]
            branch_sigs = [_commit_sig(git, rev, cwd) for rev in branch_revs]

            parent_counter = Counter(parent_sigs)

            shared_prefix_len = 0
            temp_counter = parent_counter.copy()

            for sig in branch_sigs:
                if temp_counter[sig] > 0:
                    temp_counter[sig] -= 1
                    shared_prefix_len += 1
                else:
                    break

            return branch_revs[shared_prefix_len:]

        def _is_dirty(git: Git, cwd) -> bool:
            status = git.git("status", "--porcelain", cwd=cwd).strip()
            return bool(status)

        def _stash_push(git: Git, repo: str, branch: str, cwd) -> str | None:
            if not _is_dirty(git, cwd):
                log_message("workspace", f"git: Branch {repo}/{branch} is clean, no stash needed")
                return None

            stash_msg = f"ws-sync-auto-stash:{repo}:{branch}"
            log_message("workspace", f"git: Branch {repo}/{branch} is dirty, stashing changes")
            git.git("stash", "push", "-u", "-m", stash_msg, cwd=cwd)
            return stash_msg

        def _stash_pop(git: Git, repo: str, branch: str, cwd, stash_msg: str | None) -> None:
            if not stash_msg:
                return

            stash_list = git.git("stash", "list", cwd=cwd).splitlines()
            stash_ref = None

            for line in stash_list:
                if stash_msg in line:
                    stash_ref = line.split(":", 1)[0]
                    break

            if stash_ref:
                log_message("workspace", f"git: Restoring stashed changes for {repo}/{branch} from {stash_ref}")
                git.git("stash", "pop", stash_ref, cwd=cwd)
            else:
                log_message(
                    "workspace",
                    f"git: No matching stash entry found for {repo}/{branch}; nothing to restore"
                )

        with DB(self._db()) as db:
            log_message("workspace", "git: Starting tag application for experiment branches")

            rows = db.execute(
                "SELECT repo, branch, tag, dep FROM experiments"
            )

            tag_targets = {}

            for row in rows:
                repo = row["repo"]
                branch = row["branch"]
                tag = row["tag"]
                dep = row["dep"]

                if not (tag and dep):
                    log_message(
                        "workspace",
                        f"git: Skipping {repo}/{branch} because tag or dep is missing"
                    )
                    continue

                parent = db.execute(
                    "SELECT repo, branch FROM experiments WHERE id = ?",
                    (dep,)
                )[0]
                parent_branch = parent["branch"]

                repo_path = project_base / repo
                branch_path = repo_path / branch
                git = Git(repo_path=repo_path)

                log_message(
                    "workspace",
                    f"git: Inspecting {repo}/{branch} against parent branch {parent_branch}"
                )

                exclusive_commits = _logical_exclusive_commits(
                    git=git,
                    parent_branch=parent_branch,
                    branch=branch,
                    cwd=repo_path,
                )

                if exclusive_commits:
                    start_commit = exclusive_commits[0]
                    tag_targets[(repo, branch)] = (start_commit, len(exclusive_commits), tag)
                    log_message(
                        "workspace",
                        f"git: Found {len(exclusive_commits)} exclusive commits for {repo}/{branch}; "
                        f"start commit is {start_commit}"
                    )
                else:
                    log_message(
                        "workspace",
                        f"git: No exclusive commits found for {repo}/{branch}; skipping"
                    )

            for (repo, branch), (start_commit, num, tag) in tag_targets.items():
                repo_path = project_base / repo
                branch_path = repo_path / branch
                git = Git(repo_path=repo_path)

                log_message(
                    "workspace",
                    f"git: Preparing to apply tag [{tag}] on {num} commits for {repo}/{branch}"
                )

                stash_msg = None

                try:
                    stash_msg = _stash_push(git, repo, branch, branch_path)

                    rebase_cmd = (
                        'msg="$(git log -1 --format=%B)"; '
                        f'prefix="[{tag}] "; '
                        'case "$msg" in '
                        '"${prefix}"*) exit 0 ;; '
                        '*) printf "%s" "${prefix}${msg}" | git commit --amend --allow-empty -F - ;; '
                        'esac'
                    )

                    log_message(
                        "workspace",
                        f"git: Rebasing {repo}/{branch} from {start_commit}^ with tag [{tag}]"
                    )

                    git.git(
                        "rebase",
                        f"{start_commit}^",
                        "--exec", rebase_cmd,
                        cwd=branch_path
                    )

                    log_message(
                        "workspace",
                        f'git: Applied tag [{tag}] to up to {num} exclusive commits for repo {repo} branch {branch}'
                    )

                finally:
                    _stash_pop(git, repo, branch, branch_path, stash_msg)

            log_message("workspace", "git: Completed tag application for experiment branches")
            
                
    def experiment_app_sel(self, eid: str) -> str:

        shell = detect_shell()

        with DB(self._db()) as db:
            experiment = db.execute(
                "SELECT branch, repo FROM experiments WHERE ID = ?",
                (eid,),
            )

            if not experiment:
                return "cd ."

            experiment = experiment[0]

            repo = experiment["repo"]
            branch = experiment["branch"]
            ppath = self._pb() / repo / branch

            path = str(ppath)
            
            # ------------------ Bash / Zsh ------------------
            if shell in ("bash", "zsh"):
                print(
                    f"export REPO_DIR={quote(repo)}\n"
                    f"export BRANCH_NAME={quote(branch)}\n"
                    f"cd {quote(path)}"
                )

            # ------------------ PowerShell ------------------
            elif shell == "powershell":
                print(
                    f'$env:REPO_DIR="{repo}"\n'
                    f'$env:BRANCH_NAME="{branch}"\n'
                    f'cd "{path}"'
                )

            elif shell == "cmd":
                print(
                    f"set REPO_DIR={repo}\n"
                    f"set BRANCH_NAME={branch}\n"
                    f'cd /d "{path}"'
                )            
            else:
                print("cd .")

    def experiment_app_go(self, target: str) -> str:
        shell = detect_shell()
       
        repo  = need_env()['REPO_DIR']
        branch  = need_env()['BRANCH_NAME']

        tm = Template(repo, branch)
        paths = tm._paths()

        if target == 'code':
            path  = paths.code
        elif target == 'pb':
            path  = paths.pb
        elif target == 'env':
            path  = paths.env
        elif target == 'eb':
            path  = paths.eb
        elif target == 'data':
            path  = paths.data
        elif target == 'files':
            path  = paths.files
        elif target == 'logs':
            path  = paths.logs
        elif target == 'figs':
            path  = paths.figs
        elif target == 'pretrained':
            path  = paths.pretrained        
        elif target == 'snapshots':
            path  = paths.snapshots
        else:
            path  = '.'

        path = str(path)
        
       # ------------------ Bash / Zsh ------------------
        if shell in ("bash", "zsh"):
            print(
                f"export REPO_DIR={quote(repo)}\n"
                f"export BRANCH_NAME={quote(branch)}\n"
                f"cd {quote(path)}"
            )

        # ------------------ PowerShell ------------------
        elif shell == "powershell":
            print(
                f'$env:REPO_DIR="{repo}"\n'
                f'$env:BRANCH_NAME="{branch}"\n'
                f'cd "{path}"'
            )

        elif shell == "cmd":
            print(
                f"set REPO_DIR={repo}\n"
                f"set BRANCH_NAME={branch}\n"
                f'cd /d "{path}"'
            )            
        else:
            print(f"cd {quote(path)}")

    def experiment_app_sync(self, push: bool = False):

        project_base = self._pb()

        G = self._experiment_merge_dependency()

        roots = [n for n in G.nodes if G.in_degree(n) == 0]
        leaves = [n for n in G.nodes if G.out_degree(n) == 0]
            
        chains = []
        for r in roots:
            for l in leaves:
                if nx.has_path(G, r, l):
                    chains.extend(nx.all_simple_paths(G, r, l))
        
        for chain in chains:
            
            # -------- pretty print chain using branch names --------
            branch_chain_str = " → ".join([e[1] for e in chain])

            log_message("workspace", f"chain: {branch_chain_str}")

            processed_branches = []

            for idx, (repo, branch) in enumerate(chain):
                
                repo_path = project_base / repo
                branch_path = repo_path / branch
                git = Git(repo_path=repo_path)
                
                with DB(self._db()) as db:
                    row = db.execute('SELECT id,tag from experiments where branch = ? and repo = ?',(branch,repo))[0]

                exp_id = row['id']
                tag    = row['tag']

                processed_branches.append(branch)

                # ====================================================
                # ROOT (first tagged node)
                # ====================================================
                if idx == 0:
                    log_message('workspace', f"{repo}: Pulling main ↲")
                    git.git("pull", "origin", cwd=f"{repo_path}/main")

                    log_message('workspace', f"{repo}: Rebase {exp_id}. {branch} ({tag}) ➡ main ↲")
                    git.git("rebase", "main", cwd=branch_path)
                # ====================================================
                # STACKED REBASE
                # ====================================================
                else:
                    _, prev_branch = chain[idx - 1]

                    with DB(self._db()) as db:
                        row = db.execute('SELECT id,tag from experiments where branch = ? and repo = ?',(prev_branch,repo))[0]
                    prev_exp_id = row['id']
                    prev_tag    = row['tag']

                    log_message(
                        'workspace',
                        f"{repo}: Rebase {exp_id}. {branch} ({tag}) ➡ {prev_exp_id}. {prev_branch} ({prev_tag}) ↲"
                    )

                    # -------- STRICT TAG MATCH --------
                    pattern = re.compile(rf"\[{re.escape(tag)}\]")

                    # -------- current commits --------
                    curr_commits = git.git(
                        "log",
                        "--pretty=format:%H::%s",
                        cwd=branch_path
                    ).split("\n")

                    keep_commits = []
                    for c in curr_commits:
                        sha, msg = c.split("::", 1)

                        if pattern.search(msg):
                            keep_commits.append(sha)

                    if not keep_commits:
                        log_message(
                            'workspace',
                            f"{repo}: {exp_id}. {branch} WARNING: No commits found for tag [{tag}] ⚠"
                        )

                    # -------- reset to previous branch --------
                    git.git("reset", "--hard", prev_branch, cwd=branch_path)

                    # -------- cherry-pick commits --------
                    for commit in reversed(keep_commits):
                        try:
                            git.git("cherry-pick", commit, cwd=branch_path)
                        except Exception:
                            log_message(repo, f"Skipping conflict {commit} ↲")
                            git.git("cherry-pick", "--abort", cwd=branch_path)

                log_message(
                    'workspace',
                    f"{repo}: {exp_id}. {branch}  Sync prepared ✔"
                )

            # ====================================================
            # 🚀 OPTIONAL PUSH
            # ====================================================
            if push:
                log_message("workspace", f"push: Pushing chain ↲")

                for branch in processed_branches:
                    try:
                        git.git("push", "origin","HEAD","--force",branch)
                        log_message("workspace", f"push: {branch} ✔")
                    except Exception as e:
                        log_message("workspace", f"push: {branch} FAILED ⚠ {e}")
            else:
                log_message("push", "Skipped (push=False)")
