from __future__ import annotations

from pathlib import Path
from typing import Optional

import typer

# Local modules
from .utils import need_env
from .mixin import (
    ShowMixin,
    UpdateMixin,
    ExperimentMixin,
    RemotesMixin
)

# ---------------------------------------------------------------------
# Core Workspace Singleton
# ---------------------------------------------------------------------
class Workspace(
    ShowMixin,
    UpdateMixin,
    ExperimentMixin,
    RemotesMixin,
):
    _instance: Optional["Workspace"] = None

    def __new__(cls, *args, **kwargs):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance

    def _db(self) -> Path:
        env = need_env()
        return Path(env["ENV_STORAGE_BASE"].replace('\\','/')) / "db" / "workspace_config.db"

    def _pb(self) -> Path:
        env = need_env()
        return Path(env["PROJ_STORAGE_BASE"].replace('\\','/'))


# ---------------------------------------------------------------------
# Typer App Setup
# ---------------------------------------------------------------------
app = typer.Typer(help="Workspace Manager CLI")
update_app = typer.Typer(help="Update operations")
show_app = typer.Typer(help="Show operations")
experiment_app = typer.Typer(help="Experiment operations")

app.add_typer(update_app, name="update")
app.add_typer(show_app, name="show")
app.add_typer(experiment_app, name="experiment")



# ---------------------------------------------------------------------
# Experiment Commands
# ---------------------------------------------------------------------

@experiment_app.command("sel")
def cmd_experiment_app_sel(
    eid: str = typer.Argument(..., help="Experiment selector, e.g.'eid'")
):
    """Select experiment and return its absolute path."""
    Workspace().experiment_app_sel(eid)

@experiment_app.command("go")
def cmd_experiment_app_go(
    target: str = typer.Argument("code", help="Experiment go target: pb, data, logs, files, etc.")
):
    """Select experiment and return its absolute path."""
    Workspace().experiment_app_go(target)


@experiment_app.command("refresh")
def experiment_refresh():
    """Refresh experiment directories."""
    Workspace().experiment_app_refresh()

@experiment_app.command("scan")
def cmd_experiment_and_remotes_app_scan():
    """Scan git projects and refresh DB from worktrees."""
    Workspace().remotes_app_scan_remotes()
    Workspace().experiment_app_scan_experiments()


@experiment_app.command("sync")
def cmd_experiment_app_sync(
    push: bool = typer.Option(False, "--push", help="Push all branches in the chain")
):
    """Sync experiment (git worktree or local folder)."""
    Workspace().experiment_app_apply_tag()
    Workspace().experiment_app_sync(push=push)

# ---------------------------------------------------------------------
# Show Commands
# ---------------------------------------------------------------------

@show_app.command("remotes")
def show_remotes():
    """Show configured remotes."""
    Workspace().show_app_remotes()

@show_app.command("experiments")
def show_experiments():
    """Show current experiments."""
    Workspace().show_app_experiments()


# ---------------------------------------------------------------------
# Update Commands
# ---------------------------------------------------------------------
@update_app.command("dep")
def update_dependency(
    q: str = typer.Argument(..., help="Source ID -> Target ID"),
):
    Workspace().update_dependency(q)

@update_app.command("tag")
def update_add_or_update_tag(
    target_id: str = typer.Argument(..., help="Target EID"),
    tag: str = typer.Argument(..., help="Tag value"),
):
    Workspace().update_app_add_or_update_tag(target_id, tag)


@update_app.command("add_remote")
def update_add_remote(
    remote_path: str = typer.Argument(..., help="Remote path"),
):
    Workspace().update_app_add_remote(remote_path)

@update_app.command("del_remote")
def update_del_remote(
    remote_id: str = typer.Argument(..., help="Remote ID"),
):
    Workspace().update_app_del_remote(remote_id)

# ---------------------------------------------------------------------
# Entry Point
# ---------------------------------------------------------------------

if __name__ == "__main__":
    app()