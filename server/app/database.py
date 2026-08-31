import json
import sqlite3
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


class Database:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.connection = sqlite3.connect(path, check_same_thread=False)
        self.connection.row_factory = sqlite3.Row
        self.lock = threading.RLock()
        with self.lock:
            self.connection.execute("PRAGMA journal_mode=WAL")
            self.connection.execute("PRAGMA foreign_keys=ON")
            self.connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS runs (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    repeat INTEGER NOT NULL DEFAULT 0,
                    run_mode TEXT NOT NULL DEFAULT 'normal',
                    status TEXT NOT NULL,
                    current_pose TEXT,
                    step_index INTEGER NOT NULL DEFAULT 0,
                    cycle_count INTEGER NOT NULL DEFAULT 0,
                    started_at TEXT NOT NULL,
                    finished_at TEXT,
                    error TEXT
                );

                CREATE TABLE IF NOT EXISTS events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    run_id INTEGER,
                    event_type TEXT NOT NULL,
                    name TEXT NOT NULL,
                    payload TEXT NOT NULL DEFAULT '{}',
                    raw TEXT,
                    created_at TEXT NOT NULL,
                    FOREIGN KEY (run_id) REFERENCES runs(id)
                );

                CREATE INDEX IF NOT EXISTS idx_events_run_id_id ON events(run_id, id);
                CREATE INDEX IF NOT EXISTS idx_events_created_at ON events(created_at);

                CREATE TABLE IF NOT EXISTS calibration_state (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    generation INTEGER NOT NULL DEFAULT 0,
                    reset_at TEXT NOT NULL
                );

                INSERT OR IGNORE INTO calibration_state(id,generation,reset_at)
                VALUES(1,0,'1970-01-01T00:00:00.000Z');

                CREATE TABLE IF NOT EXISTS run_reviews (
                    run_id INTEGER PRIMARY KEY,
                    verdict TEXT NOT NULL CHECK (verdict IN ('normal','abnormal')),
                    causes TEXT NOT NULL DEFAULT '[]',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    FOREIGN KEY (run_id) REFERENCES runs(id) ON DELETE CASCADE
                );

                CREATE INDEX IF NOT EXISTS idx_runs_calibration
                ON runs(repeat,status,finished_at);

                CREATE INDEX IF NOT EXISTS idx_runs_calibration_started
                ON runs(repeat,status,started_at);
                """
            )
            run_columns = {
                str(row["name"])
                for row in self.connection.execute("PRAGMA table_info(runs)").fetchall()
            }
            if "run_mode" not in run_columns:
                self.connection.execute(
                    "ALTER TABLE runs "
                    "ADD COLUMN run_mode TEXT NOT NULL DEFAULT 'normal'"
                )
            self.connection.commit()

    @staticmethod
    def _run(row: sqlite3.Row | None) -> dict[str, Any] | None:
        if row is None:
            return None
        item = dict(row)
        item["repeat"] = bool(item["repeat"])
        return item

    @staticmethod
    def _event(row: sqlite3.Row) -> dict[str, Any]:
        item = dict(row)
        try:
            item["payload"] = json.loads(item["payload"])
        except (TypeError, json.JSONDecodeError):
            item["payload"] = {"value": item["payload"]}
        return item

    @staticmethod
    def _review(row: sqlite3.Row) -> dict[str, Any]:
        item = dict(row)
        try:
            causes = json.loads(item["causes"])
        except (TypeError, json.JSONDecodeError):
            causes = []
        item["causes"] = causes if isinstance(causes, list) else []
        return item

    def recover_interrupted_runs(self) -> list[int]:
        with self.lock:
            rows = self.connection.execute(
                "SELECT id FROM runs WHERE status IN ('running', 'stopping')"
            ).fetchall()
            ids = [int(row["id"]) for row in rows]
            now = utc_now()
            for run_id in ids:
                self.connection.execute(
                    "UPDATE runs SET status='interrupted', finished_at=?, error=? WHERE id=?",
                    (now, "Server restarted while the run was active", run_id),
                )
                self.connection.execute(
                    "INSERT INTO events(run_id,event_type,name,payload,created_at) VALUES(?,?,?,?,?)",
                    (
                        run_id,
                        "F",
                        "RUN_INTERRUPTED",
                        json.dumps({"reason": "server_restart"}, separators=(",", ":")),
                        now,
                    ),
                )
            self.connection.commit()
            return ids

    def create_run(
        self, repeat: bool, run_mode: str = "normal"
    ) -> dict[str, Any]:
        now = utc_now()
        with self.lock:
            cursor = self.connection.execute(
                "INSERT INTO runs(repeat,run_mode,status,started_at) VALUES(?,?,?,?)",
                (int(repeat), run_mode, "running", now),
            )
            self.connection.commit()
            return self.get_run(int(cursor.lastrowid))

    def get_run(self, run_id: int) -> dict[str, Any] | None:
        with self.lock:
            row = self.connection.execute("SELECT * FROM runs WHERE id=?", (run_id,)).fetchone()
            return self._run(row)

    def list_runs(self, limit: int, offset: int) -> list[dict[str, Any]]:
        with self.lock:
            rows = self.connection.execute(
                "SELECT * FROM runs ORDER BY id DESC LIMIT ? OFFSET ?", (limit, offset)
            ).fetchall()
            return [self._run(row) for row in rows]

    def update_run(self, run_id: int, **values: Any) -> dict[str, Any] | None:
        allowed = {
            "status",
            "current_pose",
            "step_index",
            "cycle_count",
            "finished_at",
            "error",
        }
        updates = {key: value for key, value in values.items() if key in allowed}
        if not updates:
            return self.get_run(run_id)
        assignments = ", ".join(f"{key}=?" for key in updates)
        with self.lock:
            self.connection.execute(
                f"UPDATE runs SET {assignments} WHERE id=?", (*updates.values(), run_id)
            )
            self.connection.commit()
            return self.get_run(run_id)

    def add_event(
        self,
        run_id: int | None,
        event_type: str,
        name: str,
        payload: dict[str, Any] | None = None,
        raw: str | None = None,
    ) -> dict[str, Any]:
        now = utc_now()
        encoded = json.dumps(payload or {}, ensure_ascii=False, separators=(",", ":"))
        with self.lock:
            cursor = self.connection.execute(
                "INSERT INTO events(run_id,event_type,name,payload,raw,created_at) "
                "VALUES(?,?,?,?,?,?)",
                (run_id, event_type, name, encoded, raw, now),
            )
            self.connection.commit()
            row = self.connection.execute(
                "SELECT * FROM events WHERE id=?", (int(cursor.lastrowid),)
            ).fetchone()
            return self._event(row)

    def list_events(
        self, run_id: int | None, limit: int, after_id: int | None = None
    ) -> list[dict[str, Any]]:
        clauses: list[str] = []
        parameters: list[Any] = []
        if run_id is not None:
            clauses.append("run_id=?")
            parameters.append(run_id)
        if after_id is not None:
            clauses.append("id>?")
            parameters.append(after_id)
        where = " WHERE " + " AND ".join(clauses) if clauses else ""
        order = "ASC" if after_id is not None else "DESC"
        with self.lock:
            rows = self.connection.execute(
                f"SELECT * FROM events{where} ORDER BY id {order} LIMIT ?",
                (*parameters, limit),
            ).fetchall()
            return [self._event(row) for row in rows]

    def calibration_status(self, required_samples: int) -> dict[str, Any]:
        required = max(1, int(required_samples))
        with self.lock:
            state = self.connection.execute(
                "SELECT generation,reset_at FROM calibration_state WHERE id=1"
            ).fetchone()
            reset_at = str(state["reset_at"])
            counts = self.connection.execute(
                """
                SELECT
                    COUNT(rr.run_id) AS labeled_samples,
                    COALESCE(SUM(CASE WHEN rr.verdict='normal' THEN 1 ELSE 0 END),0)
                        AS normal_samples,
                    COALESCE(SUM(CASE WHEN rr.verdict='abnormal' THEN 1 ELSE 0 END),0)
                        AS abnormal_samples
                FROM runs AS r
                LEFT JOIN run_reviews AS rr ON rr.run_id=r.id
                WHERE r.repeat=0
                  AND r.status='completed'
                  AND r.finished_at IS NOT NULL
                  AND r.started_at>=?
                """,
                (reset_at,),
            ).fetchone()
            latest = self.connection.execute(
                """
                SELECT r.*
                FROM runs AS r
                LEFT JOIN run_reviews AS rr ON rr.run_id=r.id
                WHERE r.repeat=0
                  AND r.status='completed'
                  AND r.finished_at IS NOT NULL
                  AND r.started_at>=?
                  AND rr.run_id IS NULL
                ORDER BY r.finished_at DESC, r.id DESC
                LIMIT 1
                """,
                (reset_at,),
            ).fetchone()

            labeled = int(counts["labeled_samples"])
            return {
                "required_samples": required,
                "labeled_samples": labeled,
                "normal_samples": int(counts["normal_samples"]),
                "abnormal_samples": int(counts["abnormal_samples"]),
                "remaining_samples": max(required - labeled, 0),
                "repeat_unlocked": labeled >= required,
                "generation": int(state["generation"]),
                "reset_at": reset_at,
                "latest_unreviewed_run": self._run(latest),
            }

    def save_run_review(
        self,
        run_id: int,
        verdict: str = "normal",
        causes: list[str] | None = None,
    ) -> dict[str, Any]:
        normalized_verdict = verdict.strip().lower()
        if normalized_verdict not in {"normal", "abnormal"}:
            raise ValueError("verdict must be 'normal' or 'abnormal'")

        normalized_causes: list[str] = []
        seen: set[str] = set()
        for cause in causes or []:
            if not isinstance(cause, str):
                raise ValueError("causes must contain strings")
            value = cause.strip()
            if value and value not in seen:
                normalized_causes.append(value)
                seen.add(value)
        if normalized_verdict == "normal":
            normalized_causes = []
        elif not normalized_causes:
            raise ValueError("abnormal reviews require at least one cause")

        with self.lock:
            eligible = self.connection.execute(
                """
                SELECT r.id
                FROM runs AS r
                CROSS JOIN calibration_state AS cs
                WHERE cs.id=1
                  AND r.id=?
                  AND r.repeat=0
                  AND r.status='completed'
                  AND r.finished_at IS NOT NULL
                  AND r.started_at>=cs.reset_at
                """,
                (run_id,),
            ).fetchone()
            if eligible is None:
                raise LookupError(
                    "run must be a completed non-repeat run after the latest reset"
                )

            now = utc_now()
            encoded_causes = json.dumps(
                normalized_causes, ensure_ascii=False, separators=(",", ":")
            )
            self.connection.execute(
                """
                INSERT INTO run_reviews(run_id,verdict,causes,created_at,updated_at)
                VALUES(?,?,?,?,?)
                ON CONFLICT(run_id) DO UPDATE SET
                    verdict=excluded.verdict,
                    causes=excluded.causes,
                    updated_at=excluded.updated_at
                """,
                (run_id, normalized_verdict, encoded_causes, now, now),
            )
            self.connection.commit()
            row = self.connection.execute(
                "SELECT * FROM run_reviews WHERE run_id=?", (run_id,)
            ).fetchone()
            return self._review(row)

    def reset_calibration(self) -> dict[str, Any]:
        now = utc_now()
        with self.lock:
            self.connection.execute("DELETE FROM run_reviews")
            self.connection.execute(
                """
                UPDATE calibration_state
                SET generation=generation+1, reset_at=?
                WHERE id=1
                """,
                (now,),
            )
            self.connection.commit()
            row = self.connection.execute(
                "SELECT generation,reset_at FROM calibration_state WHERE id=1"
            ).fetchone()
            return {
                "generation": int(row["generation"]),
                "reset_at": str(row["reset_at"]),
            }

    def close(self) -> None:
        with self.lock:
            self.connection.close()
