from pathlib import Path
from rich.console import Console
from rich.tree import Tree
import argparse
import sys

EXCLUDED_NAMES = {"__pycache__", ".docker"}

def build_rich_tree(directory: Path, parent_tree: Tree, level: int, max_level: int):
    """Recursively build a Rich Tree up to max_level, excluding __pycache__, .docker, and hidden files."""
    if level > max_level:
        return

    try:
        entries = sorted(directory.iterdir(), key=lambda x: (not x.is_dir(), x.name.lower()))
    except PermissionError:
        parent_tree.add("[red][Permission Denied][/red]")
        return

    # Filter out hidden files/folders and excluded names
    visible_entries = [
        e for e in entries
        if not e.name.startswith(".") and e.name not in EXCLUDED_NAMES
    ]

    if not visible_entries:
        parent_tree.add("[dim]∅ empty[/dim]")

    for entry in visible_entries:
        if entry.is_dir():
            branch = parent_tree.add(f"📁 [bold cyan]{entry.name}[/bold cyan]")
            build_rich_tree(entry, branch, level + 1, max_level)
        else:
            parent_tree.add(f"📄 {entry.name}")

def main():
    parser = argparse.ArgumentParser(description="Pretty-print directory tree using rich.")
    parser.add_argument("path", nargs="?", default=".", help="Path to directory (default: current directory)")
    parser.add_argument("-L", "--level", type=int, default=999, help="Max display depth (like tree -L)")

    args = parser.parse_args()
    root_path = Path(args.path).resolve()

    if not root_path.is_dir():
        Console().print(f"[red]Error: '{root_path}' is not a valid directory.[/red]")
        sys.exit(1)

    console = Console()
    tree = Tree(f"🌲 [bold green]{root_path}[/bold green]")
    build_rich_tree(root_path, tree, level=1, max_level=args.level)
    console.print(tree)

if __name__ == "__main__":
    main()
