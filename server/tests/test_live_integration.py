"""All cameras, serial links and remote services are fixtures. No device opens."""
import asyncio
from dataclasses import replace
import csv
import io
import json
import os
from pathlib import Path
import sqlite3
import tempfile
from time import monotonic
import unittest
from unittest.mock import AsyncMock, Mock, patch

import cv2
import httpx
import numpy as np
from fastapi.testclient import TestClient

from server.app.config import load_settings
from server.app.database import Database
from server.app.main import app, camera_stream
from server.app.analysis_client import AnalysisClient
from server.app.analysis_service import RpfAnalysisService
from server.app.service import RobotService, RobotError, WebSocketHub
from server.app.vision import ArucoDetector, VisionConfig, VisionState, VisionService


def frame(marker_id=None, output=False):
    image = np.full((400, 800, 3), 255, dtype=np.uint8)
    if marker_id is not None:
        marker = cv2.aruco.generateImageMarker(cv2.aruco.getPredefinedDictionary(cv2.aruco.DICT_4X4_50), marker_id, 100)
        x = 540 if output else 140
        image[140:240, x:x+100] = cv2.cvtColor(marker, cv2.COLOR_GRAY2BGR)
    return image


class VisionTest(unittest.TestCase):
    def setUp(self):
        self.config = VisionConfig()
        self.detector = ArucoDetector(self.config)
        self.state = VisionState(self.config)

    def observe(self, marker_id=None, output=False, now=0):
        return self.state.observe(self.detector.detect(frame(marker_id, output)), now)

    def lock(self):
        self.observe(7)
        self.observe(7)
        self.assertEqual(self.observe(7), ['PRODUCT_LOCKED'])
        self.assertEqual(self.state.begin_cycle(), 7)

    def test_synthetic_detection_normalized_rois_and_consecutive_stability(self):
        markers = self.detector.detect(frame(7))
        self.assertEqual(markers[0]['marker_id'], 7)
        self.assertTrue(markers[0]['input'])
        self.assertFalse(markers[0]['output'])
        self.observe(7)
        self.observe(8)
        self.observe()
        self.assertIsNone(self.state.active_marker_id)
        self.lock()
        self.observe()
        self.observe(9)
        self.assertEqual(self.state.active_marker_id, 7)
        self.assertFalse(self.state.picked)

    def test_pick_and_same_output_stability(self):
        self.lock()
        self.state.pose_finished('LIFT', 1)
        self.assertEqual(self.observe(now=1), ['PICK_VERIFIED'])
        self.state.pose_finished('RELEASE', 2)
        self.assertEqual(self.observe(7, True, 3), [])
        self.assertEqual(self.observe(7, True, 4), [])
        self.assertEqual(self.observe(7, True, 5), ['PLACE_VERIFIED'])
        self.assertEqual(self.observe(8, True, 6), [])
        self.assertEqual(self.state.tick(99), [])

    def test_mismatch_and_timeout(self):
        self.lock()
        self.state.pose_finished('RELEASE', 1)
        self.assertEqual(self.observe(8, True, 2), ['PRODUCT_ID_MISMATCH'])
        self.state.end_cycle()
        self.lock()
        self.state.pose_finished('RELEASE', 1)
        self.assertEqual(self.state.tick(11), ['PLACE_TIMEOUT'])
        self.assertEqual(self.observe(7, True, 12), [])

    def test_output_before_release_and_without_pick_cannot_complete(self):
        self.lock()
        for _ in range(5):
            self.observe(7, True, 1)
        self.assertIsNone(self.state.outcome)
        self.state.pose_finished('RELEASE', 2)
        for _ in range(5):
            self.observe(7, True, 3)
        self.assertIsNone(self.state.outcome)
        self.assertEqual(self.state.tick(12), ['PLACE_TIMEOUT'])

    def test_stale_frames_do_not_verify_new_pose_and_missing_input_cannot_start(self):
        self.lock()
        self.state.pose_finished('LIFT', 10)
        self.assertEqual(self.observe(now=9), [])
        self.assertFalse(self.state.picked)
        self.state.pose_finished('RELEASE', 20)
        self.assertEqual(self.observe(8, True, 19), ['PICK_VERIFIED'])
        self.assertIsNone(self.state.outcome)
        self.state.end_cycle()
        for _ in range(3):
            self.observe(7)
        self.observe(8)
        with self.assertRaises(ValueError):
            self.state.begin_cycle()

    def test_invalid_config(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'vision.json'
            for value in ({'input_roi': [0, 0, 2, 1]}, {'stable_frames': 0},
                          {'place_timeout_seconds': -1}, {'dictionary': 'NOPE'},
                          {'input_roi': [0, 0, 1, 1]}):
                path.write_text(json.dumps(value))
                with self.assertRaises(ValueError):
                    VisionConfig.load(path)


class IntegrationTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / 'robot.db'
        self.settings = replace(load_settings(), database_path=self.path,
                                poses_path=Path('server/config/poses.json'),
                                vision_enabled=True, vision_required=True, camera_preview_mode='server',
                                pose_pause_seconds=0)
        self.db = Database(self.path)
        self.analysis_client = AnalysisClient('http://fixture', transport=httpx.MockTransport(
            lambda req: httpx.Response(200, json={'rpf_id': json.loads(req.content)['rpf_id'],
                 'anomaly_score': .2, 'inspection_risk_score': .3, 'timeseries_anomaly_score': None,
                 'synthetic_model': True, 'model_info': {'fixture': True}})))
        self.analysis = RpfAnalysisService(self.db, self.analysis_client)
        self.service = RobotService(self.settings, self.db, WebSocketHub(), self.analysis)
        self.service.serial.ready = True
        self.service.serial.connected = True
        self.service.vision.detector = ArucoDetector(VisionConfig())
        self.service.vision._connected = True
        self.service._send_command = AsyncMock()
        self.service._broadcast_status = AsyncMock()
        self.api_state = getattr(app.state, 'service', None)
        app.state.service = self.service
        self.api = httpx.AsyncClient(transport=httpx.ASGITransport(app), base_url='http://fixture')

    async def asyncTearDown(self):
        if self.service.run_task and not self.service.run_task.done():
            self.service.run_task.cancel()
            await asyncio.gather(self.service.run_task, return_exceptions=True)
        await self.service.vision.stop()
        await self.analysis.shutdown()
        await self.analysis_client.close()
        await self.api.aclose()
        self.db.close()
        self.temp.cleanup()
        app.state.service = self.api_state

    async def lock(self):
        for _ in range(3):
            await self.service.vision.process_frame(frame(7))

    async def run_cycle(self, output_id=7, timeout=False):
        async def move(name, angles, run_id, step_index=None, cycle=None):
            await self.service._add_event('F', 'POSE_FINISHED', {'pose': name}, run_id=run_id)
            if name == 'LIFT':
                # The fake source supplies a frame after the service consumes the pose acknowledgement.
                asyncio.get_running_loop().call_soon(lambda: asyncio.create_task(self.service.vision.process_frame(frame())))
            if name == 'RELEASE':
                async def released():
                    await asyncio.sleep(0)
                    if timeout:
                        state = self.service.vision.state
                        for event in state.tick(state.release_at + state.config.place_timeout_seconds):
                            await self.service._vision_event(event, {'marker_id': 7})
                    else:
                        for _ in range(3):
                            await self.service.vision.process_frame(frame(output_id, True))
                asyncio.create_task(released())
        self.service._move_pose = move
        await self.lock()
        result = await self.api.post('/api/runs/start', json={})
        self.assertEqual(result.status_code, 200, result.text)
        task = self.service.run_task
        await asyncio.wait_for(task, 2)
        await asyncio.gather(*self.analysis._tasks.values())
        return self.db.get_run(result.json()['run']['id'])

    async def test_normal_rpf_bound_to_marker_verified_and_analyzed(self):
        run = await self.run_cycle()
        record = self.db.list_rpfs(10, 0)[0]
        self.assertEqual(run['status'], 'completed')
        self.assertEqual(record['marker_id'], 7)
        self.assertEqual(record['status'], 'completed')
        names = [e['name'] for e in self.db.list_rpf_events(record['id'])]
        self.assertIn('PICK_VERIFIED', names)
        self.assertIn('PLACE_VERIFIED', names)
        self.assertIsNotNone(self.db.get_analysis_result(record['id']))
        first_product_id = record['product_id']
        await self.run_cycle()
        self.assertNotEqual(self.db.list_rpfs(1, 0)[0]['product_id'], first_product_id)

    async def test_mismatch_finishes_failed_without_analysis(self):
        self.assertEqual((await self.run_cycle(8))['status'], 'failed')
        record = self.db.list_rpfs(1, 0)[0]
        self.assertEqual(record['grade'], 'priority')
        self.assertIn('제품 ID 불일치', record['grade_reasons'])
        self.assertIsNone(self.db.get_analysis_result(record['id']))

    async def test_timeout_finishes_failed_without_analysis(self):
        self.assertEqual((await self.run_cycle(timeout=True))['status'], 'failed')
        record = self.db.list_rpfs(1, 0)[0]
        self.assertEqual(record['status'], 'failed')
        self.assertIn('PLACE_TIMEOUT', [e['name'] for e in self.db.list_rpf_events(record['id'])])

    async def test_camera_missing_blocks_only_run_and_health_survives(self):
        response = await self.api.post('/api/runs/start', json={})
        self.assertEqual(response.status_code, 409)
        health = await self.api.get('/health')
        self.assertEqual(health.status_code, 200)
        self.assertFalse(health.json()['vision_ready'])
        self.assertFalse(health.json()['analysis_server_available'])
        self.assertEqual(self.db.list_runs(10, 0), [])
        self.assertEqual((await self.api.get('/api/camera/snapshot')).status_code, 503)

    async def test_snapshot_and_mjpeg_from_mock_frames(self):
        await self.lock()
        snapshot = await self.api.get('/api/camera/snapshot')
        self.assertEqual(snapshot.status_code, 200)
        self.assertEqual(snapshot.headers['cache-control'], 'no-store')
        self.assertTrue(snapshot.content.startswith(b'\xff\xd8'))
        request = Mock(app=app)
        request.is_disconnected = AsyncMock(side_effect=[False, True])
        response = await camera_stream(request)
        chunks = [chunk async for chunk in response.body_iterator]
        self.assertEqual(len(chunks), 1)
        self.assertIn(b'Content-Type: image/jpeg', chunks[0])

    async def test_inspection_api_update_csv_and_grade_preservation(self):
        await self.run_cycle()
        record = self.db.list_rpfs(1, 0)[0]
        payload = {'result': 'FAIL', 'confirmed_causes': ['표면 손상'], 'action': '재검사', 'note': '=1+1'}
        path = f"/api/rpf/{record['id']}/inspection"
        response = await self.api.put(path, json=payload)
        self.assertEqual(response.status_code, 200)
        self.assertIsNotNone(response.json()['inspected_at'])
        csv_response = await self.api.get('/api/data/rpf.csv')
        row = list(csv.DictReader(io.StringIO(csv_response.text.lstrip('\ufeff'))))[0]
        self.assertEqual(row['inspection_result'], 'FAIL')
        self.assertEqual(row['note'], "'=1+1")
        self.assertEqual(json.loads(row['confirmed_causes']), ['표면 손상'])
        self.assertEqual((await self.api.put(path, json={**payload, 'result': 'PASS'})).status_code, 200)
        self.assertEqual(self.db.get_rpf(record['id'])['grade'], record['grade'])
        self.assertEqual(self.db.get_rpf(record['id'])['inspection']['result'], 'PASS')
        self.assertEqual((await self.api.get('/api/data/rpf')).json()['items'][0]['inspection_result'], 'PASS')
        self.assertEqual((await self.api.put(path, json={'result': 'BAD'})).status_code, 422)
        self.assertEqual((await self.api.put('/api/rpf/999/inspection', json=payload)).status_code, 404)
        reopened = Database(self.path)
        self.assertEqual(reopened.get_inspection(record['id'])['result'], 'PASS')
        reopened.close()

    async def test_mock_source_worker_and_camera_failure_recovery(self):
        source = Mock()
        source.read.return_value = frame(7)
        factory = Mock(return_value=source)
        vision = VisionService(self.settings, AsyncMock(), source_factory=factory)
        await vision.start()
        try:
            for _ in range(100):
                if vision.ready and vision.state.active_marker_id == 7:
                    break
                await asyncio.sleep(.01)
            self.assertTrue(vision.ready)
            self.assertEqual(vision.state.active_marker_id, 7)
        finally:
            await vision.stop()
        source.close.assert_called_once()
        with patch('cv2.VideoCapture', side_effect=AssertionError('forbidden')) as capture:
            browser = VisionService(replace(self.settings, camera_preview_mode='browser'), AsyncMock())
            await browser.start()
            self.assertIn('requires', browser.error)
            capture.assert_not_called()

    async def test_presentation_with_live_vision_preserves_thirty_rpfs(self):
        from scripts.seed_demo_rpf import seed_demo
        seed_demo(self.path, Path('server/config/rpf_rules.json'))
        self.service.settings = replace(self.settings, presentation_mode=True)
        before = self.db.list_rpfs(100, 0)
        self.assertEqual((await self.run_cycle())['status'], 'completed')
        self.assertEqual(self.db.list_rpfs(100, 0), before)
        self.assertEqual(len(before), 30)
        self.assertIn('PLACE_VERIFIED', [e['name'] for e in self.db.list_events(None, 2000)])

    async def test_optional_unavailable_camera_runs_without_inventing_rpf(self):
        self.service.settings = replace(self.settings, vision_required=False)
        self.service._move_pose = AsyncMock()
        response = await self.api.post('/api/runs/start', json={})
        self.assertEqual(response.status_code, 200)
        await self.service.run_task
        self.assertEqual(self.db.list_rpfs(100, 0), [])
        self.assertEqual(self.db.get_run(response.json()['run']['id'])['status'], 'completed')

    async def test_source_failure_keeps_vision_service_alive(self):
        vision = VisionService(self.settings, AsyncMock(), source_factory=Mock(side_effect=OSError('missing camera')))
        await vision.start()
        try:
            await asyncio.sleep(.05)
            self.assertFalse(vision.ready)
            self.assertFalse(vision.task.done())
            self.assertEqual(vision.error, 'missing camera')
        finally:
            await vision.stop()

    async def test_offline_analysis_keeps_completed_rpf(self):
        with patch.object(self.analysis_client, 'analyze', side_effect=RuntimeError('offline')):
            self.assertEqual((await self.run_cycle())['status'], 'completed')
        self.assertEqual(self.db.list_rpfs(1, 0)[0]['status'], 'completed')


class MigrationTest(unittest.TestCase):
    def test_existing_database_is_migrated_without_deleting_records(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'old.db'
            db = Database(path)
            run = db.create_run(False)
            record = db.create_rpf(run['id'], 0, 'LEGACY')
            db.close()
            with sqlite3.connect(path) as conn:
                conn.execute('DROP TABLE inspections')
                conn.execute('ALTER TABLE rpf_records DROP COLUMN marker_id')
            db = Database(path)
            self.assertEqual(db.get_rpf(record['id'])['product_id'], 'LEGACY')
            self.assertIsNone(db.get_rpf(record['id'])['marker_id'])
            self.assertIsNone(db.get_rpf(record['id'])['inspection'])
            db.close()


class StartupTest(unittest.TestCase):
    def test_presentation_starts_with_offline_ai_and_camera_status_fixture(self):
        with tempfile.TemporaryDirectory() as temp:
            client = AnalysisClient('http://fixture', transport=httpx.MockTransport(lambda request: httpx.Response(503)))
            with patch.dict(os.environ, {
                'PRESENTATION_MODE': 'true', 'PRESENTATION_DATABASE_PATH': str(Path(temp) / 'presentation.db'),
                'DATABASE_PATH': str(Path(temp) / 'user.db'), 'VISION_ENABLED': 'true',
                'VISION_REQUIRED': 'true', 'CAMERA_PREVIEW_MODE': 'server',
            }), patch('server.app.main.AnalysisClient', return_value=client), patch(
                    'server.app.serial_link.SerialLink.start', new_callable=AsyncMock), patch(
                    'server.app.vision.VisionService.start', new_callable=AsyncMock):
                with TestClient(app) as api:
                    health = api.get('/health')
                    self.assertEqual(health.status_code, 200)
                    self.assertFalse(health.json()['camera_connected'])
                    self.assertFalse(health.json()['analysis_server_available'])
                    self.assertEqual(len(api.get('/api/rpf').json()['items']), 30)
