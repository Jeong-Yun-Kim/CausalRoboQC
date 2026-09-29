import asyncio
from dataclasses import replace
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

import httpx
from fastapi.testclient import TestClient

from server.app.analysis_client import AnalysisClient, AnalysisError
from server.app.config import load_settings
from server.app.copilot import ask_laptop
from server.app.copilot_queries import CopilotQueries
from server.app.database import Database
from server.app.main import app
from server.app.presentation_mode import APPLICATION_ID, presentation_guard, prepare_presentation
from server.app.service import ERROR_RUN_SEQUENCE, RUN_SEQUENCE
from server.tests.analysis_fixtures import create_rpf


def response(request):
    # Contract fixture only. ai/tests verifies actual saved-model inference.
    return httpx.Response(200, json={"rpf_id": json.loads(request.content)["rpf_id"],
        "anomaly_score": .2, "inspection_risk_score": .3, "timeseries_anomaly_score": .4,
        "synthetic_model": True, "model_info": {"sequence_available": True}})


class PreparationTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "presentation.db"
        self.settings = replace(load_settings(), presentation_mode=True, database_path=self.path)
        self.client = AnalysisClient("http://fixture", transport=httpx.MockTransport(response))

    async def asyncTearDown(self):
        await self.client.close()
        self.temp.cleanup()

    async def prepare(self):
        with presentation_guard(self.settings):
            return await prepare_presentation(self.settings, self.client)

    async def test_prepare_is_idempotent_and_repairs_missing_scores_and_owned_records(self):
        self.assertEqual((await self.prepare())["analysis_count"], 30)
        db = Database(self.path)
        try:
            before = list(db.connection.iterdump())
            with patch.object(self.client, "analyze", side_effect=AssertionError("must reuse scores")):
                await self.prepare()
            self.assertEqual(before, list(db.connection.iterdump()))
            with db.connection:
                db.connection.execute("DELETE FROM analysis_results WHERE rpf_id=1")
            await self.prepare()
            self.assertEqual(db.connection.execute("SELECT COUNT(*) FROM analysis_results").fetchone()[0], 30)
            with db.connection:
                db.connection.execute("DELETE FROM analysis_results WHERE rpf_id=1")
                db.connection.execute("DELETE FROM events WHERE rpf_id=1")
                db.connection.execute("DELETE FROM rpf_records WHERE id=1")
            await self.prepare()
            self.assertEqual(len(db.list_rpfs(100, 0)), 30)
            self.assertEqual({r["product_id"] for r in db.list_rpfs(100, 0)},
                             {f"RPF-{i:03d}" for i in range(1, 31)})
        finally:
            db.close()

    async def test_inference_failure_does_not_publish_partial_scores_and_restart_recovers(self):
        original = self.client.analyze
        calls = 0
        async def fail_last(*args):
            nonlocal calls
            calls += 1
            if calls == 30:
                raise AnalysisError(503, "AI offline")
            return await original(*args)
        with patch.object(self.client, "analyze", side_effect=fail_last), self.assertRaises(AnalysisError):
            await self.prepare()
        db = Database(self.path)
        self.assertEqual(db.connection.execute("SELECT COUNT(*) FROM analysis_results").fetchone()[0], 0)
        self.assertEqual(len(db.list_rpfs(100, 0)), 30)
        db.close()
        self.assertTrue((await self.prepare())["ready"])

    async def test_unowned_database_and_records_are_preserved_and_refused(self):
        db = Database(self.path)
        create_rpf(db, product_id="USER-001")
        before = list(db.connection.iterdump())
        with self.assertRaisesRegex(ValueError, "unowned"):
            await self.prepare()
        self.assertEqual(before, list(db.connection.iterdump()))
        with db.connection:
            db.connection.execute(f"PRAGMA application_id={APPLICATION_ID}")
        with self.assertRaisesRegex(ValueError, "Unowned RPFs"):
            await self.prepare()
        self.assertEqual(before, list(db.connection.iterdump()))
        db.close()

    async def test_process_lock_and_user_database_path_guard(self):
        with presentation_guard(self.settings):
            with self.assertRaisesRegex(RuntimeError, "already in use"):
                with presentation_guard(self.settings):
                    pass
        with patch.dict(os.environ, {"PRESENTATION_MODE": "true", "DATABASE_PATH": str(self.path),
                                     "PRESENTATION_DATABASE_PATH": str(self.path)}):
            with self.assertRaisesRegex(ValueError, "separate"):
                load_settings()
        with patch.dict(os.environ, {"PRESENTATION_MODE": "false", "DATABASE_PATH": str(self.path)}):
            self.assertEqual(load_settings().database_path, self.path)


class PresentationApiTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.user_path = root / "user.db"
        user = Database(self.user_path)
        create_rpf(user, product_id="USER-001")
        user.close()
        self.user_bytes = self.user_path.read_bytes()
        self.poses = root / "poses.json"
        self.poses.write_text(json.dumps({name: [90] * 6 for name in (*RUN_SEQUENCE, *ERROR_RUN_SEQUENCE)}))
        self.analysis = AnalysisClient("http://fixture", transport=httpx.MockTransport(response))
        for p in [patch.dict(os.environ, {"PRESENTATION_MODE": "true",
                         "PRESENTATION_DATABASE_PATH": str(root / "presentation.db"),
                         "DATABASE_PATH": str(self.user_path), "POSES_PATH": str(self.poses),
                         "POSE_PAUSE_SECONDS": "0", "REPEAT_UNLOCK_SAMPLES": "1"}),
                  patch("server.app.serial_link.SerialLink.start", new_callable=AsyncMock),
                  patch("server.app.main.AnalysisClient", return_value=self.analysis)]:
            p.start()
            self.addCleanup(p.stop)
        self.api = TestClient(app)
        self.api.__enter__()
        self.addCleanup(self.api.__exit__, None, None, None)
        self.service = app.state.service
        self.db = self.service.database
        self.service.serial.ready = True
        self.service.serial.connected = True
        self.commands = []
        self.hold_move = False
        async def send(command):
            self.commands.append(command)
            if command.startswith("MOVE "):
                await self.service.handle_line("OK MOVE")
                if not self.hold_move:
                    await self.service.handle_line("DONE")
            elif command == "STATUS":
                angles = " ".join(str(v if v is not None else 90) for v in self.service.robot["target_angles"])
                await self.service.handle_line(f"STATUS 63 0 0 {angles} {angles}")
            else:
                await self.service.handle_line(f"OK {command}")
        self.service.serial.send = send

    def assert_fixed(self):
        rows = self.api.get("/api/rpf?include_analysis=true").json()["items"]
        self.assertEqual(len(rows), 30)
        self.assertTrue(all(r["analysis_result"] for r in rows))
        self.assertEqual(self.user_bytes, self.user_path.read_bytes())
        return rows

    def wait_run(self):
        async def wait():
            task = self.service.run_task
            if task:
                await asyncio.wait_for(asyncio.shield(task), 30)
        self.api.portal.call(wait)

    def test_robot_apis_scenarios_safety_websocket_and_fixed_quality_records(self):
        before = self.assert_fixed()
        with self.api.websocket_connect("/ws") as ws:
            self.assertEqual(ws.receive_json()["type"], "snapshot")
            ws.send_text("ping")
            self.assertEqual(ws.receive_json()["type"], "pong")
        for joint in range(1, 7):
            self.assertEqual(self.api.post(f"/api/servos/{joint}", json={"angle": 90}).status_code, 200)
        self.assertEqual(self.api.post("/api/poses/HOME/move").status_code, 200)
        for mode in ("normal", "error"):
            start = self.api.post("/api/runs/start", json={"mode": mode})
            self.assertEqual(start.status_code, 200, start.text)
            run_id = start.json()["run"]["id"]
            self.wait_run()
            self.assertEqual(self.api.get(f"/api/runs/{run_id}").json()["status"], "completed")
            self.assertEqual(self.api.post(f"/api/runs/{run_id}/review", json={"verdict": "normal"}).status_code, 200)
        for command in ("STOP", "ESTOP", "DETACH"):
            self.hold_move = True
            start = self.api.post("/api/runs/start", json={"repeat": command == "STOP"})
            self.assertEqual(start.status_code, 200, start.text)
            control = self.api.post(f"/api/control/{command}")
            self.assertEqual(control.status_code, 200, control.text)
            self.assertIsNone(self.service.active_run_id)
            self.assertEqual(self.api.post("/api/control/RESET").status_code, 200)
        self.assertEqual(self.api.post("/api/runs/stop").status_code, 200)
        self.assertEqual(self.api.get("/api/status").status_code, 200)
        self.assertTrue(any(c.startswith("MOVE ") for c in self.commands))
        self.assertEqual(self.assert_fixed(), before)
        self.assertFalse(self.service.analysis._tasks)
        self.assertEqual(self.db.connection.execute("SELECT COUNT(*) FROM analysis_results").fetchone()[0], 30)

    def test_copilot_uses_server_candidates_even_if_llm_selects_only_one_fact(self):
        async def select(_url, body):
            return await ask_laptop("http://fixture", body, transport=httpx.MockTransport(
                lambda r: httpx.Response(200, json={"fact_ids": [body["facts"][0]["id"]],
                                                  "answer": "가짜 확률 99.99%"})))
        with patch("server.app.copilot.ask_laptop", side_effect=select):
            for q in ("RPF-018 원인 후보 알려줘", "RPF-018에서 먼저 뭘 점검해야 해?",
                      "우선검사 제품들의 원인 후보 비교해줘"):
                response_body = self.api.post("/api/copilot/chat", json={"question": q})
                self.assertEqual(response_body.status_code, 200, response_body.text)
                result = response_body.json()
                self.assertIn("FMEA/Bayesian", result["answer"])
                self.assertNotRegex(result["answer"], r"데모|합성|테스트|(?i:demo|synthetic|test)")
                prepared = CopilotQueries(self.db).prepare(q)
                for fact in prepared["facts"]:
                    if fact["id"] in prepared["required_fact_ids"]:
                        self.assertIn(fact["text"], result["answer"])
        detail = self.api.get("/api/rpf/18").json()["presentation"]["cause_analysis"]
        self.assertEqual(len(detail["top_candidates"]), 3)
        self.assertAlmostEqual(sum(i["probability"] for i in detail["candidates"]), 1)
        self.assert_fixed()
