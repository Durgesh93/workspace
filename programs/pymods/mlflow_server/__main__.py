import subprocess
import os
import sys
import socket
import signal
from pathlib import Path


class MLFlowManager:

    def __init__(self):
        self.base_path = Path(os.environ["EXP_STORAGE_BASE"].replace("\\", "/")) / "logs"
        self.port = 5000

        self.mlflow_path = self.base_path / "mlflow"
        self.backend_store = self.mlflow_path / "backend.db"
        self.artifacts = self.mlflow_path / "artifacts"

        self.pid_file = self.mlflow_path / "mlflow.pid"
        self.stdout_log = self.mlflow_path / "mlflow_out.log"
        self.stderr_log = self.mlflow_path / "mlflow_err.log"

    def _is_port_open(self):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            return s.connect_ex(("127.0.0.1", self.port)) == 0

    def _is_pid_running(self):
        if not self.pid_file.exists():
            return False

        try:
            pid = int(self.pid_file.read_text().strip())
            os.kill(pid, 0)
            return True
        except Exception:
            return False

    def _ensure_dirs(self):
        self.mlflow_path.mkdir(parents=True, exist_ok=True)
        self.artifacts.mkdir(parents=True, exist_ok=True)

    def _get_pid_on_port(self):
        if os.name == "nt":
            try:
                out = subprocess.check_output(
                    ["netstat", "-ano"],
                    text=True,
                    encoding="utf-8",
                    errors="ignore",
                )
                for line in out.splitlines():
                    line = line.strip()
                    if f"127.0.0.1:{self.port}" in line or f":{self.port}" in line:
                        parts = line.split()
                        if len(parts) >= 5 and parts[-1].isdigit():
                            return int(parts[-1])
            except Exception:
                return None
        else:
            for cmd in (
                ["lsof", "-ti", f"tcp:{self.port}"],
                ["fuser", f"{self.port}/tcp"],
            ):
                try:
                    out = subprocess.check_output(cmd, text=True).strip()
                    if out:
                        pid = out.split()[0]
                        if pid.isdigit():
                            return int(pid)
                except Exception:
                    continue
        return None

    def _kill_pid(self, pid):
        if not pid:
            return

        try:
            if os.name == "nt":
                subprocess.run(
                    ["taskkill", "/PID", str(pid), "/F"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    check=False,
                )
            else:
                os.kill(pid, signal.SIGTERM)
        except Exception as e:
            print(f"[MLflow] Failed to kill PID {pid}: {e}")

    def stop(self):
        stopped_any = False

        if self.pid_file.exists():
            try:
                pid = int(self.pid_file.read_text().strip())
                print(f"[MLflow] Stopping PID from pid file: {pid}")
                self._kill_pid(pid)
                stopped_any = True
            except Exception as e:
                print(f"[MLflow] Could not read pid file: {e}")

        port_pid = self._get_pid_on_port()
        if port_pid:
            print(f"[MLflow] Stopping process on port {self.port}: PID {port_pid}")
            self._kill_pid(port_pid)
            stopped_any = True

        self.pid_file.unlink(missing_ok=True)

        if stopped_any:
            print("[MLflow] Existing server stopped")
        else:
            print("[MLflow] No running server found")

    def start(self):
        self._ensure_dirs()

        # always restart fresh
        self.stop()

        backend_uri = "sqlite:///" + self.backend_store.resolve().as_posix()
        artifact_uri = self.artifacts.resolve().as_uri()

        cmd = [
            sys.executable, "-m", "mlflow", "server",
            "--backend-store-uri", backend_uri,
            "--default-artifact-root", artifact_uri,
            "--host", "127.0.0.1",
            "--port", str(self.port),
        ]

        if os.name == "nt":
            startupinfo = subprocess.STARTUPINFO()
            startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW

            stdout_log = open(self.stdout_log, "w")
            stderr_log = open(self.stderr_log, "w")

            proc = subprocess.Popen(
                cmd,
                creationflags=subprocess.CREATE_NEW_PROCESS_GROUP,
                startupinfo=startupinfo,
                stdin=subprocess.DEVNULL,
                stdout=stdout_log,
                stderr=stderr_log,
                close_fds=False,
            )
        else:
            stdout_log = open(self.stdout_log, "w")
            stderr_log = open(self.stderr_log, "w")

            proc = subprocess.Popen(
                cmd,
                stdin=subprocess.DEVNULL,
                stdout=stdout_log,
                stderr=stderr_log,
                preexec_fn=os.setsid,
                close_fds=True,
            )

        self.pid_file.write_text(str(proc.pid))
        print(f"[MLflow] Started fresh (PID={proc.pid})")


if __name__ == "__main__":
    mlflow = MLFlowManager()
    mlflow.start()