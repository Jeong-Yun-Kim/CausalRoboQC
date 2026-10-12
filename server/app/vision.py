"""In-memory camera ownership and normalized ArUco verification; no recordings."""
import asyncio
from contextlib import suppress
from dataclasses import dataclass
import json
import math
from pathlib import Path
import threading
from time import monotonic
from typing import Callable


@dataclass(frozen=True)
class VisionConfig:
    dictionary: str = "DICT_4X4_50"
    input_roi: tuple = (0.05, 0.15, 0.4, 0.7)
    output_roi: tuple = (0.55, 0.15, 0.4, 0.7)
    stable_frames: int = 3
    place_timeout_seconds: float = 10.0

    @classmethod
    def load(cls, path: Path):
        data = json.loads(path.read_text(encoding="utf-8"))
        config = cls(**data)
        for roi in (config.input_roi, config.output_roi):
            if (len(roi) != 4 or any(isinstance(v, bool) or not isinstance(v, (int, float))
                                   or not math.isfinite(v) for v in roi)
                    or min(roi[:2]) < 0 or min(roi[2:]) <= 0
                    or roi[0] + roi[2] > 1 or roi[1] + roi[3] > 1):
                raise ValueError("ROI must be normalized [x, y, width, height]")
        a, b = config.input_roi, config.output_roi
        if max(a[0], b[0]) < min(a[0]+a[2], b[0]+b[2]) and max(a[1], b[1]) < min(a[1]+a[3], b[1]+b[3]):
            raise ValueError("Input and output ROIs must not overlap")
        if (type(config.stable_frames) is not int or config.stable_frames < 1
                or isinstance(config.place_timeout_seconds, bool)
                or not math.isfinite(config.place_timeout_seconds) or config.place_timeout_seconds <= 0):
            raise ValueError("Invalid stability/timeout settings")
        if config.dictionary != "DICT_4X4_50":
            raise ValueError("Only DICT_4X4_50 is supported")
        return config


class ArucoDetector:
    def __init__(self, config: VisionConfig):
        import cv2
        self.cv2 = cv2
        self.config = config
        dictionary = cv2.aruco.getPredefinedDictionary(getattr(cv2.aruco, config.dictionary))
        self.detector = cv2.aruco.ArucoDetector(dictionary, cv2.aruco.DetectorParameters())

    @staticmethod
    def inside(center, roi):
        x, y, w, h = roi
        return x <= center[0] <= x+w and y <= center[1] <= y+h

    def detect(self, frame):
        corners, ids, _ = self.detector.detectMarkers(frame)
        height, width = frame.shape[:2]
        markers = []
        for corner, marker_id in zip(corners, [] if ids is None else ids.flatten()):
            points = corner.reshape(4, 2)
            center = points.mean(axis=0) / (width, height)
            markers.append({"marker_id": int(marker_id), "corners": points,
                            "input": self.inside(center, self.config.input_roi),
                            "output": self.inside(center, self.config.output_roi)})
        return markers

    def jpeg(self, frame, markers, active_marker_id):
        cv2 = self.cv2
        overlay = frame.copy()
        height, width = frame.shape[:2]
        for label, roi in (("INPUT", self.config.input_roi), ("OUTPUT", self.config.output_roi)):
            x, y, w, h = roi
            left, top = int(x*width), int(y*height)
            cv2.rectangle(overlay, (left, top), (int((x+w)*width), int((y+h)*height)), (0, 180, 0), 2)
            cv2.putText(overlay, label, (left, top+20), cv2.FONT_HERSHEY_SIMPLEX, .5, (0, 180, 0), 1)
        for marker in markers:
            point = tuple(int(v) for v in marker["corners"][0])
            cv2.putText(overlay, str(marker["marker_id"]), point, cv2.FONT_HERSHEY_SIMPLEX, .6, (0, 0, 220), 2)
        cv2.putText(overlay, f"Active: {active_marker_id if active_marker_id is not None else '-'}",
                    (12, 25), cv2.FONT_HERSHEY_SIMPLEX, .6, (200, 80, 0), 2)
        ok, encoded = cv2.imencode(".jpg", overlay)
        return encoded.tobytes() if ok else None


