"""Local browser fixture, never used by production startup.

Run: python -m server.tests.copilot_browser_fixture
Build Flutter with --dart-define=API_BASE_URL=http://127.0.0.1:18000 first.
Pi :18000, existing AI :19000, mock Ollama :11435, built web :18080.
Only a temporary SQLite DB is seeded. Robot startup is disabled. Ctrl-C stops all.
"""

import asyncio
from contextlib import ExitStack
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import tempfile
import threading
from unittest.mock import AsyncMock, patch

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
import uvicorn

from ai.app.main import app as laptop
from scripts.seed_demo_rpf import seed_demo
from scripts.prepare_rpf_presentation import analyze_seed
from server.app.analysis_client import AnalysisClient
from server.app.database import Database
import httpx
from server.app.main import app as pi


mock = FastAPI()
mock.state.offline = False


@mock.post("/__test__/offline")
async def offline(request: Request):
    mock.state.offline = (await request.json())["offline"]
    return {"offline": mock.state.offline}


@mock.post("/api/chat")
async def respond(request: Request):
    if mock.state.offline:
        return JSONResponse(status_code=503, content={"error": "test Ollama offline"})
    body = await request.json()
    evidence = json.loads(body["messages"][-1]["content"])
    return {"done": True, "message": {"content": json.dumps({
        "fact_ids": [fact["id"] for fact in evidence["facts"][:8]]})}}


async def serve():
    servers = [uvicorn.Server(uvicorn.Config(application, host="127.0.0.1", port=port,
                                            log_level="warning"))
               for application, port in ((pi, 18000), (laptop, 19000), (mock, 11435))]
    await asyncio.gather(*(server.serve() for server in servers))


async def prepare(path):
    # Exercise the actual saved IF/RF/AE artifacts even though Ollama is a fixture.
    async with laptop.router.lifespan_context(laptop):
        client = AnalysisClient("http://laptop", transport=httpx.ASGITransport(app=laptop))
        database = Database(path)
        try:
            await analyze_seed(database, client)
        finally:
            await client.close()
            database.close()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="copilot-browser-") as temp, ExitStack() as stack:
        path = Path(temp) / "demo.db"
        seed_demo(path, Path("server/config/rpf_rules.json"))
        asyncio.run(prepare(path))
        stack.enter_context(patch.dict(os.environ, {
            "DATABASE_PATH": str(path), "ANALYSIS_BASE_URL": "http://127.0.0.1:19000",
            "OLLAMA_MODEL": "browser-test-fixture", "OLLAMA_BASE_URL": "http://127.0.0.1:11435",
            "OLLAMA_TIMEOUT_SECONDS": "2", "COPILOT_TIMEOUT_SECONDS": "5",
        }))
        stack.enter_context(patch("server.app.main.RobotService.start", new_callable=AsyncMock))
        stack.enter_context(patch("server.app.main.RobotService.shutdown", new_callable=AsyncMock))
        web = ThreadingHTTPServer(("127.0.0.1", 18080), partial(
            SimpleHTTPRequestHandler, directory="app/build/web"))
        stack.callback(web.server_close)
        stack.callback(web.shutdown)
        threading.Thread(target=web.serve_forever, daemon=True).start()
        print("Browser fixture: http://127.0.0.1:18080 (temporary demo DB, mock Ollama)", flush=True)
        asyncio.run(serve())
