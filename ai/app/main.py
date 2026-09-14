"""Serve the existing synthetic trial models without training or generating data."""

from contextlib import asynccontextmanager
from typing import Annotated

from fastapi import FastAPI, Request
import pandas as pd
from pydantic import BaseModel, ConfigDict, Field
from .copilot import router as copilot_router

from ai.modeling import (
    FEATURE_NAMES, RISK_FEATURE_NAMES, SEQUENCE_FEATURE_NAMES, SyntheticModels,
    fail_probabilities, normalize_scores, numeric_features,
)


Duration = Annotated[float, Field(ge=0, allow_inf_nan=False, strict=True)]
StageDuration = Annotated[float, Field(gt=0, allow_inf_nan=False, strict=True)]
Count = Annotated[int, Field(ge=0, strict=True)]
Score = Annotated[float, Field(ge=0, le=1, allow_inf_nan=False)]


class Features(BaseModel):
    model_config = ConfigDict(extra="forbid")
    work_time_ms: Duration
    retry_count: Count
    error_count: Count
    operator_interventions: Count


class Sequence(BaseModel):
    model_config = ConfigDict(extra="forbid")
    HOME: StageDuration | None = None
    PICK_ABOVE: StageDuration | None = None
    PICK: StageDuration | None = None
    GRAB: StageDuration | None = None
    LIFT: StageDuration | None = None
    PLACE: StageDuration | None = None
    RELEASE: StageDuration | None = None


class AnalyzeBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    rpf_id: int = Field(gt=0, strict=True)
    product_id: str = Field(min_length=1, strict=True)
    features: Features
    sequence: Sequence | None = None


class AnalysisResult(BaseModel):
    rpf_id: int
    anomaly_score: Score
    inspection_risk_score: Score
    timeseries_anomaly_score: Score | None
    synthetic_model: bool
    model_info: dict


@asynccontextmanager
async def lifespan(app: FastAPI):
    # One load per server process, on CPU through the existing model loader.
    app.state.models = SyntheticModels()
    yield
    del app.state.models


app = FastAPI(title="CausalRoboQC Laptop ML/DL", lifespan=lifespan)
app.include_router(copilot_router)


@app.get("/health")
def health(request: Request) -> dict:
    return {"status": "ok", "synthetic_model": request.app.state.models.metadata["synthetic_data"]}


@app.post("/api/analyze/rpf", response_model=AnalysisResult)
def analyze(body: AnalyzeBody, request: Request) -> dict:
    models = request.app.state.models
    rpf = pd.DataFrame([body.features.model_dump()], columns=FEATURE_NAMES)
    sequence = body.sequence.model_dump() if body.sequence is not None else {}
    complete = all(sequence.get(name) is not None for name in SEQUENCE_FEATURE_NAMES)
    if complete:
        scores = models.predict(rpf, pd.DataFrame([sequence])).iloc[0].to_dict()
    else:
        # Reuse the loaded IF/RF and the exact existing normalization helpers.
        # Do not run the autoencoder with invented or padded stage durations.
        features = numeric_features(rpf, FEATURE_NAMES)
        raw = -models.isolation_forest.score_samples(models.feature_scaler.transform(features))
        anomaly = normalize_scores(raw, models.metadata["score_normalization"]["anomaly_score"])
        risk_features = features.assign(anomaly_score=anomaly).loc[:, RISK_FEATURE_NAMES]
        scores = {
            "anomaly_score": float(anomaly[0]),
            "inspection_risk_score": float(fail_probabilities(models.random_forest, risk_features)[0]),
            "timeseries_anomaly_score": None,
        }
    return {
        "rpf_id": body.rpf_id,
        **scores,
        "synthetic_model": models.metadata["synthetic_data"],
        "model_info": {
            "trained_at_utc": models.metadata["trained_at_utc"],
            "versions": models.metadata["versions"],
            "models": {name: info["type"] for name, info in models.metadata["models"].items()},
            "sequence_available": complete,
            "intended_use": models.metadata["intended_use"],
        },
    }
