import asyncio
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

import httpx

from scripts.prepare_rpf_presentation import analyze_seed, backup_database, migrate_seed_ids, owned_records
from scripts.seed_demo_rpf import PRODUCT_IDS, seed_demo
from server.app.analysis_client import AnalysisClient, AnalysisError
from server.app.database import Database
from server.app.rpf_presentation import presentation
from server.tests.analysis_fixtures import create_rpf


class PresentationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "records.db"
        self.rules = Path("server/config/rpf_rules.json")
        seed_demo(self.path, self.rules)
        self.db = Database(self.path)
        self.addCleanup(self.db.close)

    def legacy_ids(self):
        with self.db.connection:
            for record in owned_records(self.db):
                old = "DEMO-" + record["product_id"]
                self.db.connection.execute("UPDATE rpf_records SET product_id=? WHERE id=?", (old, record["id"]))
                for event in self.db.list_rpf_events(record["id"]):
                    if "product_id" in event["payload"]:
                        event["payload"]["product_id"] = old
                        self.db.connection.execute("UPDATE events SET payload=? WHERE id=?",
                            (json.dumps(event["payload"], ensure_ascii=False), event["id"]))

    def score(self, ident):
        # Explicit transport fixture for atomicity tests; real inference is tested in ai/tests.
        return {"rpf_id": ident, "anomaly_score": .2, "inspection_risk_score": .3,
                "timeseries_anomaly_score": .4, "synthetic_model": True, "model_info": {"fixture": True}}

    def test_exact_30_ids_grade_distribution_and_rerun(self):
        self.assertEqual([row["product_id"] for row in owned_records(self.db)], PRODUCT_IDS)
        self.assertEqual(len(PRODUCT_IDS), 30)
        user = create_rpf(self.db, product_id="CUSTOMER-001")
        events = self.db.list_rpf_events(user["id"])
        result = seed_demo(self.path, self.rules)
        self.assertEqual(result["demo_rpfs"], 30)
        self.assertEqual(result["grades"], {"normal": 22, "review": 6, "priority": 2})
        self.assertEqual(self.db.get_rpf(user["id"]), user)
        self.assertEqual(self.db.list_rpf_events(user["id"]), events)

    def test_migrate_preserves_identity_scores_grades_timestamps_and_users(self):
        self.legacy_ids()
        user = create_rpf(self.db, product_id="DEMO-RPF-999")
        user_events = self.db.list_rpf_events(user["id"])
        before = owned_records(self.db)
        saved = self.db.save_analysis_result(self.score(before[0]["id"]))
        event_ids = [row[0] for row in self.db.connection.execute("SELECT id FROM events ORDER BY id")]
        self.assertEqual(migrate_seed_ids(self.db), 30)
        for old, new in zip(before, owned_records(self.db)):
            self.assertEqual({**old, "product_id": old["product_id"].removeprefix("DEMO-")}, new)
            for event in self.db.list_rpf_events(new["id"]):
                if "product_id" in event["payload"]:
                    self.assertEqual(event["payload"]["product_id"], new["product_id"])
        self.assertEqual(self.db.get_analysis_result(before[0]["id"]), saved)
        self.assertEqual(self.db.get_rpf(user["id"]), user)
        self.assertEqual(self.db.list_rpf_events(user["id"]), user_events)
        self.assertEqual(event_ids, [row[0] for row in self.db.connection.execute("SELECT id FROM events ORDER BY id")])
        snapshot = list(self.db.connection.iterdump())
        self.assertEqual(migrate_seed_ids(self.db), 0)
        self.assertEqual(snapshot, list(self.db.connection.iterdump()))

    def test_collision_rolls_back_entire_migration_and_seed(self):
        self.legacy_ids()
        create_rpf(self.db, product_id="RPF-014")
        before = list(self.db.connection.iterdump())
        with self.assertRaisesRegex(ValueError, "collision"):
            migrate_seed_ids(self.db)
        self.assertEqual(before, list(self.db.connection.iterdump()))
        with self.assertRaisesRegex(ValueError, "non-seed"):
            seed_demo(self.path, self.rules)
        self.assertEqual(before, list(self.db.connection.iterdump()))

    def test_unowned_legacy_name_never_grants_permission(self):
        user = create_rpf(self.db, product_id="DEMO-RPF-001")
        self.assertEqual(migrate_seed_ids(self.db), 0)
        self.assertEqual(self.db.get_rpf(user["id"]), user)

    def test_sqlite_backup_includes_wal(self):
        self.db.connection.execute("PRAGMA wal_autocheckpoint=0")
        create_rpf(self.db, product_id="BACKUP-001")
        path = backup_database(self.path)
        with sqlite3.connect(path) as connection:
            self.assertEqual(list(connection.iterdump()), list(self.db.connection.iterdump()))

    def run_analysis(self, respond):
        async def run():
            client = AnalysisClient("http://fixture", transport=httpx.MockTransport(respond))
            try:
                return await analyze_seed(self.db, client)
            finally:
                await client.close()
        return asyncio.run(run())

    def test_all_scores_saved_and_user_analysis_untouched(self):
        user = create_rpf(self.db, product_id="CUSTOMER-001")
        user_score = self.db.save_analysis_result(self.score(user["id"]))
        records = owned_records(self.db)
        result = self.run_analysis(lambda r: httpx.Response(200, json=self.score(json.loads(r.content)["rpf_id"])))
        self.assertEqual(result["analyzed_rpfs"], 30)
        self.assertEqual(records, owned_records(self.db))
        self.assertEqual(self.db.get_analysis_result(user["id"]), user_score)
        for record in records:
            self.assertIsNotNone(self.db.get_analysis_result(record["id"])["timeseries_anomaly_score"])

    def test_model_failure_or_missing_autoencoder_preserves_all_scores(self):
        saved = self.db.save_analysis_result(self.score(owned_records(self.db)[0]["id"]))
        for missing in (False, True):
            calls = []
            def respond(request):
                ident = json.loads(request.content)["rpf_id"]
                calls.append(ident)
                if len(calls) == 30:
                    if not missing:
                        raise httpx.ConnectError("AI unavailable")
                    return httpx.Response(200, json={**self.score(ident), "timeseries_anomaly_score": None})
                return httpx.Response(200, json=self.score(ident))
            with self.assertRaises(AnalysisError):
                self.run_analysis(respond)
            self.assertEqual(len(calls), 30)
            self.assertEqual(self.db.connection.execute("SELECT COUNT(*) FROM analysis_results").fetchone()[0], 1)
            self.assertEqual(self.db.get_analysis_result(saved["rpf_id"]), saved)

    def test_invalid_stages_never_invented_and_concurrent_changes_rejected(self):
        calls = []
        def respond(request):
            calls.append(request)
            if len(calls) == 30:
                with self.db.connection:
                    self.db.connection.execute("UPDATE rpf_records SET retry_count=4 WHERE product_id='RPF-001'")
            return httpx.Response(200, json=self.score(json.loads(request.content)["rpf_id"]))
        with self.assertRaisesRegex(ValueError, "changed during inference"):
            self.run_analysis(respond)
        self.assertEqual(self.db.connection.execute("SELECT COUNT(*) FROM analysis_results").fetchone()[0], 0)
        with self.db.connection:
            self.db.connection.execute("DELETE FROM events WHERE id=(SELECT MIN(id) FROM events WHERE name='POSE_FINISHED')")
        with self.assertRaisesRegex(ValueError, "Incomplete process stages"):
            self.run_analysis(lambda _: self.fail("Must reject before calling AI"))

    def test_report_uses_evidence_no_cause_probabilities_or_inspection_labels(self):
        record = next(row for row in owned_records(self.db) if row["grade"] == "priority")
        result = presentation(record, self.db.list_rpf_events(record["id"]), self.score(record["id"]))
        self.assertEqual(len(result["stages"]), 7)
        self.assertIn("우선검사", result["report_draft"])
        self.assertIn("공정 단계 시간 이상도: 0.4", result["report_draft"])
        self.assertGreater(len(result["recommended_checks"]), 1)
        self.assertNotRegex(result["report_draft"], "데모|합성|테스트|DEMO")
        self.assertNotIn("cause_candidates", result)
