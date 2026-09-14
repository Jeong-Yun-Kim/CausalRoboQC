"""Laptop copilot router. Only validated evidence can appear in an answer."""

from fastapi import APIRouter
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, model_validator

from .ollama_client import NO_DATA, UNAVAILABLE, CopilotUnavailable, configuration, select_facts


router = APIRouter(prefix="/api/copilot", tags=["copilot"])


class Fact(BaseModel):
    model_config = ConfigDict(extra="forbid")
    id: str = Field(pattern=r"^f\d{1,3}$")
    text: str = Field(min_length=1, max_length=4000)


class ChatBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    question: str = Field(min_length=1, max_length=1000)
    intent: str = Field(max_length=40)
    facts: list[Fact] = Field(default_factory=list, max_length=80)
    required_fact_ids: list[str] = Field(default_factory=list, max_length=80)
    demo_data: bool = False

    @model_validator(mode="after")
    def validate_facts(self):
        ids = [fact.id for fact in self.facts]
        if len(ids) != len(set(ids)) or any(item not in ids for item in self.required_fact_ids):
            raise ValueError("Invalid evidence references")
        if sum(len(fact.text) for fact in self.facts) > 32000:
            raise ValueError("Evidence too large")
        return self


@router.get("/health")
def health() -> dict:
    # Configuration status only, explicitly not a liveness/model probe.
    return {"status": "configured" if configuration()[1] else "unavailable",
            "ollama_checked": False}


@router.post("/chat")
async def chat(body: ChatBody):
    if not body.facts:
        return {"answer": NO_DATA, "table": None, "chart": None, "demo_data": body.demo_data,
                "fact_ids": []}
    try:
        selected = await select_facts(body.question, body.intent, [f.model_dump() for f in body.facts])
    except CopilotUnavailable:
        return JSONResponse(status_code=503, content={
            "answer": UNAVAILABLE, "table": None, "chart": None, "demo_data": body.demo_data})
    ids = list(dict.fromkeys([*body.required_fact_ids, *selected]))
    facts = {fact.id: fact.text for fact in body.facts}
    return {"answer": "\n\n".join(facts[item] for item in ids),
            "fact_ids": ids, "table": None, "chart": None, "demo_data": body.demo_data}
