import json
import sqlite3
import threading
import uuid
from pathlib import Path
from typing import Any, Optional


DB_FILE = Path("/agibot/data/var/agent/data/offline.db")


class EventStore:
    """
    Agent 本地事件存储。

    所有需要可靠上传到后端的数据，
    都先写入 SQLite。

    Backend 上传成功后再删除。
    """

    def __init__(self, db_file: Path = DB_FILE):
        self.db_file = db_file

        self.db_file.parent.mkdir(
            parents=True,
            exist_ok=True,
        )

        self._lock = threading.Lock()

        self._initialize()

    # ========================================================
    # Database
    # ========================================================

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(
            self.db_file,
            timeout=10,
        )

        connection.row_factory = sqlite3.Row

        return connection

    def _initialize(self):
        with self._lock:

            connection = self._connect()

            try:
                connection.execute(
                    """
                    PRAGMA journal_mode=WAL
                    """
                )

                connection.execute(
                    """
                    PRAGMA synchronous=NORMAL
                    """
                )

                connection.execute(
                    """
                    CREATE TABLE IF NOT EXISTS events (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        event_uuid TEXT NOT NULL UNIQUE,
                        event_type TEXT NOT NULL,
                        event_time TEXT NOT NULL,
                        payload TEXT NOT NULL,
                        created_at TEXT NOT NULL
                    )
                    """
                )

                connection.execute(
                    """
                    CREATE INDEX IF NOT EXISTS
                    idx_events_id
                    ON events(id)
                    """
                )

                connection.commit()

            finally:
                connection.close()

    # ========================================================
    # Write
    # ========================================================

    def append(
        self,
        event_type: str,
        event_time: str,
        payload: dict[str, Any],
    ) -> str:
        """
        写入一条本地事件。

        返回：
            event_uuid
        """

        event_uuid = str(uuid.uuid4())

        with self._lock:

            connection = self._connect()

            try:

                connection.execute(
                    """
                    INSERT INTO events (
                        event_uuid,
                        event_type,
                        event_time,
                        payload,
                        created_at
                    )
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    (
                        event_uuid,
                        event_type,
                        event_time,
                        json.dumps(
                            payload,
                            ensure_ascii=False,
                        ),
                        event_time,
                    ),
                )

                connection.commit()

            finally:
                connection.close()

        return event_uuid

    # ========================================================
    # Read
    # ========================================================

    def get_batch(
        self,
        limit: int = 100,
    ) -> list[dict[str, Any]]:
        """
        获取最早的一批未上传事件。
        """

        with self._lock:

            connection = self._connect()

            try:

                rows = connection.execute(
                    """
                    SELECT
                        id,
                        event_uuid,
                        event_type,
                        event_time,
                        payload
                    FROM events
                    ORDER BY id ASC
                    LIMIT ?
                    """,
                    (limit,),
                ).fetchall()

            finally:
                connection.close()

        result = []

        for row in rows:

            result.append(
                {
                    "id": row["id"],
                    "event_uuid": row["event_uuid"],
                    "event_type": row["event_type"],
                    "event_time": row["event_time"],
                    "payload": json.loads(
                        row["payload"]
                    ),
                }
            )

        return result

    # ========================================================
    # Delete
    # ========================================================

    def delete_until(self, event_id: int):
        """
        删除已经被后端确认处理的事件。
        """

        with self._lock:

            connection = self._connect()

            try:

                connection.execute(
                    """
                    DELETE FROM events
                    WHERE id <= ?
                    """,
                    (event_id,),
                )

                connection.commit()

            finally:
                connection.close()

    # ========================================================
    # Statistics
    # ========================================================

    def count(self) -> int:

        with self._lock:

            connection = self._connect()

            try:

                row = connection.execute(
                    """
                    SELECT COUNT(*) AS count
                    FROM events
                    """
                ).fetchone()

                return int(row["count"])

            finally:
                connection.close()