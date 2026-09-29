"""Actual model inference through the production presentation startup path."""

import hashlib
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

import httpx
import pandas as pd

from ai.app.main import app as laptop
from ai.modeling import FEATURE_NAMES, MODEL_DIR, SCORE_NAMES
from server.app.analysis_client import AnalysisClient, pose_sequence
from server.app.main import app as api


class IntegratedPresentationTest(unittest.IsolatedAsyncioTestCase):
    async def test_startup_creates_exactly_30_real_scores_and_restart_is_read_only(self):
        hashes = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in MODEL_DIR.iterdir() if p.is_file()}
        with tempfile.TemporaryDirectory() as temporary:
            env = {"PRESENTATION_MODE": "true", "PRESENTATION_DATABASE_PATH": str(Path(temporary) / "presentation.db")}
            async with laptop.router.lifespan_context(laptop):
                def client(*args):
                    return AnalysisClient("http://laptop", transport=httpx.ASGITransport(laptop))
                with patch.dict(os.environ, env), patch("server.app.main.AnalysisClient", side_effect=client), patch(
                    "server.app.serial_link.SerialLink.start", new_callable=AsyncMock
                ):
                    async with api.router.lifespan_context(api):
                        db = api.state.service.database
                        rows = sorted(db.list_rpfs(100, 0), key=lambda r: r["product_id"])
                        self.assertEqual([r["product_id"] for r in rows], [f"RPF-{i:03d}" for i in range(1, 31)])
                        expected = laptop.state.models.predict(
                            pd.DataFrame([{k: r[k] for k in FEATURE_NAMES} for r in rows]),
                            pd.DataFrame([pose_sequence(db.list_rpf_events(r["id"]), r["cycle_index"]) for r in rows]),
                        )
                        for i, row in enumerate(rows):
                            saved = db.get_analysis_result(row["id"])
                            for key in SCORE_NAMES:
                                # Float32 AE batch vs single-row CPU kernels can differ <1e-6.
                                self.assertAlmostEqual(saved[key], expected.iloc[i][key], places=6)
                        snapshot = list(db.connection.iterdump())
                    with patch.object(AnalysisClient, "analyze", side_effect=AssertionError("duplicate inference")):
                        async with api.router.lifespan_context(api):
                            self.assertEqual(snapshot, list(api.state.service.database.connection.iterdump()))
        self.assertEqual(hashes, {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in hashes})
