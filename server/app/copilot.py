"""Isolated copilot HTTP path: read in a worker, await laptop without robot locks."""

import asyncio
import math
import os

import httpx
from fastapi import APIRouter, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field

from .copilot_queries import CopilotQueries


router = APIRouter(prefix="/api/copilot", tags=["copilot"])
UNAVAILABLE = "AI 코파일럿을 사용할 수 없습니다.\n로컬 AI 서버 상태를 확인해주세요."


class ChatBody(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)
    question: str = Field(min_length=1, max_length=1000)


def timeout_seconds() -> float:
    try:
        value = float(os.getenv("COPILOT_TIMEOUT_SECONDS", "55"))
    except ValueError:
        return 55.0
    return value if math.isfinite(value) and value > 0 else 55.0


async def ask_laptop(base_url: str, body: dict, *, transport=None) -> list[str]:
    timeout = timeout_seconds()
    async with httpx.AsyncClient(timeout=timeout, trust_env=False, transport=transport) as client:
        response = await asyncio.wait_for(client.post(
            f"{base_url.rstrip('/')}/api/copilot/chat", json=body), timeout=timeout)
    response.raise_for_status()
    ids = response.json()["fact_ids"]
    allowed = {fact["id"] for fact in body["facts"]}
    if (not isinstance(ids, list) or not ids or len(ids) > 80
            or any(not isinstance(item, str) or item not in allowed for item in ids)):
        raise ValueError("Invalid evidence")
    return list(dict.fromkeys([*body["required_fact_ids"], *ids]))


@router.get("/health")
def health() -> dict:
    return {"status": "ok", "optional": True, "ollama_checked": False}


@router.post("/chat")
async def chat(body: ChatBody, request: Request):
    service = request.app.state.service
    prepared = await run_in_threadpool(CopilotQueries(service.database).prepare, body.question)
    response = {key: prepared[key] for key in ("answer", "table", "chart", "demo_data")}
    if response["answer"]:
        return response
    try:
        ids = await ask_laptop(service.settings.analysis_base_url, {
            "question": body.question, "intent": prepared["intent"],
            "facts": prepared["facts"], "required_fact_ids": prepared["required_fact_ids"],
            "demo_data": prepared["demo_data"],
        })
        # Reconstruct from the Pi's own evidence. Ignore all laptop answer/table/chart text.
        facts = {fact["id"]: fact["text"] for fact in prepared["facts"]}
        response["answer"] = "\n\n".join(facts[ident] for ident in ids)
    except (httpx.HTTPError, httpx.InvalidURL, ValueError, TypeError, KeyError, AttributeError, asyncio.TimeoutError):
        return JSONResponse(status_code=503, content={
            "answer": UNAVAILABLE, "table": None, "chart": None, "demo_data": prepared["demo_data"]})
    return response
