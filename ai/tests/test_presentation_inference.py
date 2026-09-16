"""End-to-end saved-model inference and read surfaces, without robot hardware."""

import hashlib
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

import httpx
import pandas as pd
from fastapi.testclient import TestClient

from ai.app.main import app as laptop
from ai.modeling import FEATURE_NAMES, MODEL_DIR, SCORE_NAMES
from scripts.prepare_rpf_presentation import analyze_seed, owned_records
from scripts.seed_demo_rpf import seed_demo
from server.app.analysis_client import AnalysisClient, pose_sequence
from server.app.database import Database
from server.app.main import app as server


class PresentationInferenceTest(unittest.IsolatedAsyncioTestCase):
    async def test_30_real_inferences_persist_and_reach_every_read_surface(self):
        hashes = {path: hashlib.sha256(path.read_bytes()).hexdigest()
                  for path in MODEL_DIR.iterdir() if path.is_file()}
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "presentation.db"
            seed_demo(path, Path("server/config/rpf_rules.json"))
            database = Database(path)
            try:
                before = owned_records(database)
                events = [database.list_rpf_events(row["id"]) for row in before]
                async with laptop.router.lifespan_context(laptop):
                    client = AnalysisClient("http://laptop", transport=httpx.ASGITransport(laptop))
                    try:
                        summary = await analyze_seed(database, client)
                    finally:
                        await client.close()
                    expected = laptop.state.models.predict(
                        pd.DataFrame([{key: row[key] for key in FEATURE_NAMES} for row in before]),
                        pd.DataFrame([pose_sequence(items, row["cycle_index"]) for row, items in zip(before, events)]),
                    )
                self.assertEqual(summary["analyzed_rpfs"], 30)
                self.assertEqual(owned_records(database), before)
                self.assertEqual([database.list_rpf_events(row["id"]) for row in before], events)
                for i, record in enumerate(before):
                    saved = database.get_analysis_result(record["id"])
                    for key in SCORE_NAMES:
                        self.assertIsNotNone(saved[key])
                        self.assertAlmostEqual(saved[key], expected.iloc[i][key], places=6)
                    self.assertTrue(saved["model_info"]["sequence_available"])
                    self.assertEqual(saved["model_info"]["models"], {
                        "isolation_forest": "sklearn.ensemble.IsolationForest", "random_forest": "sklearn.ensemble.RandomForestClassifier",
                        "autoencoder": "torch MLP Autoencoder"})
                saved_rows = database.browse_rpfs()["items"]
            finally:
                database.close()
            # Reopen through the real FastAPI lifespan; disable only hardware startup.
            with patch.dict(os.environ, {"DATABASE_PATH": str(path)}), patch(
                "server.app.main.RobotService.start", new_callable=AsyncMock
            ), patch("server.app.main.RobotService.shutdown", new_callable=AsyncMock), TestClient(server) as api:
                overview = api.get("/api/rpf?include_analysis=true").json()["items"]
                self.assertEqual(len(overview), 30)
                for item in overview:
                    self.assertRegex(item["product_id"], r"^RPF-\d{3}$")
                    self.assertTrue(all(item["analysis_result"][key] is not None for key in SCORE_NAMES))
                self.assertEqual(api.get("/api/data/rpf?limit=100").json()["items"], saved_rows)
                csv = api.get("/api/data/rpf.csv").text
                self.assertIn("timeseries_anomaly_score", csv)
                self.assertNotIn("DEMO-RPF", csv)
                detail = api.get(f"/api/rpf/{overview[0]['id']}").json()
                self.assertEqual(len(detail["presentation"]["stages"]), 7)
                self.assertNotRegex(detail["presentation"]["report_draft"], "데모|합성|테스트")
                async def evidence(_url, body):
                    return [fact["id"] for fact in body["facts"]]
                def ask(q):
                    with patch("server.app.copilot.ask_laptop", side_effect=evidence):
                        reply = api.post("/api/copilot/chat", json={"question": q})
                    self.assertEqual(reply.status_code, 200, reply.text)
                    result = reply.json()
                    self.assertNotRegex(result["answer"], "데모|합성|테스트|DEMO")
                    return result
                metrics = ["공정 이상도", "검사 위험도", "공정 단계 시간 이상도"]
                for key, label in zip(SCORE_NAMES, metrics):
                    chart = ask(f"최근 30개 제품 {label} 그래프로 보여줘")["chart"]
                    self.assertEqual(chart["labels"], [row["product_id"] for row in reversed(saved_rows)])
                    self.assertEqual(chart["series"][0]["values"], [row[key] for row in reversed(saved_rows)])
                    comparison = ask(f"RPF-001과 RPF-002 {label} 비교 그래프로 보여줘")
                    for ident, value in zip(comparison["chart"]["labels"], comparison["chart"]["series"][0]["values"]):
                        self.assertEqual(value, next(row[key] for row in saved_rows if row["product_id"] == ident))
                comparison = ask("RPF-001과 RPF-002 비교해줘")["table"]
                for row in comparison["rows"]:
                    original = next(item for item in saved_rows if item["product_id"] == row[0])
                    for label, key in zip(metrics, SCORE_NAMES):
                        self.assertEqual(row[comparison["columns"].index(label)], original[key])
                # A question's premise must never overwrite the stored grade.
                self.assertIn("저장된 등급은 정상", ask("RPF-014가 왜 확인 필요야?")["answer"])
                review_id = next(row["product_id"] for row in saved_rows if row["retry_count"] > 0)
                self.assertIn("그리퍼", ask(f"{review_id} 점검 순서 알려줘")["answer"])
                self.assertIn("품질보고서 초안", ask("RPF-014 품질보고서 초안 작성해줘")["answer"])
        self.assertEqual(hashes, {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in hashes})
