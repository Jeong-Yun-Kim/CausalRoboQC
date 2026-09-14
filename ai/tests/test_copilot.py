import asyncio
import json
import os
import unittest
from unittest.mock import AsyncMock, patch

from fastapi import FastAPI
from fastapi.testclient import TestClient
import httpx

from ai.app.copilot import router
from ai.app.ollama_client import NO_DATA, UNAVAILABLE, select_facts


class CopilotTest(unittest.TestCase):
    def setUp(self):
        app = FastAPI()
        app.include_router(router)
        self.client = TestClient(app)
        self.body = {"question": "제품 설명해줘", "intent": "PRODUCT_DETAIL",
                     "facts": [{"id": "f0", "text": "저장된 등급은 확인 필요입니다."},
                               {"id": "f1", "text": "집기 재시도 1회가 기록되어 있습니다."}],
                     "required_fact_ids": ["f0"], "demo_data": True}
        patcher = patch.dict(os.environ, {"OLLAMA_MODEL": "test-model", "OLLAMA_TIMEOUT_SECONDS": "1"})
        patcher.start()
        self.addCleanup(patcher.stop)

    def request(self, responder):
        async def select(question, intent, facts):
            return await select_facts(question, intent, facts, transport=httpx.MockTransport(responder))
        with patch("ai.app.copilot.select_facts", side_effect=select):
            return self.client.post("/api/copilot/chat", json=self.body)

    def test_mock_success_only_evidence_is_rendered(self):
        def respond(request):
            payload = json.loads(request.content)
            self.assertEqual(payload["model"], "test-model")
            self.assertFalse(payload["stream"])
            self.assertNotIn("tools", payload)
            self.assertEqual(payload["format"]["properties"]["fact_ids"]["items"]["enum"], ["f0", "f1"])
            return httpx.Response(200, json={"done": True, "message": {"content": '{"fact_ids":["f1"]}'}})
        response = self.request(respond)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["answer"], "저장된 등급은 확인 필요입니다.\n\n집기 재시도 1회가 기록되어 있습니다.")
        self.assertTrue(response.json()["demo_data"])
        self.assertIsNone(response.json()["chart"])

    def test_off_timeout_missing_model_and_invalid_responses(self):
        def fail(error):
            def respond(request):
                raise error
            return respond
        for responder in (
            fail(httpx.ConnectError("connection refused http://private:11434")),
            fail(httpx.ReadTimeout("stack trace")),
            lambda _: httpx.Response(404, json={"error": "model missing"}),
            lambda _: httpx.Response(500, text="internal details"),
            lambda _: httpx.Response(200, text="invalid json"),
            lambda _: httpx.Response(200, json={"done": False}),
            lambda _: httpx.Response(200, json={"done": True, "message": {"content": '[]'}}),
            lambda _: httpx.Response(200, json={"done": True, "message": {"content": '{"fact_ids":["made-up"]}'}}),
            lambda _: httpx.Response(200, json={"done": True, "message": {"content": '{"fact_ids":["f0"],"answer":"9999"}'}}),
        ):
            with self.subTest(responder=responder):
                response = self.request(responder)
                self.assertEqual(response.status_code, 503)
                self.assertEqual(response.json()["answer"], UNAVAILABLE)
                self.assertIsNone(response.json()["chart"])

    def test_wall_clock_timeout(self):
        async def respond(request):
            await asyncio.sleep(1)
            return httpx.Response(200)
        with patch.dict(os.environ, {"OLLAMA_TIMEOUT_SECONDS": "0.01"}):
            self.assertEqual(self.request(respond).status_code, 503)

    def test_no_model_and_no_data_do_not_call_ollama(self):
        with patch.dict(os.environ, {"OLLAMA_MODEL": ""}), patch("ai.app.ollama_client.httpx.AsyncClient") as client:
            self.assertEqual(self.client.get("/api/copilot/health").json(),
                             {"status": "unavailable", "ollama_checked": False})
            self.assertEqual(self.client.post("/api/copilot/chat", json=self.body).status_code, 503)
            client.assert_not_called()
        with patch("ai.app.copilot.select_facts", new_callable=AsyncMock) as select:
            body = {**self.body, "facts": [], "required_fact_ids": []}
            self.assertEqual(self.client.post("/api/copilot/chat", json=body).json()["answer"], NO_DATA)
            select.assert_not_called()

    def test_bad_evidence_rejected(self):
        for extra in ({"required_fact_ids": ["f99"]}, {"sql": "SELECT *"},
                      {"facts": [self.body["facts"][0]] * 2}):
            self.assertEqual(self.client.post("/api/copilot/chat", json={**self.body, **extra}).status_code, 422)
