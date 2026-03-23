import subprocess
import os
import sys
import time
import socket
from pathlib import Path


class MLFlowManager:

    def __init__(self):
        self.base_path = Path(os.environ['EXP_STORAGE_BASE'].replace('\\', '/')) / 'logs'
        self.port = 5000

        self.mlflow_path = self.base_path / "mlflow"
        self.backend_store = self.mlflow_path / "backend.db"
        self.artifacts = self.mlflow_path / "artifacts"

        self.pid_file = self.mlflow_path / "mlflow.pid"

    # ---------------------------------------------------------
    # Check if port is already in use
    # ---------------------------------------------------------
    def _is_port_open(self):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            return s.connect_ex(("127.0.0.1", self.port)) == 0

    # ---------------------------------------------------------
    # Check if PID is alive
    # ---------------------------------------------------------
    def _is_pid_running(self):
        if not self.pid_file.exists():
            return False

        try:
            pid = int(self.pid_file.read_text().strip())
            os.kill(pid, 0)
            return True
        except Exception:
            return False

    # ---------------------------------------------------------
    # Ensure dirs
    # ---------------------------------------------------------
    def _ensure_dirs(self):
        self.mlflow_path.mkdir(parents=True, exist_ok=True)
        self.artifacts.mkdir(parents=True, exist_ok=True)

    # ---------------------------------------------------------
    # Start server (detached)
    # ---------------------------------------------------------
    def start(self):

        self._ensure_dirs()

        # -------- prevent duplicates --------
        if self._is_pid_running() or self._is_port_open():
            print("[MLflow] Already running. Skipping.")
            return

        backend_uri = f"sqlite:///{self.backend_store}"
        artifact_uri = str(self.artifacts)

        cmd = [
            sys.executable, "-m", "mlflow", "server",
            "--backend-store-uri", backend_uri,
            "--default-artifact-root", artifact_uri,
            "--host", "127.0.0.1",
            "--port", str(self.port),
        ]

        # -------- Windows --------
        if os.name == "nt":
            # Hide the new console window
            startupinfo = subprocess.STARTUPINFO()
            startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW

            # Write logs to files instead of discarding
            stdout_log = open("mlflow_out.log", "w")
            stderr_log = open("mlflow_err.log", "w")

            proc = subprocess.Popen(
                cmd,
                creationflags=subprocess.CREATE_NEW_PROCESS_GROUP,
                startupinfo=startupinfo,
                stdin=subprocess.DEVNULL,
                stdout=stdout_log,
                stderr=stderr_log,
                close_fds=False  # <-- CRITICAL FIX
            )
            
        # -------- Linux / macOS --------
        else:
            proc = subprocess.Popen(
                cmd,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                preexec_fn=os.setsid,
                close_fds=True
            )

        # -------- save PID --------
        self.pid_file.write_text(str(proc.pid))

        print(f"[MLflow] Started (PID={proc.pid})")

    # ---------------------------------------------------------
    # Stop server
    # ---------------------------------------------------------
    def stop(self):

        if not self.pid_file.exists():
            print("[MLflow] No running server.")
            return

        pid = int(self.pid_file.read_text())

        try:
            if os.name == "nt":
                subprocess.run(["taskkill", "/PID", str(pid), "/F"],
                               stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL)
            else:
                os.kill(pid, 15)

            print(f"[MLflow] Stopped (PID={pid})")

        except Exception as e:
            print(f"[MLflow] Failed to stop: {e}")

        finally:
            self.pid_file.unlink(missing_ok=True)


if __name__ == "__main__":
    MLFlowManager().start()