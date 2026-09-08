import asyncio
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

import httpx

from server.app.analysis_client import AnalysisClient
from server.app.database import Database
from server.app.main import app
from server.app.service import ERROR_RUN_SEQUENCE, RUN_SEQUENCE
from server.tests.analysis_fixtures import create_rpf


class AutomaticAnalysisTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.db_path = Path(self.temp.name) / 'robot.db'
        seed_db = Database(self.db_path)
        self.seed = create_rpf(seed_db, product_id='EXISTING-DEMO')
        seed_db.close()
        self.release = asyncio.Event()
        self.started = asyncio.Event()
        self.requests = []
        self.failure = None
        self.invalid = False

        async def respond(request):
            payload = json.loads(request.content)
            self.requests.append(payload)
            self.started.set()
            await self.release.wait()
            if self.failure:
                raise self.failure
            return httpx.Response(200, json={
                'rpf_id': payload['rpf_id'],
                'anomaly_score': 1.5 if self.invalid else 0.3,
                'inspection_risk_score': 0.4,
                'timeseries_anomaly_score': 0.5 if payload['sequence'] else None,
                'synthetic_model': True, 'model_info': {'fixture': True},
            })

        self.analysis_client = AnalysisClient(
            'http://test-laptop', transport=httpx.MockTransport(respond))
        self.patches = [
            patch.dict(os.environ, {'DATABASE_PATH': str(self.db_path),
                                   'POSES_PATH': 'server/config/poses.json',
                                   'POSE_PAUSE_SECONDS': '0'}),
            patch('server.app.serial_link.SerialLink.start', new_callable=AsyncMock),
            patch('server.app.main.AnalysisClient', return_value=self.analysis_client),
        ]
        for item in self.patches:
            item.start()
        self.lifespan = app.router.lifespan_context(app)
        await self.lifespan.__aenter__()
        self.service = app.state.service
        self.database = self.service.database
        self.api = httpx.AsyncClient(transport=httpx.ASGITransport(app), base_url='http://test')

        async def fake_move(name, angles, run_id, step_index=None, cycle=None):
            payload = {'pose': name, 'step_index': step_index, 'cycle': cycle}
            await self.service._add_event('F', 'POSE_REQUESTED', payload, run_id=run_id)
            await asyncio.sleep(0)
            await self.service._add_event('F', 'POSE_FINISHED', payload, run_id=run_id)

        self.service._move_pose = fake_move

    async def asyncTearDown(self):
        await self.api.aclose()
        await self.lifespan.__aexit__(None, None, None)
        for item in reversed(self.patches):
            item.stop()
        self.temp.cleanup()

    async def execute(self, mode='normal', repeat=False):
        sequence = ERROR_RUN_SEQUENCE if mode == 'error' else RUN_SEQUENCE
        run = self.database.create_run(repeat, mode)
        self.service.active_run_id = run['id']
        poses = {name: [90] * 6 for name in sequence}
        await asyncio.wait_for(
            self.service._execute_run(run['id'], repeat, mode, sequence, poses), timeout=30)
        return self.database.get_run(run['id']), self.database.list_rpfs(1, 0)[0]

    async def finish_analysis(self):
        self.release.set()
        tasks = list(self.service.analysis._tasks.values())
        await asyncio.wait_for(asyncio.gather(*tasks), timeout=1)

    async def test_completion_does_not_wait_and_result_is_saved_without_grade_changes(self):
        run, record = await self.execute('error')
        self.assertEqual(run['status'], 'completed')
        self.assertEqual(record['status'], 'completed')
        self.assertEqual(record['grade'], 'priority')
        await asyncio.wait_for(self.started.wait(), timeout=1)
        detail = (await self.api.get(f"/api/rpf/{record['id']}")).json()
        self.assertTrue(detail['analysis_pending'])
        self.assertIsNone(detail['analysis_result'])
        await self.finish_analysis()
        detail = (await self.api.get(f"/api/rpf/{record['id']}")).json()
        self.assertFalse(detail['analysis_pending'])
        self.assertEqual(detail['analysis_result']['anomaly_score'], 0.3)
        self.assertEqual(self.database.get_rpf(record['id']), record)
        reopened = Database(self.db_path)
        self.assertEqual(reopened.get_analysis_result(record['id']), detail['analysis_result'])
        reopened.close()
        self.assertEqual([r['rpf_id'] for r in self.requests], [record['id']])

    async def test_ai_failures_preserve_completion_results_and_other_apis(self):
        for failure in (httpx.ConnectError('offline'), httpx.ReadTimeout('timeout'),
                        RuntimeError('unexpected analysis error')):
            for preserve in (False, True):
                with self.subTest(failure=type(failure).__name__, preserve=preserve):
                    self.release.clear()
                    self.failure = failure
                    run, record = await self.execute()
                    saved = None
                    if preserve:
                        saved = self.database.save_analysis_result({
                            'rpf_id': record['id'], 'anomaly_score': 0.8,
                            'inspection_risk_score': 0.7, 'timeseries_anomaly_score': None,
                            'synthetic_model': True, 'model_info': {},
                        })
                    with self.assertLogs('server.app.analysis_service', level='WARNING'):
                        await self.finish_analysis()
                    self.assertEqual(self.database.get_run(run['id'])['status'], 'completed')
                    self.assertEqual(self.database.get_rpf(record['id']), record)
                    detail = (await self.api.get(f"/api/rpf/{record['id']}")).json()
                    self.assertFalse(detail['analysis_pending'])
                    self.assertEqual(detail['analysis_result'], saved)
                    for url in ('/health', '/api/status', '/api/rpf'):
                        self.assertEqual((await self.api.get(url)).status_code, 200)

    async def test_invalid_ai_response_does_not_save_or_change_grade(self):
        self.invalid = True
        _, record = await self.execute()
        with self.assertLogs('server.app.analysis_service', level='WARNING'):
            await self.finish_analysis()
        self.assertIsNone(self.database.get_analysis_result(record['id']))
        self.assertEqual(self.database.get_rpf(record['id']), record)

    async def test_existing_completed_seed_is_not_analyzed_on_start_or_read(self):
        detail = (await self.api.get(f"/api/rpf/{self.seed['id']}")).json()
        self.assertFalse(detail['analysis_pending'])
        self.assertIsNone(detail['analysis_result'])
        await asyncio.sleep(0)
        self.assertEqual(self.requests, [])
        self.assertEqual(self.database.get_rpf(self.seed['id']), self.seed)

    async def test_failed_cycle_does_not_call_ai(self):
        self.service._move_pose = AsyncMock(side_effect=RuntimeError('motion failed'))
        run, record = await self.execute()
        self.assertEqual(run['status'], 'failed')
        self.assertEqual(record['status'], 'failed')
        await asyncio.sleep(0)
        self.assertEqual(self.requests, [])

    async def test_repeat_analyzes_each_completed_cycle_once_without_waiting(self):
        start = self.service.rpf.start_cycle

        def three_cycles(run_id, cycle):
            if cycle == 3:
                raise RuntimeError('end test repeat')
            return start(run_id, cycle)

        self.service.rpf.start_cycle = three_cycles
        run, _ = await self.execute(repeat=True)
        records = [r for r in self.database.list_rpfs(10, 0) if r['run_id'] == run['id']]
        self.assertEqual(len(records), 3)
        self.assertTrue(all(r['status'] == 'completed' for r in records))
        await self.finish_analysis()
        self.assertCountEqual([p['rpf_id'] for p in self.requests], [r['id'] for r in records])
        self.assertTrue(all(self.database.get_analysis_result(r['id']) for r in records))

    async def test_shutdown_cancels_inflight_analysis_and_keeps_completed_rpf(self):
        _, record = await self.execute()
        await asyncio.wait_for(self.started.wait(), timeout=1)
        await asyncio.wait_for(self.service.analysis.shutdown(), timeout=1)
        self.assertFalse(self.service.analysis.is_pending(record['id']))
        self.assertEqual(self.database.get_rpf(record['id']), record)
        self.assertIsNone(self.database.get_analysis_result(record['id']))

    async def test_repeated_completion_does_not_schedule_existing_completed_record(self):
        self.service.active_run_id = self.seed['run_id']
        self.service.active_rpf_id = self.seed['id']
        await self.service._finish_active_rpf('completed')
        await asyncio.sleep(0)
        self.assertEqual(self.requests, [])
