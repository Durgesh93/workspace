import os
import yaml
from pathlib import Path
import shutil
from types import SimpleNamespace

from ..utils import need_env


class Template:

    def __init__(self, project, experiment):
        self.project = project
        self.experiment = experiment
        self.template = Path(__file__).parent / "storage.yaml"

    # ------------------------------------------------------------
    # dict → namespace
    # ------------------------------------------------------------
    def to_ns(self, d):
        if isinstance(d, dict):
            return SimpleNamespace(**{k: self.to_ns(v) for k, v in d.items()})
        elif isinstance(d, list):
            return [self.to_ns(i) for i in d]
        return d

    # ------------------------------------------------------------
    # convert strings → Path (where applicable)
    # ------------------------------------------------------------
    def _to_path(self, obj):
        if isinstance(obj, dict):
            return {k: self._to_path(v) for k, v in obj.items()}

        elif isinstance(obj, list):
            return [self._to_path(v) for v in obj]

        elif isinstance(obj, str):
            # keep non-path values as-is
            if obj in ("", None):
                return obj

            # convert to Path (safe)
            try:
                return Path(obj)
            except Exception:
                return obj

        return obj

    # ------------------------------------------------------------
    # load + resolve template
    # ------------------------------------------------------------
    def _paths(self):
        env = need_env()

        replacements = {
            "PROJ_STORAGE_BASE": env["PROJ_STORAGE_BASE"],
            "EXP_STORAGE_BASE": env["EXP_STORAGE_BASE"],
            "ENV_STORAGE_BASE": env["ENV_STORAGE_BASE"],
            "REPO_DIR": self.project,
            "BRANCH_NAME": self.experiment,
            "ENVIRONMENT": env["ENVIRONMENT"],
        }

        raw = self.template.read_text()
        raw = raw.replace("\\", "/")
        replacements = {
            k: str(v).replace("\\", "/")
            for k, v in replacements.items()
        }
        parsed = yaml.safe_load(raw.format(**replacements))
        parsed = self._to_path(parsed)
        return self.to_ns(parsed)

    # ------------------------------------------------------------
    # CLEAN
    # ------------------------------------------------------------
    def clean(self):
        all_paths = self._paths()

        code_path = Path(all_paths.code)
        files_path = Path(all_paths.files)

        # remove unwanted directories
        for p in code_path.rglob("*"):
            if p.is_dir() and p.name in {"__pycache__", "jobs", "wandb", "dirs"}:
                shutil.rmtree(p, ignore_errors=True)

        # remove *.o and *.e files
        for pattern in ("*.o", "*.e"):
            for f in files_path.glob(pattern):
                try:
                    f.unlink()
                except FileNotFoundError:
                    pass

    # ------------------------------------------------------------
    # PURGE (debug)
    # ------------------------------------------------------------
    def purge(self):
        all_paths = self._paths()
        print(all_paths)

    # ------------------------------------------------------------
    # UPDATE (symlink structure)
    # ------------------------------------------------------------
    def update(self):
        all_paths = self._paths()

        parent = Path(all_paths.vlinks.data).parent
        docker = parent / ".docker"

        parent.mkdir(parents=True, exist_ok=True)
        docker.mkdir(parents=True, exist_ok=True)

        for k, v in vars(all_paths.vlinks).items():
            destination = Path(v)
            source = Path(getattr(all_paths, k))

            # relative structure for docker mirror
            link_folder = destination.relative_to(parent)
            docker_destination = docker / link_folder

            # ensure directories exist
            source.mkdir(parents=True, exist_ok=True)
            docker_destination.mkdir(parents=True, exist_ok=True)
            destination.parent.mkdir(parents=True, exist_ok=True)

            # remove existing destination safely
            if destination.exists() or destination.is_symlink():
                if destination.is_dir() and not destination.is_symlink():
                    shutil.rmtree(destination)
                else:
                    destination.unlink()

            # create symlink
            destination.symlink_to(source, target_is_directory=True)
