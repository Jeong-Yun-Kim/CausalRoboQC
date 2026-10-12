"""Standalone Playwright fixture. Temp DB + synthetic frames; no hardware startup.

Run only after building app/build/web with API_BASE_URL=/ and --no-web-resources-cdn.
"""
import asyncio
from contextlib import asynccontextmanager, ExitStack
from dataclasses import replace
from pathlib import Path
import tempfile
from unittest.mock import patch

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
import httpx
import uvicorn

from scripts.seed_demo_rpf import seed_demo
from server.app.analysis_client import AnalysisClient
from server.app.analysis_service import RpfAnalysisService
from server.app.config import load_settings
from server.app.database import Database
from server.app.main import app as api
from server.app.service import RobotService, WebSocketHub
from server.app.vision import VisionService
from server.tests.test_live_integration import frame


class FrameFixture:
    offline = False
    def read(self):
        if self.offline:
            raise OSError('Fixture camera offline')
        return frame(7)
    def close(self):
        pass


def forbidden(*args, **kwargs):
    raise AssertionError('Real hardware/network is prohibited in this fixture')


@asynccontextmanager
async def lifespan(app):
    with tempfile.TemporaryDirectory(prefix='live-browser-') as temp, ExitStack() as stack:
        for target in ('serial.Serial', 'cv2.VideoCapture', 'httpx.AsyncHTTPTransport.handle_async_request'):
            stack.enter_context(patch(target, side_effect=forbidden))
        path = Path(temp) / 'fixture.db'
        seed_demo(path, Path('server/config/rpf_rules.json'))
        database = Database(path)
        settings = replace(load_settings(), database_path=path, presentation_mode=True,
                           vision_enabled=True, vision_required=True, camera_preview_mode='server',
                           poses_path=Path('server/config/poses.json'))
        client = AnalysisClient('http://fixture', transport=httpx.MockTransport(lambda request: httpx.Response(503)))
        analysis = RpfAnalysisService(database, client)
        service = RobotService(settings, database, WebSocketHub(), analysis)
        source = FrameFixture()
        service.vision = VisionService(settings, service._vision_event, source_factory=lambda device: source)
        app.state.service = service
        app.state.analysis_client = client
        app.state.source = source
        await service.vision.start()
        try:
            yield
        finally:
            await service.vision.stop()
            await analysis.shutdown()
            await client.close()
            database.close()


app = FastAPI(lifespan=lifespan)
app.router.routes.extend(route for route in api.routes if getattr(route, 'path', '/') != '/')


@app.post('/__fixture__/camera/{mode}')
async def camera_mode(mode: str):
    app.state.source.offline = mode == 'offline'
    if app.state.source.offline:
        app.state.service.vision._connected = False
    return {'offline': app.state.source.offline}


app.mount('/', StaticFiles(directory='app/build/web', html=True), name='web')

if __name__ == '__main__':
    uvicorn.run(app, host='127.0.0.1', port=18081, log_level='warning')
