import copy
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient

from ai.app.main import app
from ai.modeling import SyntheticModels


BODY = {
    "rpf_id": 23, "product_id": "P-023",
    "features": {"work_time_ms": 13800, "retry_count": 1, "error_count": 1,
                 "operator_interventions": 0},
    "sequence": {"HOME": 800, "PICK_ABOVE": 1050, "PICK": 900, "GRAB": 500,
                 "LIFT": 1000, "PLACE": 1200, "RELEASE": 400},
}


class LaptopAnalysisTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.loader_patch = patch("ai.app.main.SyntheticModels", wraps=SyntheticModels)
        cls.loader = cls.loader_patch.start()
        cls.client = TestClient(app)
        cls.client.__enter__()

    @classmethod
    def tearDownClass(cls):
        cls.client.__exit__(None, None, None)
        cls.loader_patch.stop()

    def test_health_and_model_loaded_once(self):
        for _ in range(2):
            self.assertEqual(self.client.get("/health").json(), {"status": "ok", "synthetic_model": True})
            self.assertEqual(self.client.post("/api/analyze/rpf", json=BODY).status_code, 200)
        self.assertEqual(self.loader.call_count, 1)

    def test_complete_sequence_returns_three_bounded_scores(self):
        response = self.client.post("/api/analyze/rpf", json=BODY)
        self.assertEqual(response.status_code, 200, response.text)
        result = response.json()
        self.assertEqual(result["rpf_id"], 23)
        self.assertTrue(result["synthetic_model"])
        for name in ("anomaly_score", "inspection_risk_score", "timeseries_anomaly_score"):
            self.assertGreaterEqual(result[name], 0)
            self.assertLessEqual(result[name], 1)
        self.assertTrue(result["model_info"]["sequence_available"])

    def test_missing_partial_null_sequences_keep_if_rf(self):
        complete = self.client.post("/api/analyze/rpf", json=BODY).json()
        for sequence in (None, {}, {"HOME": 800}, {**BODY["sequence"], "PICK": None}):
            with self.subTest(sequence=sequence):
                body = {**BODY, "sequence": sequence}
                response = self.client.post("/api/analyze/rpf", json=body)
                self.assertEqual(response.status_code, 200, response.text)
                result = response.json()
                self.assertIsNone(result["timeseries_anomaly_score"])
                self.assertFalse(result["model_info"]["sequence_available"])
                for name in ("anomaly_score", "inspection_risk_score"):
                    self.assertEqual(result[name], complete[name])
        body = {key: value for key, value in BODY.items() if key != "sequence"}
        self.assertIsNone(self.client.post("/api/analyze/rpf", json=body).json()["timeseries_anomaly_score"])

    def test_invalid_features_are_4xx(self):
        for name, value in (("retry_count", -1), ("error_count", 0.5),
                            ("work_time_ms", "nan"), ("work_time_ms", None),
                            ("operator_interventions", True), ("grade", "normal")):
            with self.subTest(name=name, value=value):
                body = copy.deepcopy(BODY)
                body["features"][name] = value
                self.assertEqual(self.client.post("/api/analyze/rpf", json=body).status_code, 422)
        body = copy.deepcopy(BODY)
        del body["features"]["retry_count"]
        self.assertEqual(self.client.post("/api/analyze/rpf", json=body).status_code, 422)

    def test_invalid_sequence_is_not_padded(self):
        for value in (-1, 0, "unknown"):
            body = copy.deepcopy(BODY)
            body["sequence"]["HOME"] = value
            self.assertEqual(self.client.post("/api/analyze/rpf", json=body).status_code, 422)
