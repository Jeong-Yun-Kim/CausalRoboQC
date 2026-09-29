"""Prepare only an explicitly owned, separate local presentation database."""

from contextlib import contextmanager
import fcntl
import math
import sqlite3

from .database import Database
from .fmea_bayesian import cause_candidates, load_model


APPLICATION_ID = 0x43525150  # CRQP; never adopt an arbitrary existing database.
SCORES = ("anomaly_score", "inspection_risk_score", "timeseries_anomaly_score")


@contextmanager
def presentation_guard(settings):
    if not settings.presentation_mode:
        yield
        return
    path = settings.database_path.resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.with_suffix(".lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise RuntimeError("Presentation database is already in use") from exc
        if path.exists() and path.stat().st_size:
            with sqlite3.connect(path.as_uri() + "?mode=ro", uri=True) as conn:
                if conn.execute("PRAGMA application_id").fetchone()[0] != APPLICATION_ID:
                    raise ValueError("Refusing an unowned presentation database; choose a new PRESENTATION_DATABASE_PATH")
        yield


async def prepare_presentation(settings, client) -> dict:
    # Local integrated mode reuses the existing seed/inference tools verbatim.
    # Normal API deployment does not import or require these tools.
    from scripts.seed_demo_rpf import PRODUCT_IDS, seed_demo
    from scripts.prepare_rpf_presentation import analyze_seed, owned_records
    from .analysis_client import pose_sequence

    load_model()  # Fail before announcing readiness if the CPT is invalid.
    database = Database(settings.database_path)
    try:
        with database.connection:
            database.connection.execute(f"PRAGMA application_id={APPLICATION_ID}")
        records = owned_records(database)
        total = database.connection.execute("SELECT COUNT(*) FROM rpf_records").fetchone()[0]
        if total != len(records):
            raise ValueError("Unowned RPFs found; presentation preparation will not delete user records")
        complete = (len(records) == 30 and {r["product_id"] for r in records} == set(PRODUCT_IDS)
                    and all(r["status"] == "completed" and
                            pose_sequence(database.list_rpf_events(r["id"]), r["cycle_index"]) is not None
                            for r in records))
        if not complete:
            seed_demo(settings.database_path, settings.rpf_rules_path)
            records = owned_records(database)
        results = [database.get_analysis_result(record["id"]) for record in records]
        ready = all(result and all(isinstance(result.get(key), (int, float))
                                   and math.isfinite(result[key]) and 0 <= result[key] <= 1
                                   for key in SCORES)
                    and result["model_info"].get("sequence_available") is True for result in results)
        if not ready:
            await analyze_seed(database, client)  # 30 real HTTP inferences, one atomic save.
        for record in records:
            cause_candidates(record, database.list_rpf_events(record["id"]))
        return {"rpf_count": 30, "analysis_count": 30, "ready": True}
    finally:
        database.close()
