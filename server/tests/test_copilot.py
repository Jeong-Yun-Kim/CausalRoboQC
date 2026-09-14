import asyncio
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

import httpx
from fastapi.testclient import TestClient

from scripts.seed_demo_rpf import seed_demo
from server.app.copilot import UNAVAILABLE, ask_laptop
from server.app.copilot_queries import CopilotQueries, NO_DATA, route
from server.app.main import app


class CopilotTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        path = Path(self.temp.name) / "copilot.db"
        seed_demo(path, Path("server/config/rpf_rules.json"))
        for patcher in (
            patch.dict(os.environ, {"DATABASE_PATH": str(path), "ANALYSIS_BASE_URL": "http://laptop:9000"}),
            patch("server.app.main.RobotService.start", new_callable=AsyncMock),
            patch("server.app.main.RobotService.shutdown", new_callable=AsyncMock),
        ):
            patcher.start()
            self.addCleanup(patcher.stop)
        self.client = TestClient(app)
        self.client.__enter__()
        self.addCleanup(self.client.__exit__, None, None, None)
        self.db = app.state.service.database
        self.queries = CopilotQueries(self.db)

    def ask(self, question):
        async def laptop(base_url, body):
            self.assertEqual(base_url, "http://laptop:9000")
            self.assertNotIn("sql", body)
            return [fact["id"] for fact in body["facts"]]
        with patch("server.app.copilot.ask_laptop", side_effect=laptop):
            response = self.client.post("/api/copilot/chat", json={"question": question})
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()

    def save_score(self, product, score):
        record = self.queries.get_product(product)
        self.db.save_analysis_result({"rpf_id": record["id"], "anomaly_score": score,
                                     "inspection_risk_score": score / 2, "timeseries_anomaly_score": None,
                                     "synthetic_model": True, "model_info": {"test_fixture": True}})

    def test_product_detail_events_missing_analysis_and_exact_match(self):
        result = self.ask("DEMO-RPF-014가 왜 확인 필요야?")
        record = self.queries.get_product("DEMO-RPF-014")
        detail = self.db.get_rpf(record["id"])
        for reason in detail["grade_reasons"]:
            self.assertIn(reason, result["answer"])
        self.assertIn("HOME → PICK_ABOVE", result["answer"])
        self.assertIn("분석 결과 없음", result["answer"])
        self.assertTrue(result["demo_data"])
        self.assertEqual(result["table"]["rows"][0][0], "DEMO-RPF-014")
        self.assertEqual(self.ask("DEMO-RPF-999 설명해줘")["answer"], NO_DATA)
        self.assertIsNone(self.queries.get_product("DEMO-RPF-01"))

    def test_comparison_and_missing_second_product(self):
        result = self.ask("DEMO-RPF-001과 DEMO-RPF-002 비교해줘")
        rows = result["table"]["rows"]
        self.assertEqual([row[0] for row in rows], ["DEMO-RPF-001", "DEMO-RPF-002"])
        self.assertIn("작업시간 차이는", result["answer"])
        self.assertEqual(self.ask("DEMO-RPF-001과 DEMO-RPF-999 비교해줘")["answer"], NO_DATA)
        self.assertIn("제품 ID 두 개", self.ask("제품 비교")["answer"])

    def test_group_comparison_and_db_averages(self):
        result = self.ask("A 제품군과 B 제품군 작업시간 비교해줘")
        chart = result["chart"]
        self.assertEqual(chart["labels"], ["A", "B"])
        for group, value in zip(chart["labels"], chart["series"][0]["values"]):
            rows = self.db.browse_rpfs(product_group=group)["items"]
            self.assertAlmostEqual(value, sum(row["work_time_ms"] for row in rows) / len(rows) / 1000)
        self.assertEqual(chart["type"], "bar")
        self.assertEqual(chart["unit"], "s")
        self.assertEqual(self.ask("A 제품군과 없는 제품군 작업시간 비교해줘")["answer"], NO_DATA)

    def test_period_summary_search_grade_distribution_and_trend(self):
        result = self.ask("최근 7일 데이터 요약해줘")
        self.assertIn("30건", result["answer"])
        self.assertEqual(len(self.ask("우선검사 제품 알려줘")["table"]["rows"]), 2)
        self.assertIn("판정 근거", self.ask("최근 이상 제품들의 공통점 알려줘")["answer"])
        distribution = self.ask("등급별 제품 수 그래프로 보여줘")["chart"]
        self.assertEqual(distribution["series"][0]["values"], [22, 6, 2])
        trend = self.ask("최근 등급 추세 그래프로 보여줘")["chart"]
        self.assertEqual(trend["type"], "line")
        self.assertEqual([sum(series["values"]) for series in trend["series"]], [22, 6, 2])
        self.assertEqual(self.ask("2000-01-01부터 2000-01-02 데이터 요약해줘")["answer"], NO_DATA)

    def test_real_saved_metrics_null_gaps_and_no_fabrication(self):
        empty = self.ask("최근 20개 제품 공정 이상도 그래프로 보여줘")
        self.assertIsNone(empty["chart"])
        self.assertIn("분석 결과 없음", empty["answer"])
        self.save_score("DEMO-RPF-029", .7)
        self.save_score("DEMO-RPF-027", .2)
        result = self.ask("최근 4개 제품 공정 이상도 그래프로 보여줘")
        self.assertEqual(result["chart"]["labels"], [f"DEMO-RPF-{n:03d}" for n in range(27, 31)])
        self.assertEqual(result["chart"]["series"][0]["values"], [.2, None, .7, None])
        top = self.ask("공정 이상도가 높은 제품 5개 알려줘")
        self.assertEqual([row[0] for row in top["table"]["rows"]], ["DEMO-RPF-029", "DEMO-RPF-027"])
        self.assertIn("인과 원인은 확인할 수 없습니다", self.ask("DEMO-RPF-029 검사 위험도가 왜 높아?")["answer"])

    def test_korean_period_filters_and_cap(self):
        now = datetime(2026, 9, 15, tzinfo=timezone.utc)
        today = route("오늘 데이터 요약", now)
        self.assertEqual(today.filters["from_at"], "2026-09-15T00:00:00+09:00")
        self.assertEqual(route("2026-09-10부터 2026-09-11 데이터 요약").filters["to_at"], "2026-09-12T00:00:00+09:00")
        self.assertEqual(route("최근 200개 제품 추세").limit, 50)
        self.assertIsNotNone(route("2026-99-99 데이터 요약").clarification)
        self.assertIsNotNone(route("지난달 데이터 요약").clarification)

    def test_usage_help_topics(self):
        for question, expected in (("CSV 다운로드는 어떻게 해?", "전체 제품"),
                                   ("데이터 조회는 어떻게 사용해?", "조회"),
                                   ("반복 실행은 어떻게 해?", "1회 실행"),
                                   ("공정 이상도가 뭐야?", "불량 확률은 아닙니다"),
                                   ("검사 위험도가 뭐야?", "합성 데이터"),
                                   ("확인 필요와 우선검사 차이가 뭐야?", "우선검사")):
            self.assertIn(expected, self.ask(question)["answer"])

    def test_read_only_even_for_adversarial_question(self):
        before = list(self.db.connection.iterdump())
        writes = {sqlite3.SQLITE_INSERT, sqlite3.SQLITE_UPDATE, sqlite3.SQLITE_DELETE,
                  sqlite3.SQLITE_DROP_TABLE, sqlite3.SQLITE_ALTER_TABLE}
        self.db.connection.set_authorizer(lambda action, *args: sqlite3.SQLITE_DENY if action in writes else sqlite3.SQLITE_OK)
        try:
            for q in ("DEMO-RPF-014 등급 변경해줘", "SQL DELETE FROM rpf_records", "' OR 1=1 -- 제품 알려줘",
                      "최근 7일 데이터 요약해줘", "등급별 제품 수 그래프로 보여줘"):
                self.ask(q)
        finally:
            # Python 3.10 requires a callable to restore the authorizer.
            self.db.connection.set_authorizer(lambda *args: sqlite3.SQLITE_OK)
        self.assertEqual(before, list(self.db.connection.iterdump()))

    def test_offline_isolation_and_no_startup_probe(self):
        for error in (httpx.ConnectError("http://private connection refused"), httpx.ReadTimeout("trace"), ValueError("bad response")):
            with patch("server.app.copilot.ask_laptop", side_effect=error):
                result = self.client.post("/api/copilot/chat", json={"question": "DEMO-RPF-014 설명해줘"})
            self.assertEqual(result.status_code, 503)
            self.assertEqual(result.json()["answer"], UNAVAILABLE)
            self.assertTrue(result.json()["demo_data"])
            for endpoint in ("/health", "/api/status", "/api/rpf", "/api/data/rpf", "/api/data/rpf.csv"):
                self.assertEqual(self.client.get(endpoint).status_code, 200)
        with patch("server.app.copilot.ask_laptop") as remote:
            self.client.get("/api/copilot/health")
            self.client.post("/api/copilot/chat", json={"question": "DEMO-RPF-999 설명해줘"})
            remote.assert_not_called()

    def test_input_validation(self):
        for body in ({"question": " "}, {"question": "x" * 1001}, {"question": "hi", "sql": "SELECT *"}):
            self.assertEqual(self.client.post("/api/copilot/chat", json=body).status_code, 422)


