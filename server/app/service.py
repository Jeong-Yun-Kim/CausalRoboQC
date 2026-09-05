import asyncio
import json
import os
from contextlib import suppress
from pathlib import Path
from time import monotonic
from typing import Any

from fastapi import WebSocket

from .config import Settings
from .database import Database, utc_now
from .rpf import RpfPipeline
from .serial_link import SerialLink


NORMAL_POSE_NAMES = (
    "HOME",
    "PICK_ABOVE",
    "PICK",
    "GRAB",
    "LIFT",
    "PLACE",
    "RELEASE",
)
ERROR_POSE_NAMES = ("ERROR_PICK", "ERROR_PLACE")
POSE_NAMES = NORMAL_POSE_NAMES + ERROR_POSE_NAMES
RUN_SEQUENCE = (
    "HOME",
    "PICK_ABOVE",
    "PICK",
    "GRAB",
    "LIFT",
    "PLACE",
    "RELEASE",
    "HOME",
)
ERROR_RUN_SEQUENCE = (
    "HOME",
    "PICK_ABOVE",
    "ERROR_PICK",
    "PICK_ABOVE",
    "PICK",
    "GRAB",
    "LIFT",
    "ERROR_PLACE",
    "LIFT",
    "PLACE",
    "RELEASE",
    "HOME",
)
DEFAULT_LIMITS = [[0, 180] for _ in range(6)]
REVIEW_CAUSES = (
    "집기 재시도",
    "작업시간 초과",
    "배치 실패",
    "제품 ID 불일치",
    "작업자 수동 보정",
    "기타",
)
ERROR_SUGGESTED_CAUSES = ("집기 재시도", "작업시간 초과", "배치 실패")
ERROR_INJECTIONS = {
    "ERROR_PICK": ("PICK_RETRY_INJECTED", "집기 재시도"),
    "ERROR_PLACE": ("PLACE_FAILURE_INJECTED", "배치 실패"),
}


class RobotError(Exception):
    def __init__(self, status_code: int, detail: str):
        super().__init__(detail)
        self.status_code = status_code
        self.detail = detail


class WebSocketHub:
    def __init__(self) -> None:
        self.connections: set[WebSocket] = set()
        self.lock = asyncio.Lock()

    async def connect(self, websocket: WebSocket) -> None:
        await websocket.accept()
        self.connections.add(websocket)

    def disconnect(self, websocket: WebSocket) -> None:
        self.connections.discard(websocket)

    async def send(self, websocket: WebSocket, event_type: str, data: Any) -> None:
        async with self.lock:
            await websocket.send_json({"type": event_type, "data": data})

    async def broadcast(self, event_type: str, data: Any) -> None:
        if not self.connections:
            return
        message = {"type": event_type, "data": data}
        async with self.lock:
            sockets = list(self.connections)
            results = await asyncio.gather(
                *(
                    asyncio.wait_for(socket.send_json(message), timeout=1.0)
                    for socket in sockets
                ),
                return_exceptions=True,
            )
        for socket, result in zip(sockets, results):
            if isinstance(result, Exception):
                self.connections.discard(socket)


