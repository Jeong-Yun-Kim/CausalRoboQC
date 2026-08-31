import asyncio
import glob
import time
from collections.abc import Awaitable, Callable
from typing import Any

import serial

from .config import Settings


LineCallback = Callable[[str], Awaitable[None]]
StateCallback = Callable[[dict[str, Any]], Awaitable[None]]


class SerialLink:
    def __init__(
        self,
        settings: Settings,
        on_line: LineCallback,
        on_state: StateCallback,
    ):
        self.settings = settings
        self.on_line = on_line
        self.on_state = on_state
        self.device: serial.Serial | None = None
        self.port: str | None = None
        self.connected = False
        self.ready = False
        self.last_error: str | None = None
        self._task: asyncio.Task[None] | None = None
        self._closing = False
        self._write_lock = asyncio.Lock()
        self._buffer = bytearray()
        self._opened_at = 0.0
        self._last_ping_at = 0.0
        self._last_status_at = 0.0
        self._port_cursor = 0

    def snapshot(self) -> dict[str, Any]:
        return {
            "connected": self.connected,
            "ready": self.ready,
            "port": self.port,
            "baud_rate": self.settings.baud_rate,
            "last_error": self.last_error,
        }

    def _ports(self) -> list[str]:
        candidates: list[str] = []
        for item in (
            self.settings.serial_port,
            "/dev/ttyACM0",
            "/dev/ttyUSB0",
            *sorted(glob.glob("/dev/ttyACM*")),
            *sorted(glob.glob("/dev/ttyUSB*")),
        ):
            if item and item not in candidates:
                candidates.append(item)
        return candidates

    async def start(self) -> None:
        if self._task is None:
            self._closing = False
            self._task = asyncio.create_task(self._run(), name="arduino-serial")

    async def stop(self) -> None:
        self._closing = True
        if self._task is not None:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
            self._task = None
        await self._disconnect(None)

    async def send(self, command: str) -> None:
        if not self.ready or self.device is None:
            raise ConnectionError("Arduino is not ready")
        await self._write(command)

    async def _write(self, command: str) -> None:
        device = self.device
        if device is None:
            raise ConnectionError("Serial port is closed")
        data = (command + "\n").encode("ascii")
        async with self._write_lock:
            written = device.write(data)
            if written != len(data):
                raise serial.SerialTimeoutException("Incomplete serial write")

    async def _notify_state(self) -> None:
        await self.on_state(self.snapshot())

    async def _connect(self) -> bool:
        ports = self._ports()
        for offset in range(len(ports)):
            index = (self._port_cursor + offset) % len(ports)
            port_name = ports[index]
            if self._closing:
                return False
            try:
                device = serial.Serial(
                    port_name,
                    self.settings.baud_rate,
                    timeout=0,
                    write_timeout=1.0,
                    exclusive=True,
                )
            except (serial.SerialException, OSError) as exc:
                self.last_error = f"{port_name}: {exc}"
                continue
            self.device = device
            self.port = port_name
            self.connected = True
            self.ready = False
            self.last_error = None
            self._buffer.clear()
            self._opened_at = time.monotonic()
            self._last_ping_at = 0.0
            self._last_status_at = 0.0
            self._port_cursor = (index + 1) % len(ports)
            await self._notify_state()
            return True
        await self._notify_state()
        return False

    async def _disconnect(self, error: str | None) -> None:
        device = self.device
        changed = self.connected or self.ready or self.port is not None
        self.device = None
        self.connected = False
        self.ready = False
        self.port = None
        self._buffer.clear()
        if error:
            self.last_error = error
        if device is not None:
            try:
                device.close()
            except (serial.SerialException, OSError):
                pass
        if changed or error:
            await self._notify_state()

    async def _read_bytes(self) -> bytes:
        device = self.device
        if device is None:
            return b""

        waiting = device.in_waiting
        return device.read(waiting) if waiting > 0 else b""

    async def _consume(self, data: bytes) -> None:
        self._buffer.extend(data)
        while b"\n" in self._buffer:
            raw, _, rest = self._buffer.partition(b"\n")
            self._buffer = bytearray(rest)
            line = raw.rstrip(b"\r").decode("utf-8", errors="replace").strip()
            if not line:
                continue
            upper = line.upper()
            if upper.startswith("READY"):
                self.ready = False
                self._opened_at = time.monotonic()
                self._last_ping_at = 0.0
            await self.on_line(line)
            if upper.startswith("READY"):
                await self._notify_state()
            elif upper == "PONG" and not self.ready:
                self.last_error = None
                self._last_status_at = time.monotonic()
                await self._write("LIMITS")
                await self._write("STATUS")
                self.ready = True
                await self._notify_state()

    async def _run(self) -> None:
        while not self._closing:
            if self.device is None:
                connected = await self._connect()
                if not connected:
                    await asyncio.sleep(self.settings.reconnect_seconds)
                    continue
            try:
                data = await self._read_bytes()
                if data:
                    await self._consume(data)
                now = time.monotonic()
                if not self.ready:
                    if now - self._opened_at >= 1.8 and now - self._last_ping_at >= 1.0:
                        self._last_ping_at = now
                        await self._write("PING")
                    if now - self._opened_at >= 8.0:
                        raise TimeoutError("PONG handshake timed out")
                elif now - self._last_status_at >= self.settings.status_poll_seconds:
                    self._last_status_at = now
                    await self._write("STATUS")
                await asyncio.sleep(0.01)
            except asyncio.CancelledError:
                raise
            except (serial.SerialException, OSError, ConnectionError, TimeoutError) as exc:
                await self._disconnect(str(exc))
                if not self._closing:
                    await asyncio.sleep(self.settings.reconnect_seconds)
