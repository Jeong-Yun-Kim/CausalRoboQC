"""Migrate seed-owned IDs in place and infer all three scores with the existing AI API.

Never regenerates events, trains models, or changes grades/user records. The CLI
backs up SQLite before migration. Inference is staged before an atomic write;
an unavailable model, incomplete sequence or concurrent edit preserves scores.
Run after starting ai.app.main: python scripts/prepare_rpf_presentation.py
"""

import argparse
import asyncio
from datetime import datetime, timezone
import json
from pathlib import Path
import sqlite3
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scripts.seed_demo_rpf import MARKER, OWNER_EVENT, PRODUCT_IDS, SOURCE
from server.app.analysis_client import AnalysisClient, AnalysisError, pose_sequence
from server.app.config import load_settings
from server.app.database import Database


def owned_records(database: Database) -> list[dict]:
    with database.lock:
        rows = database.connection.execute(
            "SELECT r.* FROM rpf_records r WHERE EXISTS "
            "(SELECT 1 FROM events e WHERE e.rpf_id=r.id AND e.name=? AND e.raw=?) "
            "ORDER BY r.product_id,r.id", (OWNER_EVENT, MARKER),
        ).fetchall()
        return [database._rpf(row) for row in rows]


def migrate_seed_ids(database: Database) -> int:
    """Only the historical ownership marker authorizes an ID migration."""
    with database.lock, database.connection:
        database.connection.execute("BEGIN IMMEDIATE")
        records = owned_records(database)
        legacy = {"DEMO-" + ident: ident for ident in PRODUCT_IDS}
        changes = [(row, legacy[row["product_id"]]) for row in records
                   if row["product_id"] in legacy]
        # Check every destination before writing anything, including duplicates
        # within the old batch. Do not rename or overwrite conflicting user IDs.
        targets = [target for _, target in changes]
        if len(targets) != len(set(targets)):
            raise ValueError("Duplicate seed IDs; no records were migrated")
        for record, target in changes:
            if database.connection.execute(
                "SELECT 1 FROM rpf_records WHERE product_id=? COLLATE NOCASE AND id<>?",
                (target, record["id"]),
            ).fetchone():
                raise ValueError(f"ID collision at {target}; no records were migrated")
        for record, target in changes:
            database.connection.execute("UPDATE rpf_records SET product_id=? WHERE id=?",
                                        (target, record["id"]))
            for event in database.list_rpf_events(record["id"]):
                payload = event["payload"]
                if (isinstance(payload, dict) and payload.get("source") == SOURCE
                        and payload.get("product_id") == record["product_id"]):
                    payload["product_id"] = target
                    database.connection.execute("UPDATE events SET payload=? WHERE id=?",
                                                (json.dumps(payload, ensure_ascii=False), event["id"]))
        return len(changes)


async def analyze_seed(database: Database, client: AnalysisClient) -> dict:
    records = owned_records(database)
    if len(records) != 30 or {row["product_id"] for row in records} != set(PRODUCT_IDS):
        raise ValueError("Expected exactly 30 owned RPF-001 through RPF-030 records")
    snapshots = [(row, database.list_rpf_events(row["id"])) for row in records]
    for record, events in snapshots:
        if record["status"] != "completed" or pose_sequence(events, record["cycle_index"]) is None:
            raise ValueError(f"Incomplete process stages for {record['product_id']}; scores unchanged")
    results = []
    for record, events in snapshots:
        result = await client.analyze(record, events)
        if result["timeseries_anomaly_score"] is None:
            raise AnalysisError(502, "Autoencoder score is missing; scores unchanged")
        results.append(result)
    with database.lock, database.connection:
        database.connection.execute("BEGIN IMMEDIATE")
        if owned_records(database) != records or any(
            database.list_rpf_events(row["id"]) != events for row, events in snapshots
        ):
            raise ValueError("RPF data changed during inference; scores unchanged, retry preparation")
        # The save helper participates in this transaction without an early commit.
        database.save_analysis_results(results, commit=False)
    return {"analyzed_rpfs": len(results), "scores_per_rpf": 3,
            "product_ids": [row["product_id"] for row in records]}


def backup_database(path: Path) -> Path:
    suffix = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    target = path.with_name(f"{path.stem}.before-presentation-{suffix}.db")
    # SQLite backup API includes committed WAL data, unlike copying the DB file.
    with sqlite3.connect(f"{path.resolve().as_uri()}?mode=ro", uri=True) as source:
        with sqlite3.connect(target) as destination:
            source.backup(destination)
    return target


async def main() -> None:
    settings = load_settings()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", "--db", type=Path, default=settings.database_path)
    parser.add_argument("--analysis-url", default=settings.analysis_base_url)
    parser.add_argument("--migrate-only", action="store_true")
    args = parser.parse_args()
    path = args.database.expanduser()
    if not path.is_file():
        parser.error("Database does not exist; run scripts/seed_demo_rpf.py first")
    backup = backup_database(path)
    print(f"SQLite backup: {backup}", flush=True)
    database = Database(path)
    client = AnalysisClient(args.analysis_url, timeout=max(30, settings.analysis_timeout_seconds))
    try:
        migrated = migrate_seed_ids(database)
        result = {} if args.migrate_only else await analyze_seed(database, client)
        print(json.dumps({"migrated_ids": migrated, **result}, ensure_ascii=False, indent=2))
    finally:
        await client.close()
        database.close()


if __name__ == "__main__":
    asyncio.run(main())
