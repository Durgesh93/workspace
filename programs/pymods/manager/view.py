from typing import List, Dict
import typer
from itertools import cycle

def print_table(
    rows: List[Dict[str, str]],
    headers: List[str],
    title: str = "My Experiments",
) -> None:
    if not rows:
        typer.secho("(no rows)", fg=typer.colors.WHITE, dim=True)
        return

    typer.secho(title, bold=True)
    typer.echo()

    # column widths
    col_widths = {
        h: max(len(h), *(len(str(row.get(h, ""))) for row in rows))
        for h in headers
    }

    # header
    header_line = "  ".join(f"{h:<{col_widths[h]}}" for h in headers)
    typer.secho(header_line, bold=True)
    typer.echo("  ".join("-" * col_widths[h] for h in headers))

    # 🎨 cycle through typer colors
    color_cycle = cycle([
        typer.colors.BLUE,
        typer.colors.GREEN,
        typer.colors.CYAN,
        typer.colors.MAGENTA,
        typer.colors.YELLOW,
        typer.colors.RED,
        typer.colors.WHITE,
    ])

    # rows
    for row in rows:
        color = next(color_cycle)

        line = "  ".join(
            f"{str(row.get(h, '')):<{col_widths[h]}}" for h in headers
        )

        typer.secho(line, fg=color)

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
