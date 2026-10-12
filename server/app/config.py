import os
import math
from dataclasses import dataclass
from pathlib import Path


def _float_env(name: str, default: float) -> float:
    try:
        return float(os.getenv(name, str(default)))
    except ValueError:
        return default


def _positive_int_env(name: str, default: int) -> int:
    try:
        value = int(os.getenv(name, str(default)))
    except ValueError:
        return default
    return value if value >= 1 else default


@dataclass(frozen=True)
class Settings:
    serial_port: str
    baud_rate: int
    reconnect_seconds: float
    status_poll_seconds: float
    move_timeout_seconds: float
    pose_pause_seconds: float
    repeat_unlock_samples: int
    database_path: Path
    poses_path: Path
    rpf_rules_path: Path
    analysis_base_url: str = "http://127.0.0.1:9000"
    analysis_timeout_seconds: float = 3.0
    presentation_mode: bool = False
    vision_enabled: bool = False
    vision_required: bool = False
    camera_device: str = "/dev/video0"
    vision_config_path: Path = Path(__file__).resolve().parents[1] / "config" / "vision.json"
    camera_preview_mode: str = "browser"


def load_settings() -> Settings:
    server_dir = Path(__file__).resolve().parents[1]
    repo_dir = server_dir.parent
    analysis_timeout = _float_env("ANALYSIS_TIMEOUT_SECONDS", 3.0)
    presentation_mode = os.getenv("PRESENTATION_MODE", "false").lower() in {"true", "1", "yes"}
    user_database = Path(os.getenv("DATABASE_PATH", str(server_dir / "data" / "robot_arm.db"))).expanduser()
    database = (Path(os.getenv("PRESENTATION_DATABASE_PATH", str(server_dir / "data" / "presentation.db"))).expanduser()
                if presentation_mode else user_database)
    if presentation_mode and database.resolve() in {user_database.resolve(), (server_dir / "data" / "robot_arm.db").resolve()}:
        raise ValueError("Presentation database must be separate from the user database")
    return Settings(
        serial_port=os.getenv("SERIAL_DEVICE", os.getenv("SERIAL_PORT", "/dev/ttyACM0")),
        baud_rate=int(os.getenv("SERIAL_BAUD_RATE", "115200")),
        reconnect_seconds=_float_env("SERIAL_RECONNECT_SECONDS", 2.0),
        status_poll_seconds=_float_env("SERIAL_STATUS_POLL_SECONDS", 0.5),
        move_timeout_seconds=_float_env("MOVE_TIMEOUT_SECONDS", 20.0),
        pose_pause_seconds=_float_env("POSE_PAUSE_SECONDS", 0.35),
        repeat_unlock_samples=_positive_int_env("REPEAT_UNLOCK_SAMPLES", 5),
        database_path=database,
        poses_path=Path(
            os.getenv("POSES_PATH", str(repo_dir / "robot_arm" / "poses.json"))
        ).expanduser(),
        rpf_rules_path=Path(
            os.getenv("RPF_RULES_PATH", str(server_dir / "config" / "rpf_rules.json"))
        ).expanduser(),
        analysis_base_url=os.getenv("ANALYSIS_BASE_URL", "http://127.0.0.1:9000"),
        analysis_timeout_seconds=(
            analysis_timeout if math.isfinite(analysis_timeout) and analysis_timeout > 0 else 3.0
        ),
        presentation_mode=presentation_mode,
        vision_enabled=os.getenv("VISION_ENABLED", "false").lower() in {"true", "1", "yes"},
        vision_required=os.getenv("VISION_REQUIRED", "false").lower() in {"true", "1", "yes"},
        camera_device=os.getenv("CAMERA_DEVICE", "/dev/video0"),
        vision_config_path=Path(os.getenv("VISION_CONFIG_PATH", str(server_dir / "config" / "vision.json"))),
        camera_preview_mode=(os.getenv("CAMERA_PREVIEW_MODE", "browser")
                             if os.getenv("CAMERA_PREVIEW_MODE", "browser") in {"browser", "server", "off"} else "off"),
    )
