import asyncio
import tempfile
import unittest
from pathlib import Path

from server.app.config import Settings
from server.app.database import Database
from server.app.service import (
    ERROR_RUN_SEQUENCE,
    RUN_SEQUENCE,
    RobotService,
    WebSocketHub,
)


class RpfPipelineTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        self.database_path = root / "robot.db"
        self.settings = Settings(
            serial_port="/dev/null",
            baud_rate=115200,
            reconnect_seconds=0.01,
            status_poll_seconds=0.01,
            move_timeout_seconds=0.1,
            pose_pause_seconds=0,
            repeat_unlock_samples=1,
            database_path=self.database_path,
            poses_path=Path("server/config/poses.json"),
            rpf_rules_path=Path("server/config/rpf_rules.json"),
        )
        self.database = Database(self.database_path)
        self.service = RobotService(self.settings, self.database, WebSocketHub())

        async def fake_move_pose(
            name: str,
            angles: list[int],
            run_id: int | None,
            step_index: int | None = None,
            cycle: int | None = None,
        ) -> None:
            await self.service._add_event(
                "F",
                "POSE_FINISHED",
                {"pose": name, "step_index": step_index, "cycle": cycle},
                run_id=run_id,
            )

        async def no_broadcast() -> None:
            return None

        self.service._move_pose = fake_move_pose  # type: ignore[method-assign]
        self.service._broadcast_status = no_broadcast  # type: ignore[method-assign]

    def tearDown(self) -> None:
        self.database.close()
        self.temporary.cleanup()

    async def _execute_once(self, mode: str) -> tuple[int, dict]:
        sequence = ERROR_RUN_SEQUENCE if mode == "error" else RUN_SEQUENCE
        run = self.database.create_run(False, mode)
        run_id = int(run["id"])
        self.service.active_run_id = run_id
        poses = {name: [90] * 6 for name in set(sequence)}
        await self.service._execute_run(run_id, False, mode, sequence, poses)
        records = self.database.list_rpfs(10, 0)
        return run_id, records[0]

    async def test_normal_cycle_creates_normal_rpf_and_links_pose_events(self) -> None:
        _, record = await self._execute_once("normal")

        self.assertEqual(record["status"], "completed")
        self.assertEqual(record["grade"], "normal")
        self.assertEqual(record["grade_reasons"], [])
        self.assertEqual(record["retry_count"], 0)
        self.assertGreaterEqual(record["work_time_ms"], 0)
        events = self.database.list_rpf_events(int(record["id"]))
        self.assertTrue(any(event["name"] == "POSE_FINISHED" for event in events))
        self.assertTrue(all(event["rpf_id"] == record["id"] for event in events))

    async def test_error_cycle_uses_existing_events_for_priority_grade(self) -> None:
        _, record = await self._execute_once("error")

        self.assertEqual(record["status"], "completed")
        self.assertEqual(record["grade"], "priority")
        self.assertEqual(record["retry_count"], 1)
        self.assertIn("집기 재시도 1회", record["grade_reasons"])
        self.assertIn("표준 작업시간 초과", record["grade_reasons"])
        self.assertIn("배치 실패", record["grade_reasons"])

    async def test_repeat_creates_one_completed_rpf_per_cycle(self) -> None:
        run = self.database.create_run(True, "normal")
        run_id = int(run["id"])
        self.service.active_run_id = run_id
        poses = {name: [90] * 6 for name in set(RUN_SEQUENCE)}
        original_start_cycle = self.service.rpf.start_cycle

        def limited_start_cycle(current_run_id: int, cycle_index: int) -> dict:
            if cycle_index == 3:
                raise RuntimeError("test repeat limit")
            return original_start_cycle(current_run_id, cycle_index)

        self.service.rpf.start_cycle = limited_start_cycle  # type: ignore[method-assign]
        await self.service._execute_run(run_id, True, "normal", RUN_SEQUENCE, poses)

        records = list(reversed(self.database.list_rpfs(10, 0)))
        self.assertEqual([record["cycle_index"] for record in records], [0, 1, 2])
        self.assertTrue(all(record["status"] == "completed" for record in records))

    async def test_rpf_survives_database_reopen(self) -> None:
        _, record = await self._execute_once("normal")
        rpf_id = int(record["id"])
        self.database.close()

        reopened = Database(self.database_path)
        try:
            saved = reopened.get_rpf(rpf_id)
            self.assertIsNotNone(saved)
            self.assertEqual(saved["grade"], "normal")
        finally:
            reopened.close()

        self.database = Database(self.database_path)
