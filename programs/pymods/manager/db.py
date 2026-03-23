import sqlite3
from typing import Any, Mapping, Optional, Sequence, Union, Callable

Params = Optional[Union[Sequence[Any], Mapping[str, Any]]]
Row = tuple[Any, ...]


class DB:
    def __init__(self, db_path: str) -> None:
        self.db_path = db_path
        self.conn: sqlite3.Connection = sqlite3.connect(self.db_path)
        self.conn.row_factory = sqlite3.Row
        self.cursor: sqlite3.Cursor = self.conn.cursor() 
        self._create_table()

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
                branch TEXT NULL,
                repo TEXT NULL, 
                dep INTEGER DEFAULT NULL,
                tag TEXT DEFAULT NULL,
                remote_id INTEGER,
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
        if exc:
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
                return [dict(r) for r in rows]

            if first_token == "insert":
                self.conn.commit()
                return self.cursor.lastrowid

            self.conn.commit()
            return self.cursor.rowcount

        except Exception:
            self.conn.rollback()
            raise

    # --------------------------------------------------
    # Close
    # --------------------------------------------------
    def close(self):
        self.conn.close()
