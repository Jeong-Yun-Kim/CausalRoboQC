"""Prepare measured RPF inputs and call the laptop. No ML dependencies here."""

from datetime import datetime
import json
from typing import Annotated, Any

import httpx
from pydantic import BaseModel, Field, ValidationError


FEATURE_NAMES = ("work_time_ms", "retry_count", "error_count", "operator_interventions")
STAGES = ("HOME", "PICK_ABOVE", "PICK", "GRAB", "LIFT", "PLACE", "RELEASE")
Score = Annotated[float, Field(ge=0, le=1, allow_inf_nan=False, strict=True)]


class AnalysisError(Exception):
    def __init__(self, status_code: int, detail: str):
        super().__init__(detail)
        self.status_code = status_code
        self.detail = detail


class RpfFeatures(BaseModel):
    work_time_ms: float = Field(ge=0, allow_inf_nan=False, strict=True)
    retry_count: int = Field(ge=0, strict=True)
    error_count: int = Field(ge=0, strict=True)
    operator_interventions: int = Field(ge=0, strict=True)


class LaptopResult(BaseModel):
    rpf_id: int = Field(gt=0, strict=True)
    anomaly_score: Score
    inspection_risk_score: Score
    timeseries_anomaly_score: Score | None
    synthetic_model: bool = Field(strict=True)
    model_info: dict[str, Any] = Field(default_factory=dict)


def pose_sequence(events: list[dict], cycle_index: int | None = None) -> dict[str, float] | None:
    """Accept seven ordered request/finish pairs, optionally followed by return HOME.

    Extra/repeated poses, missing pairs, overlapping or invalid timestamps are
    ambiguous. They yield None rather than fabricated durations or averages.
    """
    poses = [event for event in events if event["name"] in {"POSE_REQUESTED", "POSE_FINISHED"}]
    if len(poses) not in (14, 16):
        return None
    expected = STAGES + (("HOME",) if len(poses) == 16 else ())
    result = {}
    previous_finish = None
    try:
        for index, stage in enumerate(expected):
            requested, finished = poses[index * 2:index * 2 + 2]
            if requested["name"] != "POSE_REQUESTED" or finished["name"] != "POSE_FINISHED":
                return None
            left, right = requested["payload"], finished["payload"]
            if left.get("pose") != stage or right.get("pose") != stage:
                return None
            for key, expected_value in (("step_index", index), ("cycle", cycle_index)):
                if left.get(key) != right.get(key):
                    return None
                if left.get(key) is not None and expected_value is not None and left[key] != expected_value:
                    return None
            start = datetime.fromisoformat(requested["created_at"].replace("Z", "+00:00"))
            end = datetime.fromisoformat(finished["created_at"].replace("Z", "+00:00"))
            if start.tzinfo is None or end.tzinfo is None or end <= start:
                return None
            if previous_finish is not None and start < previous_finish:
                return None
            if index < len(STAGES):
                result[stage] = (end - start).total_seconds() * 1000
            previous_finish = end
    except (KeyError, TypeError, ValueError, AttributeError):
        return None
    return result


class AnalysisClient:
    def __init__(self, base_url: str, timeout: float = 3, *, transport=None):
        self.client = httpx.AsyncClient(
            base_url=base_url.rstrip("/"), timeout=timeout, transport=transport,
        )

    async def close(self) -> None:
        await self.client.aclose()

    async def analyze(self, record: dict, events: list[dict]) -> dict:
        try:
            features = RpfFeatures.model_validate({name: record.get(name) for name in FEATURE_NAMES})
        except ValidationError as exc:
            raise AnalysisError(422, "RPF 분석에 필요한 작업시간 또는 횟수 데이터가 올바르지 않습니다.") from exc
        sequence = pose_sequence(events, record.get("cycle_index"))
        payload = {
            "rpf_id": record["id"], "product_id": record["product_id"],
            "features": features.model_dump(), "sequence": sequence,
        }
        try:
            response = await self.client.post("/api/analyze/rpf", json=payload)
            response.raise_for_status()
        except httpx.HTTPStatusError as exc:
            raise AnalysisError(502, "노트북 AI 서버가 분석 요청을 처리하지 못했습니다.") from exc
        except httpx.RequestError as exc:
            raise AnalysisError(503, "노트북 AI 서버에 연결할 수 없습니다. 연결 상태를 확인하고 다시 시도해 주세요.") from exc
        try:
            result = LaptopResult.model_validate(response.json())
            if result.rpf_id != record["id"]:
                raise ValueError("AI response RPF ID differs")
            if sequence is None and result.timeseries_anomaly_score is not None:
                raise ValueError("AI response supplied a score without a sequence")
            data = result.model_dump()
            json.dumps(data, allow_nan=False)
            return data
        except (ValidationError, ValueError, TypeError) as exc:
            raise AnalysisError(502, "노트북 AI 서버의 분석 응답 형식이 올바르지 않습니다.") from exc
