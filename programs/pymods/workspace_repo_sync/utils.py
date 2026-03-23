import os
import platform
import shutil


def need_env() -> dict[str, str]:
    """
    Ensure Git editor is set and return full environment.
    """

    # Set Git editor only if not already defined
    if not any(os.environ.get(k) for k in ("GIT_EDITOR", "VISUAL", "EDITOR")):
        system = platform.system()

        if system == "Windows":
            editor = "code --wait" if shutil.which("code") else "notepad"
        else:
            if shutil.which("nano"):
                editor = "nano"
            elif shutil.which("vim"):
                editor = "vim"
            else:
                editor = "vi"

        os.environ["GIT_EDITOR"] = editor

    return dict(os.environ)


def detect_shell() -> str:
    """
    Best-effort shell detection.
    Returns: 'bash', 'zsh', 'powershell', or 'cmd'
    """

    # ------------------ Windows ------------------
    if os.name == "nt":
        # PowerShell indicators
        if os.environ.get("PSModulePath") or os.environ.get("PROMPT", "").startswith("PS"):
            return "powershell"

        # cmd.exe indicators
        if os.environ.get("COMSPEC", "").lower().endswith("cmd.exe"):
            return "cmd"

        # fallback (modern default)
        return "powershell"

    # ------------------ Unix ------------------
    shell = os.environ.get("SHELL", "").lower()

    if "zsh" in shell:
        return "zsh"
    if "bash" in shell:
        return "bash"

    # Git Bash / MSYS
    if "MINGW" in os.environ.get("MSYSTEM", ""):
        return "bash"

    return "bash"