class VisionState:
    """All transitions run on the API event loop. Times are monotonic seconds."""
    def __init__(self, config: VisionConfig):
        self.config = config
        self.active_marker_id = None
        self.cycle_marker_id = None
        self.candidate = None
        self.input_ids = set()
        self.count = 0
        self.lifted = False
        self.lift_at = None
        self.picked = False
        self.release_at = None
        self.output_count = 0
        self.outcome = None

    def begin_cycle(self):
        if (self.active_marker_id is None or self.cycle_marker_id is not None
                or self.active_marker_id not in self.input_ids):
            raise ValueError("No available locked marker")
        self.cycle_marker_id = self.active_marker_id
        self.lifted = self.picked = False
        self.lift_at = None
        self.release_at = self.outcome = None
        self.output_count = 0
        return self.cycle_marker_id

    def pose_finished(self, name, now):
        if self.cycle_marker_id is None or self.outcome:
            return
        if name == "LIFT":
            self.lifted = True
            self.lift_at = now
        elif name == "RELEASE":
            self.release_at = now
            self.output_count = 0

    def end_cycle(self):
        self.active_marker_id = self.cycle_marker_id = self.candidate = None
        self.count = self.output_count = 0
        self.release_at = None
        self.lifted = self.picked = False
        self.lift_at = None
        self.outcome = None

    def tick(self, now):
        if (self.release_at is not None and not self.outcome
                and now - self.release_at >= self.config.place_timeout_seconds):
            self.outcome = "PLACE_TIMEOUT"
            return [self.outcome]
        return []

    def observe(self, markers, now):
        events = self.tick(now)
        inputs = {m["marker_id"] for m in markers if m["input"]}
        self.input_ids = inputs
        outputs = {m["marker_id"] for m in markers if m["output"]}
        if self.cycle_marker_id is None:
            if self.active_marker_id is None:
                candidate = next(iter(inputs)) if len(inputs) == 1 else None
                self.count = self.count + 1 if candidate is not None and candidate == self.candidate else 1
                self.candidate = candidate
                if candidate is not None and self.count >= self.config.stable_frames:
                    self.active_marker_id = candidate
                    events.append("PRODUCT_LOCKED")
            return events
        if self.outcome:
            return events
        if self.lifted and now >= self.lift_at and not self.picked and self.cycle_marker_id not in inputs:
            self.picked = True
            events.append("PICK_VERIFIED")
        if self.release_at is not None and now >= self.release_at:
            if outputs - {self.cycle_marker_id}:
                self.outcome = "PRODUCT_ID_MISMATCH"
                events.append(self.outcome)
            else:
                self.output_count = self.output_count + 1 if self.cycle_marker_id in outputs else 0
                if self.picked and self.output_count >= self.config.stable_frames:
                    self.outcome = "PLACE_VERIFIED"
                    events.append(self.outcome)
        return events


class OpenCVSource:
    """Only instantiated by an explicitly enabled background camera worker."""
    def __init__(self, device):
        import cv2
        self.capture = cv2.VideoCapture(device)
        if not self.capture.isOpened():
            self.capture.release()
            raise OSError("Camera could not be opened")

    def read(self):
        ok, frame = self.capture.read()
        if not ok:
            raise OSError("Camera frame unavailable")
        return frame

    def close(self):
        self.capture.release()


class VisionService:
    def __init__(self, settings, on_event, *, source_factory: Callable = OpenCVSource):
        self.settings, self.on_event, self.source_factory = settings, on_event, source_factory
        self.state = self.detector = None
        self.error = None
        self.latest_jpeg = None
        self.last_frame_at = None
        self.task = None
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self._latest = None
        self._worker = None
        self._connected = False
        try:
            config = VisionConfig.load(settings.vision_config_path)
            self.state = VisionState(config)
        except Exception as exc:
            self.error = str(exc)

    @property
    def camera_connected(self):
        return self._connected and self.last_frame_at is not None and monotonic()-self.last_frame_at < 2

    @property
    def ready(self):
        return self.settings.vision_enabled and self.camera_connected and self.detector is not None and self.error is None

    def status(self):
        return {"camera_connected": self.camera_connected, "vision_ready": self.ready,
                "active_marker_id": self.state.active_marker_id if self.state else None,
                "camera_preview_mode": self.settings.camera_preview_mode, "camera_error": self.error}

    def _capture(self):
        while not self._stop.is_set():
            source = None
            try:
                source = self.source_factory(self.settings.camera_device)
                while not self._stop.is_set():
                    frame = source.read()
                    with self._lock:
                        self._latest = (frame, monotonic())
                    self._connected = True
                    self._stop.wait(.03)
            except Exception as exc:
                self._connected = False
                self.error = str(exc)
            finally:
                if source is not None:
                    with suppress(Exception):
                        source.close()
            self._stop.wait(1)

    async def start(self):
        if not self.state or (not self.settings.vision_enabled and self.settings.camera_preview_mode != "server"):
            return
        if self.settings.camera_preview_mode == "browser":
            self.error = "VISION_ENABLED requires CAMERA_PREVIEW_MODE=server or off"
            return
        try:
            self.detector = ArucoDetector(self.state.config)
        except Exception as exc:
            self.error = str(exc)
            return
        self._worker = threading.Thread(target=self._capture, name="usb-camera", daemon=True)
        self._worker.start()
        self.task = asyncio.create_task(self._process(), name="vision-frames")

    async def process_frame(self, frame, now=None):
        now = monotonic() if now is None else now
        markers = self.detector.detect(frame)
        if self.last_frame_at is not None and now - self.last_frame_at > 1:
            # A disconnected source cannot contribute consecutive observations.
            self.state.count = self.state.output_count = 0
            self.state.candidate = None
        self.last_frame_at = now
        self.error = None
        events = self.state.observe(markers, now) if self.settings.vision_enabled else []
        self.latest_jpeg = self.detector.jpeg(frame, markers, self.state.active_marker_id)
        for event in events:
            await self.on_event(event, {"marker_id": self.state.active_marker_id,
                                       "observed_ids": sorted({m["marker_id"] for m in markers}),
                                       "source": "aruco"})

    async def _process(self):
        while True:
            with self._lock:
                latest, self._latest = self._latest, None
            try:
                if latest:
                    await self.process_frame(*latest)
                # Timeouts continue even when the camera disconnects.
                for event in self.state.tick(monotonic()):
                    await self.on_event(event, {"marker_id": self.state.cycle_marker_id, "source": "aruco"})
            except Exception as exc:
                self.error = str(exc)
            await asyncio.sleep(.03)

    async def stop(self):
        self._stop.set()
        if self.task:
            self.task.cancel()
            with suppress(asyncio.CancelledError):
                await self.task
        if self._worker:
            # A blocked driver must never block API shutdown indefinitely.
            await asyncio.to_thread(self._worker.join, 1)
        self._connected = False
        self.latest_jpeg = None
