import os
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


def load_settings() -> Settings:
    server_dir = Path(__file__).resolve().parents[1]
    repo_dir = server_dir.parent
    return Settings(
        serial_port=os.getenv("SERIAL_PORT", "/dev/ttyACM0"),
        baud_rate=int(os.getenv("SERIAL_BAUD_RATE", "115200")),
        reconnect_seconds=_float_env("SERIAL_RECONNECT_SECONDS", 2.0),
        status_poll_seconds=_float_env("SERIAL_STATUS_POLL_SECONDS", 0.5),
        move_timeout_seconds=_float_env("MOVE_TIMEOUT_SECONDS", 20.0),
        pose_pause_seconds=_float_env("POSE_PAUSE_SECONDS", 0.35),
        repeat_unlock_samples=_positive_int_env("REPEAT_UNLOCK_SAMPLES", 5),
        database_path=Path(
            os.getenv("DATABASE_PATH", str(server_dir / "data" / "robot_arm.db"))
        ).expanduser(),
        poses_path=Path(
            os.getenv("POSES_PATH", str(repo_dir / "robot_arm" / "poses.json"))
        ).expanduser(),
        rpf_rules_path=Path(
            os.getenv("RPF_RULES_PATH", str(server_dir / "config" / "rpf_rules.json"))
        ).expanduser(),
    )
