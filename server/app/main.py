import os
from contextlib import asynccontextmanager
from typing import Annotated, Any, Literal

from fastapi import FastAPI, HTTPException, Path, Query, Request, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from .config import load_settings
from .analysis_client import AnalysisClient, AnalysisError
from .database import Database
from .service import RobotError, RobotService, WebSocketHub


class StartRunBody(BaseModel):
    repeat: bool = False
    mode: Literal["normal", "error"] = "normal"


class ServoBody(BaseModel):
    angle: int = Field(ge=0, le=180)


class PoseBody(BaseModel):
    angles: list[int] = Field(min_length=6, max_length=6)


class RunReviewBody(BaseModel):
    verdict: Literal["normal", "abnormal"]
    causes: list[str] = Field(default_factory=list, max_length=6)


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = load_settings()
    database = Database(settings.database_path)
    hub = WebSocketHub()
    service = RobotService(settings, database, hub)
    app.state.service = service
    analysis_client = AnalysisClient(settings.analysis_base_url, settings.analysis_timeout_seconds)
    app.state.analysis_client = analysis_client
    await service.start()
    try:
        yield
    finally:
        await analysis_client.close()
        await service.shutdown()
        await service.serial.stop()
        database.close()


app = FastAPI(title="CausalRoboQC Robot Arm API", version="0.1.0", lifespan=lifespan)

configured_origins = [
    item.strip() for item in os.getenv("CORS_ORIGINS", "").split(",") if item.strip()
]
app.add_middleware(
    CORSMiddleware,
    allow_origins=configured_origins,
    allow_origin_regex=r"https?://(localhost|127\.0\.0\.1)(:\d+)?",
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)


def service_from(request: Request) -> RobotService:
    return request.app.state.service


async def api_call(awaitable: Any) -> Any:
    try:
        return await awaitable
    except RobotError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.detail) from exc


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/")
async def root(request: Request) -> dict[str, Any]:
    return {"name": app.title, "status": service_from(request).status()}


@app.get("/api/status")
async def get_status(request: Request) -> dict[str, Any]:
    return service_from(request).status()


@app.get("/api/runs")
async def get_runs(
    request: Request,
    limit: Annotated[int, Query(ge=1, le=500)] = 100,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> dict[str, Any]:
    return {"items": service_from(request).database.list_runs(limit, offset)}


@app.get("/api/runs/{run_id}")
async def get_run(
    request: Request, run_id: Annotated[int, Path(ge=1)]
) -> dict[str, Any]:
    service = service_from(request)
    run = service.database.get_run(run_id)
    if run is None:
        raise HTTPException(status_code=404, detail="Run not found")
    return service.run_response(run)


@app.get("/api/runs/{run_id}/events")
async def get_run_events(
    request: Request,
    run_id: Annotated[int, Path(ge=1)],
    limit: Annotated[int, Query(ge=1, le=2000)] = 500,
    after_id: Annotated[int | None, Query(ge=0)] = None,
) -> dict[str, Any]:
    service = service_from(request)
    if service.database.get_run(run_id) is None:
        raise HTTPException(status_code=404, detail="Run not found")
    return {"items": service.database.list_events(run_id, limit, after_id)}


@app.get("/api/events")
async def get_events(
    request: Request,
    run_id: Annotated[int | None, Query(ge=1)] = None,
    limit: Annotated[int, Query(ge=1, le=2000)] = 500,
    after_id: Annotated[int | None, Query(ge=0)] = None,
) -> dict[str, Any]:
    return {
        "items": service_from(request).database.list_events(run_id, limit, after_id)
    }


@app.get("/api/rpf")
async def get_rpf_records(
    request: Request,
    limit: Annotated[int, Query(ge=1, le=500)] = 50,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> dict[str, Any]:
    return {"items": service_from(request).database.list_rpfs(limit, offset)}


@app.get("/api/rpf/{rpf_id}")
async def get_rpf_record(
    request: Request, rpf_id: Annotated[int, Path(ge=1)]
) -> dict[str, Any]:
    database = service_from(request).database
    record = database.get_rpf(rpf_id)
    if record is None:
        raise HTTPException(status_code=404, detail="RPF not found")
    return {**record, "events": database.list_rpf_events(rpf_id),
            "analysis_result": database.get_analysis_result(rpf_id)}


@app.post("/api/rpf/{rpf_id}/analyze")
async def analyze_rpf(
    request: Request, rpf_id: Annotated[int, Path(ge=1)]
) -> dict[str, Any]:
    database = service_from(request).database
    record = database.get_rpf(rpf_id)
    if record is None:
        raise HTTPException(status_code=404, detail="RPF not found")
    if record["status"] != "completed":
        raise HTTPException(status_code=409, detail="완료된 RPF만 분석할 수 있습니다.")
    try:
        result = await request.app.state.analysis_client.analyze(record, database.list_rpf_events(rpf_id))
    except AnalysisError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.detail) from exc
    return database.save_analysis_result(result)


@app.get("/api/calibration")
async def get_calibration(request: Request) -> dict[str, Any]:
    return service_from(request).calibration_response()


@app.post("/api/runs/start")
async def start_run(request: Request, body: StartRunBody) -> dict[str, Any]:
    run = await api_call(service_from(request).start_run(body.repeat, body.mode))
    return {"run": run}


@app.post("/api/runs/stop")
async def stop_run(request: Request) -> dict[str, Any]:
    return await api_call(service_from(request).stop_run())


@app.post("/api/runs/{run_id}/review")
async def review_run(
    request: Request,
    body: RunReviewBody,
    run_id: Annotated[int, Path(ge=1)],
) -> dict[str, Any]:
    return await api_call(
        service_from(request).review_run(run_id, body.verdict, body.causes)
    )


@app.post("/api/calibration/reset")
async def reset_calibration(request: Request) -> dict[str, Any]:
    return await api_call(service_from(request).reset_calibration())


@app.post("/api/servos/{joint}")
@app.post("/api/servos/{joint}/set", include_in_schema=False)
async def set_servo(
    request: Request,
    body: ServoBody,
    joint: Annotated[int, Path(ge=1, le=6)],
) -> dict[str, Any]:
    return await api_call(service_from(request).manual_set(joint, body.angle))


@app.post("/api/control/{command}")
async def control(request: Request, command: str) -> dict[str, Any]:
    return await api_call(service_from(request).control(command))


@app.get("/api/poses")
async def get_poses(request: Request) -> dict[str, Any]:
    try:
        return service_from(request).pose_response()
    except RobotError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.detail) from exc


@app.put("/api/poses/{name}")
async def save_pose(request: Request, name: str, body: PoseBody) -> dict[str, Any]:
    return await api_call(service_from(request).save_pose(name.upper(), body.angles))


@app.post("/api/poses/{name}/move")
async def move_pose(request: Request, name: str) -> dict[str, Any]:
    return await api_call(service_from(request).move_pose(name.upper()))


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket) -> None:
    service: RobotService = websocket.app.state.service
    await service.hub.connect(websocket)
    try:
        await service.hub.send(websocket, "snapshot", await service.websocket_snapshot())
        while True:
            message = await websocket.receive_text()
            if message.strip().lower() == "ping":
                await service.hub.send(websocket, "pong", {"updated_at": service.status()["updated_at"]})
    except WebSocketDisconnect:
        pass
    finally:
        service.hub.disconnect(websocket)
