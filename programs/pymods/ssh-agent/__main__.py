#!/usr/bin/env python3
from __future__ import annotations

import os
import subprocess
from pathlib import Path


# ------------------------------------------------------------
# helpers
# ------------------------------------------------------------
def run(cmd, env=None):
    return subprocess.run(cmd, text=True, capture_output=True, env=env)


def detect_key_dir() -> Path:
    return Path.home() / ".ssh"


# ------------------------------------------------------------
# find existing agent
# ------------------------------------------------------------
def find_agent():
    sock = os.environ.get("SSH_AUTH_SOCK")
    pid = os.environ.get("SSH_AGENT_PID")

    if sock and Path(sock).exists():
        return sock, pid

    return None, None


# ------------------------------------------------------------
# start new agent
# ------------------------------------------------------------
def start_agent():
    out = run(["ssh-agent", "-s"]).stdout

    env = {}
    for line in out.splitlines():
        if "=" in line and ";" in line:
            key, val = line.split(";", 1)[0].split("=", 1)
            env[key.strip()] = val.strip()

    return env["SSH_AUTH_SOCK"], env["SSH_AGENT_PID"]


# ------------------------------------------------------------
# add keys
# ------------------------------------------------------------
def add_keys(sock, pid, key_dir: Path):
    env = os.environ.copy()
    env["SSH_AUTH_SOCK"] = sock
    env["SSH_AGENT_PID"] = pid

    if not key_dir.exists():
        return

    for key in key_dir.iterdir():
        if key.is_file() and key.suffix != ".pub":
            try:
                key.chmod(0o600)
            except Exception:
                pass
            run(["ssh-add", str(key)], env=env)


# ------------------------------------------------------------
# print exports (bash only)
# ------------------------------------------------------------
def print_exports(sock, pid):
    print(f'export SSH_AUTH_SOCK="{sock}"; export SSH_AGENT_PID="{pid}";')


# ------------------------------------------------------------
# main
# ------------------------------------------------------------
def main():
    key_dir = detect_key_dir()

    sock, pid = find_agent()

    if not sock:
        sock, pid = start_agent()

    add_keys(sock, pid, key_dir)

    print_exports(sock, pid)


if __name__ == "__main__":
    main()