"""Seed 30 demo RPFs with pose events; reruns atomically replace this seed's data.

Usage: python scripts/seed_demo_rpf.py [--database PATH] [--seed 42]
The default database follows DATABASE_PATH / the server settings. Existing real
records are retained. Only records bearing this script's ownership event are
replaced, including their saved analysis results. Database IDs may change on a
rerun; reopen product dialogs afterwards. No model training or inference occurs.
"""

import argparse
from collections import Counter
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import random
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from server.app.config import load_settings
from server.app.database import Database
from server.app.rpf import RpfRules


SOURCE = "scripts/seed_demo_rpf.py"
MARKER = "causalroboqc:seed_demo_rpf:v1"
OWNER_EVENT = "DEMO_RPF_SEEDED"
PRODUCT_IDS = [f"DEMO-RPF-{index:03d}" for index in range(1, 31)]
STAGES = ("HOME", "PICK_ABOVE", "PICK", "GRAB", "LIFT", "PLACE", "RELEASE", "HOME")
BASE_MS = (800, 1100, 900, 550, 1000, 1500, 450, 800)


def timestamp(value: datetime) -> str:
    return value.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def make_products(rules: RpfRules, seed: int) -> list[dict]:
    rng = random.Random(seed)
    scenarios = ["normal"] * 22 + ["review"] * 6 + ["priority"] * 2
    rng.shuffle(scenarios)
    # Keep even the final product fully in the past, with millisecond precision.
    now = datetime.now(timezone.utc)
    base = now.replace(microsecond=now.microsecond // 1000 * 1000) - timedelta(hours=1)
    products = []
    for cycle, (product_id, scenario) in enumerate(zip(PRODUCT_IDS, scenarios)):
        started = base + timedelta(minutes=cycle * 2)
        current = started
        events = []

        def event(name: str, **payload) -> None:
            events.append({
                "name": name, "created_at": timestamp(current),
                "payload": {"synthetic_data": True, "source": SOURCE,
                            "cycle": cycle, **payload},
            })

        event(OWNER_EVENT, product_id=product_id, seed=seed)
        event("RPF_STARTED", product_id=product_id)
        pace = rng.uniform(0.95, 1.05)
        for step_index, (stage, base_ms) in enumerate(zip(STAGES, BASE_MS)):
            duration = round(base_ms * pace * rng.uniform(0.94, 1.06))
            if scenario != "normal" and stage in ("PICK", "LIFT", "PLACE"):
                duration = round(duration * (1.35 if scenario == "review" else 2.6))
            if stage == "PICK" and scenario != "normal":
                for _ in range(1 if scenario == "review" else 2):
                    event("PICK_RETRY_INJECTED", pose=stage, step_index=step_index)
                    duration += rng.randint(350, 700)
            if stage == "LIFT" and scenario == "priority":
                event("OPERATOR_INTERVENTION", pose=stage, step_index=step_index)
                duration += rng.randint(500, 1000)
            if stage == "PLACE" and scenario == "priority":
                event("PLACE_FAILURE_INJECTED", pose=stage, step_index=step_index)
                duration += rng.randint(400, 800)
            event("POSE_REQUESTED", pose=stage, step_index=step_index)
            current += timedelta(milliseconds=duration)
            event("POSE_FINISHED", pose=stage, step_index=step_index)
            current += timedelta(milliseconds=350)
        event("RPF_FINISHED", status="completed")
        grade = rules.evaluate("completed", events)
        products.append({
            "product_id": product_id, "cycle_index": cycle,
            "started_at": timestamp(started), "finished_at": timestamp(current),
            "work_time_ms": round((current - started).total_seconds() * 1000),
            "grade": grade, "events": events,
        })
    return products


def seed_demo(database_path: Path, rules_path: Path, seed: int = 42) -> dict:
    products = make_products(RpfRules(rules_path), seed)
    database = Database(database_path)
    try:
        connection = database.connection
        # Database convenience methods commit individually. Use one transaction
        # here so readers see either the old complete batch or the new one.
        with database.lock, connection:
            connection.execute("BEGIN IMMEDIATE")
            owned = connection.execute(
                "SELECT DISTINCT r.id, r.run_id FROM rpf_records r "
                "JOIN events e ON e.rpf_id=r.id WHERE e.name=? AND e.raw=?",
                (OWNER_EVENT, MARKER),
            ).fetchall()
            owned_ids = {row["id"] for row in owned}
            placeholders = ",".join("?" for _ in PRODUCT_IDS)
            collisions = connection.execute(
                f"SELECT id,product_id FROM rpf_records WHERE product_id IN ({placeholders})",
                PRODUCT_IDS,
            ).fetchall()
            if any(row["id"] not in owned_ids for row in collisions):
                raise ValueError("An existing non-demo record uses a DEMO-RPF ID; nothing was replaced")
            for rpf_id in owned_ids:
                connection.execute("DELETE FROM analysis_results WHERE rpf_id=?", (rpf_id,))
                connection.execute("DELETE FROM events WHERE rpf_id=?", (rpf_id,))
                connection.execute("DELETE FROM rpf_records WHERE id=?", (rpf_id,))
            for run_id in {row["run_id"] for row in owned if row["run_id"] is not None}:
                # Retain a shared run if unrelated records/events still reference it.
                connection.execute(
                    "DELETE FROM runs WHERE id=? AND status='completed' "
                    "AND NOT EXISTS (SELECT 1 FROM rpf_records WHERE run_id=runs.id) "
                    "AND NOT EXISTS (SELECT 1 FROM events WHERE run_id=runs.id)",
                    (run_id,),
                )
            # A repeat batch excludes demo runs from single-run calibration/reviews.
            run_id = connection.execute(
                "INSERT INTO runs(repeat,run_mode,status,current_pose,step_index,"
                "cycle_count,started_at,finished_at) VALUES(1,'normal','completed','HOME',7,?,?,?)",
                (len(products), products[0]["started_at"], products[-1]["finished_at"]),
            ).lastrowid
            for product in products:
                grade = product["grade"]
                rpf_id = connection.execute(
                    "INSERT INTO rpf_records(run_id,cycle_index,product_id,status,started_at,finished_at,"
                    "work_time_ms,retry_count,error_count,operator_interventions,grade,grade_reasons,"
                    "created_at,updated_at) VALUES(?,?,?,'completed',?,?,?,?,?,?,?,?,?,?)",
                    (run_id, product["cycle_index"], product["product_id"], product["started_at"],
                     product["finished_at"], product["work_time_ms"], grade.retry_count,
                     grade.error_count, grade.operator_interventions, grade.grade,
                     json.dumps(grade.reasons, ensure_ascii=False),
                     product["started_at"], product["finished_at"]),
                ).lastrowid
                connection.executemany(
                    "INSERT INTO events(run_id,rpf_id,event_type,name,payload,raw,created_at) "
                    "VALUES(?,?,'F',?,?,?,?)",
                    [(run_id, rpf_id, item["name"], json.dumps(item["payload"], ensure_ascii=False),
                      MARKER if item["name"] == OWNER_EVENT else None, item["created_at"])
                     for item in product["events"]],
                )
        return {
            "database": str(database_path.resolve()), "synthetic_data": True,
            "seed": seed, "replaced_demo_rpfs": len(owned_ids), "demo_rpfs": len(products),
            "pose_events": len(products) * len(STAGES) * 2,
            "total_demo_events": sum(len(product["events"]) for product in products),
            "grades": dict(Counter(product["grade"].grade for product in products)),
        }
    finally:
        database.close()


def main() -> None:
    settings = load_settings()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", "--db", type=Path, default=settings.database_path,
                        help="SQLite path; defaults to DATABASE_PATH / server settings")
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()
    result = seed_demo(args.database.expanduser(), settings.rpf_rules_path, args.seed)
    print("DEMO DATA ONLY: invented process records for UI/API trials, not measured production data.")
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