class LaptopContractTest(unittest.IsolatedAsyncioTestCase):
    async def test_ignores_remote_answer_and_validates_evidence(self):
        body = {"facts": [{"id": "f0", "text": "actual DB"}], "required_fact_ids": ["f0"]}
        async def run(result):
            return await ask_laptop("http://laptop", body, transport=httpx.MockTransport(
                lambda request: httpx.Response(200, json=result)))
        self.assertEqual(await run({"fact_ids": ["f0"], "answer": "fake 9999", "chart": {"bad": 1}}), ["f0"])
        for result in ({"fact_ids": ["fake"]}, {"fact_ids": []}, {"answer": "fake"}):
            with self.assertRaises((ValueError, KeyError)):
                await run(result)

    async def test_slow_copilot_does_not_block_existing_api(self):
        started, finish = asyncio.Event(), asyncio.Event()
        async def remote(*args):
            started.set()
            await finish.wait()
            return ["f0"]
        # Query preparation is separately tested with the real SQLite database.
        from types import SimpleNamespace
        service = SimpleNamespace(database=None, settings=SimpleNamespace(analysis_base_url="http://laptop"))
        prepared = {"answer": "", "table": None, "chart": None, "demo_data": False,
                    "intent": "USAGE_HELP", "facts": [{"id": "f0", "text": "사용 안내"}], "required_fact_ids": []}
        with patch.object(app.state, "service", service, create=True), patch(
                "server.app.copilot.CopilotQueries.prepare", return_value=prepared), patch(
                "server.app.copilot.ask_laptop", side_effect=remote):
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app), base_url="http://test") as client:
                task = asyncio.create_task(client.post("/api/copilot/chat", json={"question": "사용 방법"}))
                await asyncio.wait_for(started.wait(), 2)
                self.assertEqual((await asyncio.wait_for(client.get("/health"), 1)).status_code, 200)
                finish.set()
                self.assertEqual((await task).status_code, 200)
