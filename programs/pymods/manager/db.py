import sqlite3
from pathlib import Path
from typing import Any, Mapping, Optional, Sequence, Union

Params = Optional[Union[Sequence[Any], Mapping[str, Any]]]


class DB:
    def __init__(self, db_path: Optional[str] = None) -> None:
        """
        SQLite DB wrapper.

        If db_path is not provided, the database will be created under:
        workspace/db/experiments.sqlite

        Expected structure:
        workspace/
        ├── db/
        │   └── experiments.sqlite
        └── programs/
            └── pymods/
                └── manager/
                    └── db.py
        """

        if db_path is None:
            # db.py is inside: workspace/programs/pymods/manager/db.py
            # parents[0] = manager
            # parents[1] = pymods
            # parents[2] = programs
            # parents[3] = workspace
            workspace_root = Path(__file__).resolve().parents[3]
            self.db_path = workspace_root / "db" / "experiments.sqlite"
        else:
            self.db_path = Path(db_path).expanduser().resolve()

        # Create db folder if it does not exist
        self.db_path.parent.mkdir(parents=True, exist_ok=True)

        self.conn: sqlite3.Connection = sqlite3.connect(str(self.db_path))
        self.conn.row_factory = sqlite3.Row
        self.cursor: sqlite3.Cursor = self.conn.cursor()

        self._create_table()

    # --------------------------------------------------
    # Create tables
    # --------------------------------------------------
    def _create_table(self) -> None:
        self.cursor.execute("PRAGMA foreign_keys = ON")

        self.cursor.execute("""
            CREATE TABLE IF NOT EXISTS remotes (
                remote_id INTEGER PRIMARY KEY AUTOINCREMENT,
                url TEXT DEFAULT NULL
            )
        """)

        self.cursor.execute("""
            CREATE TABLE IF NOT EXISTS experiments (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                branch TEXT DEFAULT NULL,
                repo TEXT DEFAULT NULL,
                dep INTEGER DEFAULT NULL,
                tag TEXT DEFAULT NULL,
                remote_id INTEGER DEFAULT NULL,
                FOREIGN KEY (remote_id)
                    REFERENCES remotes(remote_id)
                    ON DELETE SET NULL
                    ON UPDATE CASCADE
            )
        """)

        self.conn.commit()

    # --------------------------------------------------
    # Context manager support
    # --------------------------------------------------
    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        if exc_type:
            self.conn.rollback()
        else:
            self.conn.commit()
        self.close()

    # --------------------------------------------------
    # Core execute
    # --------------------------------------------------
    def execute(self, query: str, params: Params = None):
        try:
            use_plain = (
                params is None
                or (isinstance(params, Mapping) and len(params) == 0)
                or (
                    isinstance(params, Sequence)
                    and not isinstance(params, (str, bytes))
                    and len(params) == 0
                )
            )

            if use_plain:
                self.cursor.execute(query)
            else:
                self.cursor.execute(query, params)

            first_token = query.lstrip().split(None, 1)[0].lower()

            if first_token in ("select", "with", "pragma"):
                rows = self.cursor.fetchall()
                return [dict(row) for row in rows]

            if first_token == "insert":
                self.conn.commit()
                return self.cursor.lastrowid

            self.conn.commit()
            return self.cursor.rowcount

        except Exception:
            self.conn.rollback()
            raise

    # --------------------------------------------------
    # Utility
    # --------------------------------------------------
    def get_db_path(self) -> str:
        return str(self.db_path)

    # --------------------------------------------------
    # Close
    # --------------------------------------------------
    def close(self) -> None:
        self.conn.close()
