"""Explicit hardware-free fixtures, written only to caller-provided test databases."""

from datetime import datetime, timedelta, timezone


STAGES = ("HOME", "PICK_ABOVE", "PICK", "GRAB", "LIFT", "PLACE", "RELEASE", "HOME")
DURATIONS = (800, 1050, 900, 500, 1000, 1200, 400, 1600)


def pose_events():
    timestamp = datetime(2026, 9, 7, tzinfo=timezone.utc)
    events = []
    for index, (stage, duration) in enumerate(zip(STAGES, DURATIONS)):
        payload = {"pose": stage, "step_index": index, "cycle": 0}
        events.append({"name": "POSE_REQUESTED", "payload": payload.copy(),
                       "created_at": timestamp.isoformat()})
        timestamp += timedelta(milliseconds=duration)
        events.append({"name": "POSE_FINISHED", "payload": payload.copy(),
                       "created_at": timestamp.isoformat()})
        timestamp += timedelta(milliseconds=100)
    return events


def create_rpf(database, *, completed=True, with_sequence=True, product_id="FIXTURE-P-023"):
    run = database.create_run(False, "normal")
    rpf = database.create_rpf(run["id"], 0, product_id)
    if completed:
        database.finish_rpf(
            rpf["id"], status="completed", finished_at="2026-09-07T00:00:14Z",
            work_time_ms=13800, retry_count=1, error_count=1, operator_interventions=0,
            grade="review", grade_reasons=["집기 재시도 1회"],
        )
        database.update_run(run["id"], status="completed", finished_at="2026-09-07T00:00:14Z")
    if with_sequence:
        for item in pose_events():
            event = database.add_event(run["id"], "F", item["name"], item["payload"], rpf_id=rpf["id"])
            with database.lock:
                database.connection.execute(
                    "UPDATE events SET created_at=? WHERE id=?", (item["created_at"], event["id"])
                )
                database.connection.commit()
    return database.get_rpf(rpf["id"])
