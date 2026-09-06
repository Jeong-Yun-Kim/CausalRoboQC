import copy
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient
import httpx

from server.app.analysis_client import AnalysisClient, pose_sequence
from server.app.database import Database
from server.app.main import app
from server.tests.analysis_fixtures import create_rpf, pose_events


class SequenceTest(unittest.TestCase):
    def test_request_finish_durations_exclude_final_home(self):
        expected = {"HOME": 800, "PICK_ABOVE": 1050, "PICK": 900, "GRAB": 500,
                    "LIFT": 1000, "PLACE": 1200, "RELEASE": 400}
        self.assertEqual(pose_sequence(pose_events(), 0), expected)
        self.assertEqual(pose_sequence(pose_events()[:-2], 0), expected)

    def test_ambiguous_sequences_are_unavailable(self):
        original = pose_events()
        invalid = [[], original[:-1], original[1:], original[::-1], original + original[:2]]
        for key, value in (("pose", "ERROR_PICK"), ("step_index", 9), ("cycle", 2)):
            events = copy.deepcopy(original)
            events[4]["payload"][key] = value
            invalid.append(events)
        for timestamp in ("bad", original[0]["created_at"], "2026-09-06T00:00:00+00:00"):
            events = copy.deepcopy(original)
            events[1]["created_at"] = timestamp
            invalid.append(events)
        events = copy.deepcopy(original)
        events[2]["created_at"] = original[0]["created_at"]
        invalid.append(events)
        for events in invalid:
            with self.subTest(events=events):
                self.assertIsNone(pose_sequence(events, 0))


class ServerAnalysisTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.db_path = Path(self.temp.name) / "robot.db"
        self.requests = []
        self.score = 0.3
        self.failure = None
        self.invalid_result = None

        def respond(request):
            payload = json.loads(request.content)
            self.requests.append(payload)
            if self.failure:
                raise self.failure("test unavailable", request=request)
            result = {
                "rpf_id": payload["rpf_id"], "anomaly_score": self.score,
                "inspection_risk_score": 0.4,
                "timeseries_anomaly_score": 0.5 if payload["sequence"] else None,
                "synthetic_model": True, "model_info": {"fixture": True},
            }
            result.update(self.invalid_result or {})
            return httpx.Response(200, json=result)

        analysis = AnalysisClient("http://test-laptop", transport=httpx.MockTransport(respond))
        self.patches = [
            patch.dict(os.environ, {"DATABASE_PATH": str(self.db_path)}),
            patch("server.app.main.RobotService.start", new_callable=AsyncMock),
            patch("server.app.main.RobotService.shutdown", new_callable=AsyncMock),
            patch("server.app.main.AnalysisClient", return_value=analysis),
        ]
        for item in self.patches:
            item.start()
        self.client = TestClient(app)
        self.client.__enter__()
        self.database = app.state.service.database
        self.record = create_rpf(self.database)
        self.url = f"/api/rpf/{self.record['id']}"

    def tearDown(self):
        self.client.__exit__(None, None, None)
        for item in reversed(self.patches):
            item.stop()
        self.temp.cleanup()

    def test_completed_analysis_saved_upserted_and_survives_reopen(self):
        self.assertIsNone(self.client.get(self.url).json()["analysis_result"])
        response = self.client.post(self.url + "/analyze")
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["anomaly_score"], 0.3)
        self.assertEqual(set(self.requests[0]["features"]),
                         {"work_time_ms", "retry_count", "error_count", "operator_interventions"})
        self.assertEqual(self.requests[0]["sequence"]["HOME"], 800)
        self.score = 0.7
        result = self.client.post(self.url + "/analyze").json()
        self.assertEqual(result["anomaly_score"], 0.7)
        detail = self.client.get(self.url).json()
        self.assertEqual(detail["analysis_result"], result)
        self.assertEqual({key: detail[key] for key in self.record}, self.record)
        self.assertEqual(self.database.connection.execute("SELECT COUNT(*) FROM analysis_results").fetchone()[0], 1)
        reopened = Database(self.db_path)
        try:
            self.assertEqual(reopened.get_analysis_result(self.record["id"]), result)
            self.assertEqual(reopened.get_rpf(self.record["id"]), self.record)
        finally:
            reopened.close()

    def test_absent_sequence_keeps_tabular_analysis(self):
        record = create_rpf(self.database, with_sequence=False)
        result = self.client.post(f"/api/rpf/{record['id']}/analyze")
        self.assertEqual(result.status_code, 200, result.text)
        self.assertIsNone(self.requests[-1]["sequence"])
        self.assertIsNone(result.json()["timeseries_anomaly_score"])

    def test_unfinished_and_unknown_rpf_rejected_without_calling_laptop(self):
        record = create_rpf(self.database, completed=False)
        self.assertEqual(self.client.post(f"/api/rpf/{record['id']}/analyze").status_code, 409)
        self.assertEqual(self.client.post("/api/rpf/99999/analyze").status_code, 404)
        self.assertEqual(self.requests, [])

    def test_connection_failure_preserves_previous_result_and_other_apis(self):
        saved = self.client.post(self.url + "/analyze").json()
        for failure in (httpx.ConnectError, httpx.ReadTimeout):
            self.failure = failure
            self.assertEqual(self.client.post(self.url + "/analyze").status_code, 503)
            self.assertEqual(self.client.get("/health").status_code, 200)
            self.assertEqual(self.client.get("/api/status").status_code, 200)
            self.assertEqual(self.client.get("/api/rpf").status_code, 200)
            self.assertEqual(self.client.get(self.url).json()["analysis_result"], saved)

    def test_invalid_remote_scores_or_id_not_saved(self):
        for update in ({"anomaly_score": 1.1}, {"inspection_risk_score": "0.5"},
                       {"rpf_id": 9999}, {"synthetic_model": "true"}):
            self.invalid_result = update
            self.assertEqual(self.client.post(self.url + "/analyze").status_code, 502)
            self.assertIsNone(self.database.get_analysis_result(self.record["id"]))

    def test_existing_database_migrates_without_changing_rpf_or_events(self):
        events = self.database.list_rpf_events(self.record["id"])
        self.database.connection.execute("DROP TABLE analysis_results")
        self.database.connection.commit()
        migrated = Database(self.db_path)
        try:
            self.assertEqual(migrated.get_rpf(self.record["id"]), self.record)
            self.assertEqual(migrated.list_rpf_events(self.record["id"]), events)
            self.assertIsNone(migrated.get_analysis_result(self.record["id"]))
        finally:
            migrated.close()

    def test_pi_server_does_not_import_ml_libraries(self):
        for name in ("sklearn", "torch", "ai.modeling"):
            self.assertNotIn(name, sys.modules)
