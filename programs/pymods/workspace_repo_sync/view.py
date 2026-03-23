from typing import List, Dict
import typer
from itertools import cycle

def log_message(
    key: str = "",
    value: str = "",
    level: str = "info",
    exit_on_error: bool = True,
    exit_code: int = 1,
) -> None:
    """
    Print a formatted log message with preset styles.

    Args:
        key: Left part of message
        value: Right part of message
        level: "info" | "error"
        exit_on_error: Exit program if level == "error"
        exit_code: Exit code to use
    """

    if level == "error":
        key_color = typer.colors.RED
        value_color = typer.colors.YELLOW
        arrow_color = typer.colors.RED
    else:
        key_color = typer.colors.BLUE
        value_color = typer.colors.CYAN
        arrow_color = typer.colors.CYAN

    typer.secho(key, fg=key_color, bold=True, nl=False)
    typer.secho(" -> ", fg=arrow_color, nl=False)
    typer.secho(value, fg=value_color)

    # ✅ exit on error if requested
    if level == "error" and exit_on_error:
        raise typer.Exit(code=exit_code)