class PoseStore:
    def __init__(self, path: Path):
        self.path = path

    @staticmethod
    def _valid_pose(value: Any) -> list[int] | None:
        if not isinstance(value, list) or len(value) != 6:
            return None
        if any(isinstance(item, bool) or not isinstance(item, int) for item in value):
            return None
        if any(item < 0 or item > 180 for item in value):
            return None
        return list(value)

    def load(self) -> dict[str, list[int] | None]:
        result: dict[str, list[int] | None] = {name: None for name in POSE_NAMES}
        try:
            with self.path.open("r", encoding="utf-8") as file:
                data = json.load(file)
        except FileNotFoundError:
            return result
        except (OSError, json.JSONDecodeError) as exc:
            raise RobotError(500, f"Cannot read poses.json: {exc}") from exc
        if not isinstance(data, dict):
            raise RobotError(500, "poses.json must contain a JSON object")
        for name in POSE_NAMES:
            value = data.get(name)
            if value is not None:
                pose = self._valid_pose(value)
                if pose is None:
                    raise RobotError(500, f"Invalid pose in poses.json: {name}")
                result[name] = pose
        return result

    def save(self, name: str, angles: list[int]) -> dict[str, list[int] | None]:
        if name not in POSE_NAMES:
            raise RobotError(404, f"Unknown pose: {name}")
        pose = self._valid_pose(angles)
        if pose is None:
            raise RobotError(422, "angles must contain six integers from 0 to 180")
        poses = self.load()
        poses[name] = pose
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_name(self.path.name + ".tmp")
        try:
            with temporary.open("w", encoding="utf-8") as file:
                json.dump(poses, file, ensure_ascii=False, indent=2)
                file.write("\n")
            os.replace(temporary, self.path)
        except OSError as exc:
            with suppress(OSError):
                temporary.unlink()
            raise RobotError(500, f"Cannot save poses.json: {exc}") from exc
        return poses


