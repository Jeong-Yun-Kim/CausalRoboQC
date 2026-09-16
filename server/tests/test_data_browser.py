import csv
import io
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient

from scripts.seed_demo_rpf import seed_demo
from server.app.database import Database
from server.app.data_browser import CSV_COLUMNS
from server.app.main import app


class DataBrowserTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "browser.db"
        for item in (
            patch.dict(os.environ, {"DATABASE_PATH": str(self.path)}),
            patch("server.app.main.RobotService.start", new_callable=AsyncMock),
            patch("server.app.main.RobotService.shutdown", new_callable=AsyncMock),
        ):
            item.start()
            self.addCleanup(item.stop)
        self.client = TestClient(app)
        self.client.__enter__()
        self.addCleanup(self.client.__exit__, None, None, None)
        self.db = app.state.service.database
        self.run = self.db.create_run(True)
        self.records = []
        # UTC and offset representations, plus an unfinished record, exercise
        # instant comparisons, inclusive lower and exclusive upper boundaries.
        for product, group, grade, finished in (
            ("제품-001", "A", "normal", "2026-09-10T15:00:00Z"),
            ("제품-002", "B", "review", "2026-09-11T12:00:00+09:00"),
            ("제품-003", "A", "priority", "2026-09-11T14:59:59.999Z"),
            ("literal_%'", None, "normal", "2026-09-11T15:00:00Z"),
            ("running", "C", None, None),
        ):
            record = self.db.create_rpf(self.run["id"], len(self.records), product, group)
            self.db.connection.execute(
                "UPDATE rpf_records SET finished_at=?,grade=?,work_time_ms=12000 WHERE id=?",
                (finished, grade, record["id"]),
            )
            self.db.connection.commit()
            self.records.append(self.db.get_rpf(record["id"]))
        self.db.save_analysis_result({
            "rpf_id": self.records[1]["id"], "anomaly_score": 0.25,
            "inspection_risk_score": 0.5, "timeseries_anomaly_score": None,
            "synthetic_model": True, "model_info": {"fixture": True},
        })

    def query(self, **params):
        response = self.client.get("/api/data/rpf", params=params)
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()

    def assert_parity(self, params):
        data = self.query(**params)
        response = self.client.get("/api/data/rpf.csv", params=params)
        self.assertEqual(response.status_code, 200, response.text)
        self.assertTrue(response.content.startswith(b"\xef\xbb\xbf"))
        self.assertIn("text/csv", response.headers["content-type"])
        self.assertRegex(response.headers["content-disposition"], r'attachment; filename="causalroboqc_rpf_\d{8}.csv"')
        reader = csv.DictReader(io.StringIO(response.content.decode("utf-8-sig")))
        self.assertEqual(reader.fieldnames, list(CSV_COLUMNS))
        rows = list(reader)
        self.assertEqual(rows, [{k: "" if row[k] is None else str(row[k])
                                 for k in CSV_COLUMNS} for row in data["items"]])
        return data

    def test_filters_csv_parity_and_no_sql_wildcards(self):
        for params, expected in (
            ({}, 5), ({"product_group": "A"}, 2), ({"product_group": "B"}, 1),
            ({"grade": "normal"}, 2), ({"grade": "priority"}, 1),
            ({"product_id": "제품-00"}, 3), ({"product_id": "_%'"}, 1),
            ({"product_id": "' OR 1=1 --"}, 0),
            ({"product_group": "' OR 1=1 --"}, 0),
            ({"from_at": "2026-09-11T00:00:00+09:00",
              "to_at": "2026-09-12T00:00:00+09:00"}, 3),
            ({"from_at": "2026-09-11T03:00:00Z"}, 3),
            ({"to_at": "2026-09-11T03:00:00Z"}, 1),
            ({"from_at": "2026-09-11T00:00:00+09:00",
              "to_at": "2026-09-12T00:00:00+09:00", "product_group": "A",
              "grade": "priority", "product_id": "003"}, 1),
            ({"product_id": "missing"}, 0),
        ):
            with self.subTest(params=params):
                data = self.assert_parity(params)
                self.assertEqual(data["total"], expected)
                self.assertEqual(len(data["items"]), expected)
                self.assertEqual(data["product_groups"], ["A", "B", "C"])

    def test_join_and_null_scores(self):
        rows = {row["id"]: row for row in self.assert_parity({})["items"]}
        joined = rows[self.records[1]["id"]]
        self.assertEqual(joined["anomaly_score"], 0.25)
        self.assertEqual(joined["inspection_risk_score"], 0.5)
        self.assertIsNone(joined["timeseries_anomaly_score"])
        for record in (self.records[0], self.records[-1]):
            for key in CSV_COLUMNS[-3:]:
                self.assertIsNone(rows[record["id"]][key])

    def test_pagination_and_total(self):
        all_rows = self.query()["items"]
        data = self.assert_parity({"limit": 2, "offset": 1})
        self.assertEqual(data["items"], all_rows[1:3])
        self.assertEqual(data["total"], 5)
        self.assertEqual(self.query(offset=100)["items"], [])

    def test_invalid_filters_rejected_equally(self):
        for params in ({"grade": "invalid"}, {"from_at": "bad"},
                       {"from_at": "2026-09-11T00:00:00"},
                       {"from_at": "2026-09-12T00:00:00Z", "to_at": "2026-09-11T00:00:00Z"},
                       {"limit": 0}, {"limit": 501}, {"offset": -1}):
            for endpoint in ("rpf", "rpf.csv"):
                with self.subTest(params=params, endpoint=endpoint):
                    self.assertEqual(self.client.get(f"/api/data/{endpoint}", params=params).status_code, 422)

    def test_migration_preserves_old_records_events_and_analysis(self):
        record = self.db.create_rpf(self.run["id"], 99, "legacy")
        self.assertIsNone(record["product_group"])
        event = self.db.add_event(self.run["id"], "F", "LEGACY", rpf_id=record["id"])
        analysis = self.db.get_analysis_result(self.records[1]["id"])
        self.db.connection.execute("ALTER TABLE rpf_records DROP COLUMN product_group")
        self.db.connection.commit()
        migrated = Database(self.path)
        try:
            self.assertEqual(migrated.get_rpf(record["id"]), record)
            self.assertEqual(migrated.list_rpf_events(record["id"]), [event])
            self.assertEqual(migrated.get_analysis_result(self.records[1]["id"]), analysis)
            self.assertEqual(migrated.browse_rpfs()["total"], 6)
        finally:
            migrated.close()
        reopened = Database(self.path)
        reopened.close()
        # Original API still has its existing ordering and detail contract.
        self.assertEqual(self.client.get("/api/rpf", params={"limit": 1}).json()["items"], [record])
        self.assertEqual(self.client.get(f"/api/rpf/{record['id']}").json()["events"], [event])

    def test_demo_filters_and_export_all_pages_without_inference(self):
        summary = seed_demo(self.path, Path("server/config/rpf_rules.json"))
        self.assertEqual(summary["product_groups"], {"A": 10, "B": 10, "C": 10})
        demo = self.query(product_id="RPF-")
        self.assertEqual(demo["total"], 30)
        self.assertTrue(all(row[key] is None for row in demo["items"] for key in CSV_COLUMNS[-3:]))
        for params, expected in (({"product_group": "A"}, 10), ({"product_group": "B"}, 10),
                                 ({"grade": "normal"}, 22), ({"grade": "priority"}, 2),
                                 ({"product_id": "RPF-001"}, 1)):
            self.assertEqual(self.assert_parity({"product_id": "RPF-", **params})["total"], expected)
        times = sorted(row["finished_at"] for row in demo["items"])
        self.assertEqual(self.query(product_id="RPF-", from_at=times[0], to_at=times[10])["total"], 10)
        self.assertEqual(len(self.query(product_id="RPF-", limit=25)["items"]), 25)
        self.assertEqual(self.assert_parity({"product_id": "RPF-"})["total"], 30)
        before = {row["product_id"]: row["product_group"] for row in demo["items"]}
        seed_demo(self.path, Path("server/config/rpf_rules.json"))
        self.assertEqual(before, {row["product_id"]: row["product_group"]
                                 for row in self.query(product_id="RPF-")["items"]})

    def test_csv_without_limit_is_not_capped_at_default_json_page(self):
        for index in range(60):
            self.db.create_rpf(self.run["id"], index + 100, f"bulk-{index}")
        data = self.query(product_id="bulk-")
        self.assertEqual((len(data["items"]), data["total"]), (50, 60))
        response = self.client.get("/api/data/rpf.csv", params={"product_id": "bulk-"})
        self.assertEqual(len(list(csv.DictReader(io.StringIO(response.content.decode("utf-8-sig"))))), 60)
