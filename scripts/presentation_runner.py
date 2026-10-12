"""Local presentation supervisor. No installs, downloads, or killing other processes."""

import fcntl
import ipaddress
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "server" / "data" / "presentation-runtime"
MODEL = "qwen3:4b-instruct"
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def get_json(url):
    with OPENER.open(url, timeout=2) as response:
        return json.load(response)


def require_free_ports(host="127.0.0.1"):
    for port in (9000, 8000, 8080):
        with socket.socket() as probe:
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                probe.bind(("127.0.0.1" if port == 9000 else host, port))
            except OSError as exc:
                raise RuntimeError(f"Port {port} is already in use; stop its server before launching. No process was replaced.") from exc


class Supervisor:
    def __init__(self):
        self.children = []
        self.logs = []

    def start(self, name, command, env, cwd=ROOT):
        log = (RUNTIME / f"{name}.log").open("w")
        self.logs.append(log)
        child = subprocess.Popen(command, cwd=cwd, env=env, stdout=log,
                                 stderr=subprocess.STDOUT, start_new_session=True, close_fds=True)
        self.children.append((name, child))
        return child

    @staticmethod
    def wait_ready(child, url, seconds=180):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if child.poll() is not None:
                raise RuntimeError(f"Service exited before readiness: {url}. See {RUNTIME}.")
            try:
                with OPENER.open(url, timeout=2) as response:
                    if response.status == 200:
                        return
            except (OSError, urllib.error.URLError):
                pass
            time.sleep(0.25)
        raise RuntimeError(f"Service readiness timed out: {url}. See {RUNTIME}.")

    def close(self):
        # Signal only process groups created by this launcher, including build children.
        for _, child in reversed(self.children):
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
        for _, child in reversed(self.children):
            try:
                child.wait(timeout=8)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
        for log in self.logs:
            log.close()


def run():
    lan_ip = os.getenv("PRESENTATION_LAN_IP", "").strip()
    if lan_ip:
        lan_ip = str(ipaddress.IPv4Address(lan_ip))
    listen_host = "0.0.0.0" if lan_ip else "127.0.0.1"
    api_url = f"http://{lan_ip or '127.0.0.1'}:8000"
    web_url = f"http://{lan_ip or '127.0.0.1'}:8080"
    RUNTIME.mkdir(parents=True, exist_ok=True)
    with (RUNTIME / "launcher.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise RuntimeError("Presentation launcher is already running: http://127.0.0.1:8080") from exc
        require_free_ports(listen_host)
        if not shutil.which("flutter"):
            raise RuntimeError("Flutter is not on PATH")
        env = {**os.environ, "PRESENTATION_MODE": "true", "OLLAMA_MODEL": MODEL,
               "ANALYSIS_BASE_URL": "http://127.0.0.1:9000",
               "OLLAMA_BASE_URL": "http://127.0.0.1:11434"}
        if lan_ip:
            env["CORS_ORIGINS"] = ",".join(filter(None, [env.get("CORS_ORIGINS", ""), web_url]))
        manager = Supervisor()
        try:
            tags_url = env["OLLAMA_BASE_URL"] + "/api/tags"
            try:
                tags = get_json(tags_url)
            except (OSError, urllib.error.URLError):
                if not shutil.which("ollama"):
                    raise RuntimeError("Ollama is not installed") from None
                print("Starting Ollama...", flush=True)
                ollama = manager.start("ollama", ["ollama", "serve"],
                                       {**env, "OLLAMA_HOST": "127.0.0.1:11434"})
                manager.wait_ready(ollama, tags_url, seconds=30)
                tags = get_json(tags_url)
            if MODEL not in {item.get("name") for item in tags.get("models", [])}:
                raise RuntimeError(f"Required installed Ollama model is missing: {MODEL}. No model was downloaded.")
            print(f"Ollama model available: {MODEL}", flush=True)
            ai = manager.start("ai", [sys.executable, "-m", "uvicorn", "ai.app.main:app",
                                      "--host", "127.0.0.1", "--port", "9000"], env)
            manager.wait_ready(ai, "http://127.0.0.1:9000/health")
            print("Preparing 30 RPF records and IF/RF/AE scores...", flush=True)
            api = manager.start("api", [sys.executable, "-m", "uvicorn", "server.app.main:app",
                                        "--host", listen_host, "--port", "8000"], env)
            manager.wait_ready(api, "http://127.0.0.1:8000/health")
            records = get_json("http://127.0.0.1:8000/api/rpf?include_analysis=true")["items"]
            expected = {f"RPF-{i:03d}" for i in range(1, 31)}
            if len(records) != 30 or {r["product_id"] for r in records} != expected or not all(
                r.get("analysis_result") and all(r["analysis_result"].get(key) is not None for key in
                    ("anomaly_score", "inspection_risk_score", "timeseries_anomaly_score")) for r in records
            ):
                raise RuntimeError("Presentation dataset is not ready")
            print("Building Flutter Web...", flush=True)
            build = manager.start("flutter-build", ["flutter", "build", "web", "--no-web-resources-cdn",
                                  f"--dart-define=API_BASE_URL={api_url}"], env, ROOT / "app")
            if build.wait() != 0:
                raise RuntimeError(f"Flutter build failed; see {RUNTIME / 'flutter-build.log'}")
            web = manager.start("web", [sys.executable, "-m", "http.server", "8080", "--bind", listen_host,
                                        "--directory", str(ROOT / "app" / "build" / "web")], env)
            manager.wait_ready(web, "http://127.0.0.1:8080/")
            print(f"Ready: {web_url} | RPF 30 / analysis 30 | Ctrl+C to stop", flush=True)
            while True:
                for name, child in manager.children:
                    if name != "flutter-build" and child.poll() is not None:
                        raise RuntimeError(f"{name} exited; see {RUNTIME / (name + '.log')}")
                time.sleep(0.5)
        finally:
            manager.close()


if __name__ == "__main__":
    def stop(_signal, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, stop)
    try:
        run()
    except KeyboardInterrupt:
        print("Presentation services stopped.")
    except Exception as exc:
        print(f"Presentation startup failed: {exc}", file=sys.stderr)
        sys.exit(1)