class RobotService:
    def __init__(self, settings: Settings, database: Database, hub: WebSocketHub):
        self.settings = settings
        self.database = database
        self.hub = hub
        self.poses = PoseStore(settings.poses_path)
        self.robot: dict[str, Any] = {
            "attached_mask": 0,
            "moving": False,
            "estop": False,
            "current_angles": [None] * 6,
            "target_angles": [None] * 6,
            "limits": [list(pair) for pair in DEFAULT_LIMITS],
        }
        self.initialized_joints: set[int] = set()
        self.active_run_id: int | None = None
        self.active_rpf_id: int | None = None
        self.active_rpf_started: float | None = None
        self.run_task: asyncio.Task[None] | None = None
        self.manual_move_task: asyncio.Task[Any] | None = None
        self._waiters: list[tuple[Any, asyncio.Future[str]]] = []
        self._command_lock = asyncio.Lock()
        self._command_owner: asyncio.Task[Any] | None = None
        self._stop_lock = asyncio.Lock()
        self._serial_was_ready = False
        self.rpf = RpfPipeline(database, settings.rpf_rules_path)
        self.serial = SerialLink(settings, self.handle_line, self.handle_serial_state)

    async def start(self) -> None:
        interrupted_rpfs = self.database.list_running_rpfs()
        self.database.recover_interrupted_runs()
        for record in interrupted_rpfs:
            self.rpf.finish_cycle(int(record["id"]), "failed", None)
        await self.serial.start()

    async def shutdown(self) -> None:
        run_id = self.active_run_id
        manual_task = self.manual_move_task
        motion_was_active = run_id is not None or (
            manual_task is not None and not manual_task.done()
        )
        if run_id is not None:
            task = self.run_task
            if task is not None and not task.done():
                task.cancel()
                with suppress(asyncio.CancelledError):
                    await task
        if manual_task is not None and not manual_task.done():
            manual_task.cancel()
            with suppress(asyncio.CancelledError):
                await manual_task
        await self._interrupt_pending_command()
        if motion_was_active and self.serial.ready:
            with suppress(Exception):
                await self._send_command(
                    "STOP",
                    lambda line: line == "OK STOP",
                    "STOP_REQUESTED",
                    {"reason": "server_shutdown"},
                    run_id,
                )
        if run_id is not None:
            await self._finish_run(run_id, "interrupted", "Server shutdown", "RUN_INTERRUPTED")
        self._fail_waiters(ConnectionError("Server is shutting down"))

    def run_response(
        self, run: dict[str, Any] | None
    ) -> dict[str, Any] | None:
        if run is None:
            return None
        response = dict(run)
        if response.get("run_mode") == "error":
            response["suggested_verdict"] = "abnormal"
            response["suggested_causes"] = list(ERROR_SUGGESTED_CAUSES)
        else:
            response["suggested_verdict"] = "normal"
            response["suggested_causes"] = []
        return response

    def status(self) -> dict[str, Any]:
        robot = dict(self.robot)
        robot["current_angles"] = list(self.robot["current_angles"])
        robot["target_angles"] = list(self.robot["target_angles"])
        robot["limits"] = [list(pair) for pair in self.robot["limits"]]
        robot["initialized_joints"] = sorted(self.initialized_joints)
        robot["initialized"] = (
            self.initialized_joints == set(range(1, 7))
            and self.robot["attached_mask"] == 63
        )
        return {
            "serial": self.serial.snapshot(),
            "robot": robot,
            "active_run": self.run_response(self.database.get_run(self.active_run_id))
            if self.active_run_id is not None
            else None,
            "sequence": list(RUN_SEQUENCE),
            "error_sequence": list(ERROR_RUN_SEQUENCE),
            "calibration": self.calibration_response(),
            "updated_at": utc_now(),
        }

    def calibration_response(self) -> dict[str, Any]:
        result = self.database.calibration_status(self.settings.repeat_unlock_samples)
        result["latest_unreviewed_run"] = self.run_response(
            result.get("latest_unreviewed_run")
        )
        result["cause_options"] = list(REVIEW_CAUSES)
        return result

    def pose_response(self) -> dict[str, Any]:
        return {
            "poses": self.poses.load(),
            "sequence": list(RUN_SEQUENCE),
            "error_sequence": list(ERROR_RUN_SEQUENCE),
        }

    async def websocket_snapshot(self) -> dict[str, Any]:
        return {"status": self.status(), "poses": self.pose_response()}

    async def _broadcast_status(self) -> None:
        await self.hub.broadcast("status", self.status())

    async def _add_event(
        self,
        event_type: str,
        name: str,
        payload: dict[str, Any] | None = None,
        raw: str | None = None,
        run_id: int | None = None,
        rpf_id: int | None = None,
    ) -> dict[str, Any]:
        if run_id is None:
            run_id = self.active_run_id
        if rpf_id is None and run_id == self.active_run_id:
            rpf_id = self.active_rpf_id
        event = self.database.add_event(
            run_id, event_type, name, payload, raw, rpf_id=rpf_id
        )
        await self.hub.broadcast("event", event)
        return event

    def _fail_waiters(self, exception: Exception) -> None:
        waiters = self._waiters
        self._waiters = []
        for _, future in waiters:
            if not future.done():
                future.set_exception(exception)

    def _new_waiter(self, predicate: Any) -> asyncio.Future[str]:
        future: asyncio.Future[str] = asyncio.get_running_loop().create_future()
        self._waiters.append((predicate, future))
        return future

    def _remove_waiter(self, future: asyncio.Future[str]) -> None:
        self._waiters = [(test, item) for test, item in self._waiters if item is not future]
        if not future.done():
            future.cancel()

    async def handle_serial_state(self, state: dict[str, Any]) -> None:
        ready = bool(state["ready"])
        if self._serial_was_ready and not ready:
            self.initialized_joints.clear()
            self.robot.update(
                attached_mask=0,
                moving=False,
                current_angles=[None] * 6,
                target_angles=[None] * 6,
            )
            self._fail_waiters(ConnectionError(state.get("last_error") or "Arduino disconnected"))
            if self.active_run_id is not None:
                await self._cancel_active_run("failed", "Arduino connection lost")
        self._serial_was_ready = ready
        await self._broadcast_status()

    def _parse_status(self, parts: list[str]) -> None:
        if len(parts) != 16:
            return
        try:
            mask = int(parts[1])
            moving = bool(int(parts[2]))
            estop = bool(int(parts[3]))
            current = [int(value) for value in parts[4:10]]
            target = [int(value) for value in parts[10:16]]
        except ValueError:
            return
        self.robot["attached_mask"] = mask
        self.robot["moving"] = moving
        self.robot["estop"] = estop
        self.robot["current_angles"] = [value if value >= 0 else None for value in current]
        self.robot["target_angles"] = [value if value >= 0 else None for value in target]

    def _parse_limits(self, parts: list[str]) -> None:
        if len(parts) != 13:
            return
        try:
            values = [int(value) for value in parts[1:]]
        except ValueError:
            return
        self.robot["limits"] = [[values[index], values[index + 1]] for index in range(0, 12, 2)]

    async def handle_line(self, line: str) -> None:
        parts = line.split()
        if not parts:
            return
        line_run_id = self.active_run_id
        response = parts[0].upper()
        if response == "STATUS":
            self._parse_status(parts)
        elif response == "LIMITS":
            self._parse_limits(parts)
        elif response == "DONE":
            self.robot["moving"] = False
            self.robot["current_angles"] = list(self.robot["target_angles"])
        elif response == "READY":
            self.initialized_joints.clear()
            self.robot.update(
                attached_mask=0,
                moving=False,
                estop=False,
                current_angles=[None] * 6,
                target_angles=[None] * 6,
            )

        payload: dict[str, Any] = {"response": response, "tokens": parts[1:]}
        if response == "STATUS":
            payload["status"] = {
                "attached_mask": self.robot["attached_mask"],
                "moving": self.robot["moving"],
                "estop": self.robot["estop"],
                "current_angles": self.robot["current_angles"],
                "target_angles": self.robot["target_angles"],
            }
        event = None
        if line_run_id is not None or response != "STATUS":
            event = self.database.add_event(
                line_run_id,
                "P",
                f"ARDUINO_{response}",
                payload,
                line,
                rpf_id=self.active_rpf_id if line_run_id is not None else None,
            )
        for predicate, future in list(self._waiters):
            if not future.done() and predicate(line):
                future.set_result(line)
                self._remove_waiter(future)
        if event is not None:
            await self.hub.broadcast("event", event)
        if response == "READY" and line_run_id is not None:
            await self._cancel_active_run("failed", "Arduino restarted")
        await self._broadcast_status()

    async def _send_command(
        self,
        command: str,
        expected: Any,
        request_name: str,
        payload: dict[str, Any],
        run_id: int | None,
        timeout: float = 3.0,
    ) -> str:
        if not self.serial.ready:
            raise RobotError(503, "Arduino is not connected and ready")
        async with self._command_lock:
            owner = asyncio.current_task()
            self._command_owner = owner
            waiter = self._new_waiter(
                lambda line: expected(line) or line.upper().startswith("ERR ")
            )
            try:
                await self._add_event(
                    "R", request_name, payload, raw=command, run_id=run_id
                )
                await self.serial.send(command)
                line = await asyncio.wait_for(waiter, timeout=timeout)
            except asyncio.TimeoutError as exc:
                self._remove_waiter(waiter)
                raise RobotError(504, f"Arduino response timeout for {command.split()[0]}") from exc
            except (ConnectionError, OSError) as exc:
                self._remove_waiter(waiter)
                raise RobotError(503, str(exc)) from exc
            finally:
                self._remove_waiter(waiter)
                if self._command_owner is owner:
                    self._command_owner = None
        if line.upper().startswith("ERR "):
            raise RobotError(409, f"Arduino rejected command: {line}")
        return line

    def _require_idle_and_ready(self) -> None:
        if not self.serial.ready:
            raise RobotError(503, "Arduino is not connected and ready")
        if self.active_run_id is not None:
            raise RobotError(409, "A run is already active")
        if self.manual_move_task is not None and not self.manual_move_task.done():
            raise RobotError(409, "A pose move is already active")

    async def manual_set(self, joint: int, angle: int) -> dict[str, Any]:
        self._require_idle_and_ready()
        if self.robot["estop"]:
            raise RobotError(409, "Emergency stop is latched; send RESET first")
        if joint < 1 or joint > 6:
            raise RobotError(422, "joint must be from 1 to 6")
        low, high = self.robot["limits"][joint - 1]
        if isinstance(angle, bool) or angle < low or angle > high:
            raise RobotError(422, f"Joint {joint} angle must be from {low} to {high}")
        self.manual_move_task = asyncio.current_task()
        settled_waiter: asyncio.Future[str] | None = None
        try:
            command = f"SET {joint} {angle}"
            await self._send_command(
                command,
                lambda line: line == f"OK SET {joint} {angle}",
                "SERVO_SET_REQUESTED",
                {"joint": joint, "angle": angle},
                None,
            )
            self.robot["attached_mask"] |= 1 << (joint - 1)
            self.robot["target_angles"][joint - 1] = angle
            settled_waiter = self._new_waiter(
                lambda line: line.startswith("STATUS ")
                and self.robot["current_angles"][joint - 1] == angle
                and not self.robot["moving"]
            )
            await self.serial.send("STATUS")
            try:
                await asyncio.wait_for(
                    settled_waiter, timeout=self.settings.move_timeout_seconds
                )
            except asyncio.TimeoutError as exc:
                raise RobotError(504, f"Servo movement timed out: Joint {joint}") from exc
            self.initialized_joints.add(joint)
            await self._add_event(
                "F",
                "SERVO_SET_FINISHED",
                {"joint": joint, "angle": angle},
                run_id=None,
            )
            await self._broadcast_status()
            return {"ok": True, "joint": joint, "angle": angle, "status": self.status()}
        finally:
            if settled_waiter is not None:
                self._remove_waiter(settled_waiter)
            self.manual_move_task = None

    async def _move_pose(
        self,
        name: str,
        angles: list[int],
        run_id: int | None,
        step_index: int | None = None,
        cycle: int | None = None,
    ) -> None:
        done_waiter = self._new_waiter(lambda line: line == "DONE")
        payload: dict[str, Any] = {"pose": name, "angles": angles}
        if step_index is not None:
            payload["step_index"] = step_index
        if cycle is not None:
            payload["cycle"] = cycle
        command = "MOVE " + " ".join(str(value) for value in angles)
        try:
            await self._send_command(
                command,
                lambda line: line == "OK MOVE",
                "POSE_REQUESTED",
                payload,
                run_id,
            )
            self.robot["moving"] = True
            self.robot["target_angles"] = list(angles)
            await self._broadcast_status()
            try:
                await asyncio.wait_for(done_waiter, timeout=self.settings.move_timeout_seconds)
            except asyncio.TimeoutError as exc:
                raise RobotError(504, f"Pose movement timed out: {name}") from exc
        finally:
            self._remove_waiter(done_waiter)
        self.robot["moving"] = False
        self.robot["attached_mask"] = 63
        self.robot["current_angles"] = list(angles)
        self.initialized_joints.update(range(1, 7))
        await self._add_event("F", "POSE_FINISHED", payload, raw="DONE", run_id=run_id)
        await self._broadcast_status()

    async def move_pose(self, name: str) -> dict[str, Any]:
        self._require_idle_and_ready()
        if self.robot["estop"]:
            raise RobotError(409, "Emergency stop is latched; send RESET first")
        if name not in POSE_NAMES:
            raise RobotError(404, f"Unknown pose: {name}")
        pose = self.poses.load()[name]
        if pose is None:
            raise RobotError(409, f"Pose is not saved: {name}")
        self.manual_move_task = asyncio.current_task()
        try:
            await self._move_pose(name, pose, None)
        finally:
            self.manual_move_task = None
        return {"ok": True, "name": name, "angles": pose, "status": self.status()}

    async def save_pose(self, name: str, angles: list[int]) -> dict[str, Any]:
        limits = self.robot["limits"]
        if len(angles) != 6 or any(
            isinstance(value, bool)
            or value < limits[index][0]
            or value > limits[index][1]
            for index, value in enumerate(angles)
        ):
            raise RobotError(422, "angles must contain six integers within the servo limits")
        poses = self.poses.save(name, angles)
        response = {"name": name, "angles": list(angles), "poses": poses}
        await self.hub.broadcast(
            "poses",
            {
                "poses": poses,
                "sequence": list(RUN_SEQUENCE),
                "error_sequence": list(ERROR_RUN_SEQUENCE),
            },
        )
        return response

    async def start_run(
        self, repeat: bool, mode: str = "normal"
    ) -> dict[str, Any]:
        run_mode = mode.strip().lower() if isinstance(mode, str) else ""
        if run_mode not in {"normal", "error"}:
            raise RobotError(422, "mode must be normal or error")
        if repeat and run_mode == "error":
            raise RobotError(409, "오류 로직은 1회 실행으로만 사용할 수 있습니다.")
        if repeat:
            calibration = self.calibration_response()
            if not calibration["repeat_unlocked"]:
                raise RobotError(
                    409,
                    "반복 실행 잠금: 1회 실행 결과를 "
                    f"{calibration['remaining_samples']}건 더 기록하세요.",
                )
        self._require_idle_and_ready()
        if self.robot["estop"]:
            raise RobotError(409, "Emergency stop is latched; send RESET first")
        sequence = ERROR_RUN_SEQUENCE if run_mode == "error" else RUN_SEQUENCE
        required_poses = tuple(dict.fromkeys(sequence))
        poses = self.poses.load()
        missing = [name for name in required_poses if poses[name] is None]
        if missing:
            raise RobotError(409, "Missing poses: " + ", ".join(missing))
        invalid = [
            name
            for name in required_poses
            if poses[name] is not None
            and any(
                value < self.robot["limits"][index][0]
                or value > self.robot["limits"][index][1]
                for index, value in enumerate(poses[name])
            )
        ]
        if invalid:
            raise RobotError(409, "Poses outside current servo limits: " + ", ".join(invalid))
        run = self.database.create_run(repeat, run_mode)
        run_id = int(run["id"])
        self.active_run_id = run_id
        await self._add_event(
            "R",
            "RUN_STARTED",
            {"repeat": repeat, "mode": run_mode, "sequence": list(sequence)},
            run_id=run_id,
        )
        self.run_task = asyncio.create_task(
            self._execute_run(run_id, repeat, run_mode, sequence, poses),
            name=f"robot-run-{run_id}",
        )
        await self._broadcast_status()
        return self.run_response(self.database.get_run(run_id))

    async def review_run(
        self, run_id: int, verdict: str, causes: list[str]
    ) -> dict[str, Any]:
        run = self.database.get_run(run_id)
        if run is None:
            raise RobotError(404, "Run not found")
        if run["repeat"]:
            raise RobotError(409, "반복 실행 Run은 준비 데이터로 판정할 수 없습니다.")
        if run["status"] != "completed":
            raise RobotError(409, "완료된 1회 실행만 판정할 수 있습니다.")

        calibration = self.calibration_response()
        if run["started_at"] < calibration["reset_at"]:
            raise RobotError(409, "초기화 이전 Run은 다시 판정할 수 없습니다.")
        if verdict not in {"normal", "abnormal"}:
            raise RobotError(422, "verdict must be normal or abnormal")

        unique_causes = list(dict.fromkeys(causes))
        unknown = [cause for cause in unique_causes if cause not in REVIEW_CAUSES]
        if unknown:
            raise RobotError(422, "지원하지 않는 이상 원인: " + ", ".join(unknown))
        if verdict == "normal":
            unique_causes = []
        elif not unique_causes:
            raise RobotError(422, "이상 공정은 원인을 하나 이상 선택해야 합니다.")

        review = self.database.save_run_review(run_id, verdict, unique_causes)
        await self._add_event(
            "F",
            "RUN_REVIEW_SAVED",
            {"verdict": verdict, "causes": unique_causes},
            run_id=run_id,
        )
        await self._broadcast_status()
        return {"review": review, "calibration": self.calibration_response()}

    async def reset_calibration(self) -> dict[str, Any]:
        if self.active_run_id is not None:
            raise RobotError(409, "실행 중에는 준비 데이터를 초기화할 수 없습니다.")
        state = self.database.reset_calibration()
        await self._add_event(
            "F",
            "CALIBRATION_RESET",
            {"generation": state["generation"]},
            run_id=None,
        )
        await self._broadcast_status()
        return {"ok": True, "calibration": self.calibration_response()}

    async def _execute_run(
        self,
        run_id: int,
        repeat: bool,
        run_mode: str,
        sequence: tuple[str, ...],
        poses: dict[str, list[int] | None],
    ) -> None:
        cycle = 0
        try:
            while True:
                rpf = self.rpf.start_cycle(run_id, cycle)
                self.active_rpf_id = int(rpf["id"])
                self.active_rpf_started = monotonic()
                try:
                    await self._add_event(
                        "F",
                        "RPF_STARTED",
                        {"cycle": cycle, "product_id": rpf["product_id"]},
                        run_id=run_id,
                        rpf_id=self.active_rpf_id,
                    )
                    for step_index, name in enumerate(sequence):
                        pose = poses[name]
                        if pose is None:
                            raise RobotError(409, f"Pose is not saved: {name}")
                        self.database.update_run(
                            run_id,
                            current_pose=name,
                            step_index=step_index,
                            cycle_count=cycle,
                        )
                        await self._broadcast_status()
                        injection = ERROR_INJECTIONS.get(name)
                        if run_mode == "error" and injection is not None:
                            event_name, cause = injection
                            await self._add_event(
                                "F",
                                event_name,
                                {
                                    "synthetic": True,
                                    "source": "error_test",
                                    "cause": cause,
                                    "pose": name,
                                    "step_index": step_index,
                                    "cycle": cycle,
                                },
                                run_id=run_id,
                            )
                        await self._move_pose(name, pose, run_id, step_index, cycle)
                        await asyncio.sleep(self.settings.pose_pause_seconds)
                    if run_mode == "error":
                        await self._add_event(
                            "F",
                            "WORK_TIME_OVERRUN_INJECTED",
                            {
                                "synthetic": True,
                                "source": "error_test",
                                "cause": "작업시간 초과",
                                "cycle": cycle,
                            },
                            run_id=run_id,
                        )
                except asyncio.CancelledError:
                    await self._finish_active_rpf("failed")
                    raise
                except Exception as exc:
                    await self._add_event(
                        "F",
                        "RPF_FAILED",
                        {"error": str(exc), "cycle": cycle},
                        run_id=run_id,
                    )
                    await self._finish_active_rpf("failed")
                    raise
                else:
                    await self._finish_active_rpf("completed")
                cycle += 1
                self.database.update_run(run_id, cycle_count=cycle, step_index=0)
                if not repeat:
                    await self._finish_run(run_id, "completed", None, "RUN_FINISHED")
                    return
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            with suppress(Exception):
                if self.serial.ready:
                    await self._send_command(
                        "STOP",
                        lambda line: line == "OK STOP",
                        "STOP_REQUESTED",
                        {"reason": "run_error"},
                        run_id,
                    )
            await self._finish_run(run_id, "failed", str(exc), "RUN_FAILED")

    async def _finish_active_rpf(self, status: str) -> dict[str, Any] | None:
        rpf_id = self.active_rpf_id
        if rpf_id is None:
            return None
        started = self.active_rpf_started
        elapsed_ms = None if started is None else round((monotonic() - started) * 1000)
        event = self.database.add_event(
            self.active_run_id,
            "F",
            "RPF_FINISHED",
            {"status": status},
            rpf_id=rpf_id,
        )
        record = self.rpf.finish_cycle(rpf_id, status, elapsed_ms)
        self.active_rpf_id = None
        self.active_rpf_started = None
        await self.hub.broadcast("event", event)
        return record

    async def _finish_run(
        self, run_id: int, status: str, error: str | None, event_name: str
    ) -> dict[str, Any] | None:
        current = self.database.get_run(run_id)
        if current is None or current["status"] not in {"running", "stopping"}:
            if self.active_run_id == run_id:
                self.active_run_id = None
                self.run_task = None
            return current
        run = self.database.update_run(
            run_id, status=status, finished_at=utc_now(), error=error
        )
        await self._add_event(
            "F", event_name, {"status": status, "error": error}, run_id=run_id
        )
        if self.active_run_id == run_id:
            self.active_run_id = None
            self.run_task = None
        await self._broadcast_status()
        return run

    async def _cancel_active_run(self, status: str, reason: str) -> dict[str, Any] | None:
        run_id = self.active_run_id
        if run_id is None:
            return None
        task = self.run_task
        if task is not None and task is not asyncio.current_task() and not task.done():
            task.cancel()
            with suppress(asyncio.CancelledError):
                await task
        return await self._finish_run(run_id, status, reason, f"RUN_{status.upper()}")

    async def _interrupt_pending_command(self) -> None:
        owner = self._command_owner
        if owner is not None and owner is not asyncio.current_task() and not owner.done():
            owner.cancel()
            with suppress(asyncio.CancelledError):
                await owner

    async def stop_run(self) -> dict[str, Any]:
        async with self._stop_lock:
            run_id = self.active_run_id
            if run_id is not None:
                self.database.update_run(run_id, status="stopping")
                await self._add_event(
                    "F",
                    "OPERATOR_INTERVENTION",
                    {"action": "STOP"},
                    run_id=run_id,
                )
                task = self.run_task
                if task is not None and not task.done():
                    task.cancel()
                    with suppress(asyncio.CancelledError):
                        await task
            if self.manual_move_task is not None and not self.manual_move_task.done():
                task = self.manual_move_task
                task.cancel()
                with suppress(asyncio.CancelledError):
                    await task
            await self._interrupt_pending_command()
            try:
                await self._send_command(
                    "STOP",
                    lambda line: line == "OK STOP",
                    "STOP_REQUESTED",
                    {"reason": "user"},
                    run_id,
                )
            except RobotError as exc:
                self.robot["moving"] = False
                if run_id is not None:
                    await self._finish_run(
                        run_id, "failed", exc.detail, "RUN_STOP_FAILED"
                    )
                raise
            self.robot["moving"] = False
            run = None
            if run_id is not None:
                run = await self._finish_run(run_id, "stopped", None, "RUN_STOPPED")
            await self._broadcast_status()
            return {"run": run, "status": self.status()}

    async def control(self, command: str) -> dict[str, Any]:
        command = command.upper()
        if command == "STOP":
            result = await self.stop_run()
            return {"ok": True, "command": command, **result}
        if command not in {"ESTOP", "RESET", "DETACH"}:
            raise RobotError(404, f"Unknown control command: {command}")
        async with self._stop_lock:
            run_id = self.active_run_id
            if command in {"ESTOP", "DETACH"} and run_id is not None:
                await self._add_event(
                    "F",
                    "OPERATOR_INTERVENTION",
                    {"action": command},
                    run_id=run_id,
                )
                task = self.run_task
                if task is not None and not task.done():
                    task.cancel()
                    with suppress(asyncio.CancelledError):
                        await task
            if command in {"ESTOP", "DETACH"} and self.manual_move_task is not None:
                if not self.manual_move_task.done():
                    task = self.manual_move_task
                    task.cancel()
                    with suppress(asyncio.CancelledError):
                        await task
            if command in {"ESTOP", "DETACH"}:
                await self._interrupt_pending_command()
            try:
                await self._send_command(
                    command,
                    lambda line: line == f"OK {command}",
                    f"{command}_REQUESTED",
                    {},
                    run_id,
                )
            except RobotError as exc:
                if run_id is not None and command in {"ESTOP", "DETACH"}:
                    await self._finish_run(
                        run_id, "failed", exc.detail, f"RUN_{command}_FAILED"
                    )
                raise
            if command == "ESTOP":
                self.robot["moving"] = False
                self.robot["estop"] = True
            elif command == "RESET":
                self.robot["estop"] = False
            elif command == "DETACH":
                self.initialized_joints.clear()
                self.robot.update(
                    attached_mask=0,
                    moving=False,
                    current_angles=[None] * 6,
                    target_angles=[None] * 6,
                )
            await self._add_event("F", f"{command}_FINISHED", {}, run_id=run_id)
            if run_id is not None and command in {"ESTOP", "DETACH"}:
                await self._finish_run(
                    run_id,
                    "emergency_stopped" if command == "ESTOP" else "detached",
                    None,
                    "RUN_EMERGENCY_STOPPED" if command == "ESTOP" else "RUN_DETACHED",
                )
            await self._broadcast_status()
            return {"ok": True, "command": command, "status": self.status()}
