import json
import sqlite3
import threading
from contextlib import nullcontext
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

                CREATE TABLE IF NOT EXISTS rpf_records (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    run_id INTEGER,
                    cycle_index INTEGER,
                    product_id TEXT,
                    product_group TEXT,
                    status TEXT,
                    started_at TEXT,
                    finished_at TEXT,
                    work_time_ms INTEGER,
                    retry_count INTEGER NOT NULL DEFAULT 0,
                    error_count INTEGER NOT NULL DEFAULT 0,
                    operator_interventions INTEGER NOT NULL DEFAULT 0,
                    grade TEXT,
                    grade_reasons TEXT NOT NULL DEFAULT '[]',
                    created_at TEXT,
                    updated_at TEXT,
                    FOREIGN KEY (run_id) REFERENCES runs(id)
                );

                CREATE TABLE IF NOT EXISTS events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    run_id INTEGER,
                    rpf_id INTEGER,
                    event_type TEXT NOT NULL,
                    name TEXT NOT NULL,
                    payload TEXT NOT NULL DEFAULT '{}',
                    raw TEXT,
                    created_at TEXT NOT NULL,
                    FOREIGN KEY (run_id) REFERENCES runs(id),
                    FOREIGN KEY (rpf_id) REFERENCES rpf_records(id)
                );

                CREATE TABLE IF NOT EXISTS analysis_results (
                    rpf_id INTEGER PRIMARY KEY,
                    anomaly_score REAL NOT NULL CHECK (anomaly_score BETWEEN 0 AND 1),
                    inspection_risk_score REAL NOT NULL CHECK (inspection_risk_score BETWEEN 0 AND 1),
                    timeseries_anomaly_score REAL CHECK (timeseries_anomaly_score BETWEEN 0 AND 1),
                    synthetic_model INTEGER NOT NULL DEFAULT 1,
                    model_info TEXT NOT NULL DEFAULT '{}',
                    analyzed_at TEXT NOT NULL,
                    FOREIGN KEY (rpf_id) REFERENCES rpf_records(id)
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
            event_columns = {
                str(row["name"])
                for row in self.connection.execute("PRAGMA table_info(events)").fetchall()
            }
            if "rpf_id" not in event_columns:
                self.connection.execute(
                    "ALTER TABLE events "
                    "ADD COLUMN rpf_id INTEGER REFERENCES rpf_records(id)"
                )
            rpf_columns = {
                str(row["name"])
                for row in self.connection.execute("PRAGMA table_info(rpf_records)")
            }
            if "product_group" not in rpf_columns:
                self.connection.execute("ALTER TABLE rpf_records ADD COLUMN product_group TEXT")
            self.connection.execute(
                "CREATE INDEX IF NOT EXISTS idx_rpf_finished_at "
                "ON rpf_records(julianday(finished_at), id)"
            )
            self.connection.execute(
                "CREATE INDEX IF NOT EXISTS idx_events_rpf_id ON events(rpf_id)"
            )
            self.connection.execute(
                "CREATE INDEX IF NOT EXISTS idx_rpf_records_run_cycle "
                "ON rpf_records(run_id, cycle_index)"
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
    def _rpf(row: sqlite3.Row | None) -> dict[str, Any] | None:
        if row is None:
            return None
        item = dict(row)
        try:
            reasons = json.loads(item["grade_reasons"])
        except (TypeError, json.JSONDecodeError):
            reasons = []
        item["grade_reasons"] = reasons if isinstance(reasons, list) else []
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
                rpf = self.connection.execute(
                    "SELECT id FROM rpf_records "
                    "WHERE run_id=? AND status='running' ORDER BY id DESC LIMIT 1",
                    (run_id,),
                ).fetchone()
                rpf_id = int(rpf["id"]) if rpf is not None else None
                self.connection.execute(
                    "UPDATE runs SET status='interrupted', finished_at=?, error=? WHERE id=?",
                    (now, "Server restarted while the run was active", run_id),
                )
                self.connection.execute(
                    "INSERT INTO events(run_id,rpf_id,event_type,name,payload,created_at) "
                    "VALUES(?,?,?,?,?,?)",
                    (
                        run_id,
                        rpf_id,
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

    def next_rpf_sequence(self) -> int:
        with self.lock:
            row = self.connection.execute(
                "SELECT COALESCE(MAX(id), 0) + 1 AS next_id FROM rpf_records"
            ).fetchone()
            return int(row["next_id"])

    def create_rpf(
        self,
        run_id: int,
        cycle_index: int,
        product_id: str,
        product_group: str | None = None,
    ) -> dict[str, Any]:
        now = utc_now()
        with self.lock:
            cursor = self.connection.execute(
                """
                INSERT INTO rpf_records(
                    run_id,cycle_index,product_id,status,started_at,created_at,updated_at,product_group
                ) VALUES(?,?,?,?,?,?,?,?)
                """,
                (run_id, cycle_index, product_id, "running", now, now, now, product_group),
            )
            self.connection.commit()
            return self.get_rpf(int(cursor.lastrowid))

    def get_rpf(self, rpf_id: int) -> dict[str, Any] | None:
        with self.lock:
            row = self.connection.execute(
                "SELECT * FROM rpf_records WHERE id=?", (rpf_id,)
            ).fetchone()
            return self._rpf(row)

    def list_rpfs(self, limit: int, offset: int, *, include_analysis: bool = False) -> list[dict[str, Any]]:
        with self.lock:
            rows = self.connection.execute(
                "SELECT * FROM rpf_records ORDER BY id DESC LIMIT ? OFFSET ?",
                (limit, offset),
            ).fetchall()
            records = [self._rpf(row) for row in rows]
            if include_analysis:
                for record in records:
                    record["analysis_result"] = self.get_analysis_result(record["id"])
            return records

    def browse_rpfs(
        self, *, from_at: str | None = None, to_at: str | None = None,
        product_group: str | None = None, grade: str | None = None,
        product_id: str | None = None, limit: int | None = None, offset: int = 0,
    ) -> dict[str, Any]:
        """Shared JSON/CSV query. from_at is inclusive; to_at is exclusive.

        julianday compares instants even for legacy timestamps with UTC offsets.
        A missing limit returns every matching row, including for CSV export.
        """
        clauses: list[str] = []
        parameters: list[Any] = []
        for column, operator, value in (
            ("julianday(r.finished_at)", ">=", from_at),
            ("julianday(r.finished_at)", "<", to_at),
        ):
            if value is not None:
                clauses.append(f"{column} {operator} julianday(?)")
                parameters.append(value)
        for column, value in (("r.product_group", product_group), ("r.grade", grade)):
            if value is not None:
                clauses.append(f"{column} = ?")
                parameters.append(value)
        if product_id is not None:
            # Literal substring search: %, _ and quotes are ordinary characters.
            clauses.append("instr(lower(r.product_id), lower(?)) > 0")
            parameters.append(product_id)
        where = " WHERE " + " AND ".join(clauses) if clauses else ""
        with self.lock:
            # Keep total/items consistent, including while the demo seed replaces a batch.
            with self.connection:
                self.connection.execute("BEGIN")
                total = self.connection.execute(
                    f"SELECT COUNT(*) FROM rpf_records r{where}", parameters
                ).fetchone()[0]
                rows = self.connection.execute(
                    "SELECT r.id,r.product_id,r.product_group,r.started_at,r.finished_at,"
                    "r.status,r.grade,r.work_time_ms,r.retry_count,r.error_count,"
                    "r.operator_interventions,a.anomaly_score,a.inspection_risk_score,"
                    "a.timeseries_anomaly_score FROM rpf_records r "
                    "LEFT JOIN analysis_results a ON a.rpf_id=r.id"
                    f"{where} ORDER BY julianday(r.finished_at) DESC,r.id DESC LIMIT ? OFFSET ?",
                    (*parameters, -1 if limit is None else limit, offset),
                ).fetchall()
                groups = self.connection.execute(
                    "SELECT DISTINCT product_group FROM rpf_records "
                    "WHERE product_group IS NOT NULL ORDER BY product_group"
                ).fetchall()
            return {"items": [dict(row) for row in rows], "total": total,
                    "product_groups": [row[0] for row in groups]}

    def get_analysis_result(self, rpf_id: int) -> dict[str, Any] | None:
        with self.lock:
            row = self.connection.execute(
                "SELECT * FROM analysis_results WHERE rpf_id=?", (rpf_id,)
            ).fetchone()
            if row is None:
                return None
            result = dict(row)
            result["synthetic_model"] = bool(result["synthetic_model"])
            result["model_info"] = json.loads(result["model_info"])
            return result

    def save_analysis_result(self, result: dict[str, Any]) -> dict[str, Any]:
        self.save_analysis_results([result])
        return self.get_analysis_result(result["rpf_id"])

    def save_analysis_results(self, results: list[dict], *, commit: bool = True) -> None:
        values = [(result["rpf_id"], result["anomaly_score"], result["inspection_risk_score"],
                   result["timeseries_anomaly_score"], int(result["synthetic_model"]),
                   json.dumps(result["model_info"], ensure_ascii=False, allow_nan=False), utc_now())
                  for result in results]
        with self.lock, (self.connection if commit else nullcontext()):
            self.connection.executemany(
                """
                INSERT INTO analysis_results (
                    rpf_id, anomaly_score, inspection_risk_score, timeseries_anomaly_score,
                    synthetic_model, model_info, analyzed_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(rpf_id) DO UPDATE SET
                    anomaly_score=excluded.anomaly_score,
                    inspection_risk_score=excluded.inspection_risk_score,
                    timeseries_anomaly_score=excluded.timeseries_anomaly_score,
                    synthetic_model=excluded.synthetic_model,
                    model_info=excluded.model_info,
                    analyzed_at=excluded.analyzed_at
                """,
                values,
            )

    def list_running_rpfs(self) -> list[dict[str, Any]]:
        with self.lock:
            rows = self.connection.execute(
                "SELECT * FROM rpf_records WHERE status='running' ORDER BY id"
            ).fetchall()
            return [self._rpf(row) for row in rows]

    def finish_rpf(
        self,
        rpf_id: int,
        *,
        status: str,
        finished_at: str,
        work_time_ms: int,
        retry_count: int,
        error_count: int,
        operator_interventions: int,
        grade: str,
        grade_reasons: list[str],
    ) -> dict[str, Any] | None:
        encoded_reasons = json.dumps(
            grade_reasons, ensure_ascii=False, separators=(",", ":")
        )
        with self.lock:
            self.connection.execute(
                """
                UPDATE rpf_records
                SET status=?,finished_at=?,work_time_ms=?,retry_count=?,error_count=?,
                    operator_interventions=?,grade=?,grade_reasons=?,updated_at=?
                WHERE id=?
                """,
                (
                    status,
                    finished_at,
                    max(0, work_time_ms),
                    retry_count,
                    error_count,
                    operator_interventions,
                    grade,
                    encoded_reasons,
                    finished_at,
                    rpf_id,
                ),
            )
            self.connection.commit()
            return self.get_rpf(rpf_id)

    def add_event(
        self,
        run_id: int | None,
        event_type: str,
        name: str,
        payload: dict[str, Any] | None = None,
        raw: str | None = None,
        rpf_id: int | None = None,
    ) -> dict[str, Any]:
        now = utc_now()
        encoded = json.dumps(payload or {}, ensure_ascii=False, separators=(",", ":"))
        with self.lock:
            cursor = self.connection.execute(
                "INSERT INTO events(run_id,rpf_id,event_type,name,payload,raw,created_at) "
                "VALUES(?,?,?,?,?,?,?)",
                (run_id, rpf_id, event_type, name, encoded, raw, now),
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

    def list_rpf_events(self, rpf_id: int) -> list[dict[str, Any]]:
        with self.lock:
            rows = self.connection.execute(
                "SELECT * FROM events WHERE rpf_id=? ORDER BY id ASC", (rpf_id,)
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
