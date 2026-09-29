import math
import unittest

from server.app.fmea_bayesian import cause_candidates, load_model


class BayesianTest(unittest.TestCase):
    def record(self, **updates):
        return {"status": "completed", "retry_count": 0, "error_count": 0,
                "operator_interventions": 0, **updates}

    def test_exact_bayes_update_with_one_observed_node(self):
        # Unknown/uncompleted evidence is marginalized, not assumed negative.
        result = cause_candidates(self.record(status="running", retry_count=1), [])
        model = load_model()
        weights = {c["id"]: c["prior"] * c["cpt_true"]["PickRetry"] for c in model["causes"]}
        for item in result["candidates"]:
            self.assertAlmostEqual(item["probability"], weights[item["id"]] / sum(weights.values()))
        self.assertIsNone(result["evidence"]["WorkTimeOverrun"])

    def test_ranges_normalization_and_top_remainder_across_all_observations(self):
        nodes = load_model()["evidence"]
        for mask in range(1 << (len(nodes) - 1)):
            events = [{"name": definition["events"][0]} for i, definition in enumerate(nodes.values())
                      if definition["events"] and mask & (1 << i)]
            result = cause_candidates(self.record(), events)
            values = [item["probability"] for item in result["candidates"]]
            self.assertTrue(all(math.isfinite(p) and 0 <= p <= 1 for p in values))
            self.assertAlmostEqual(sum(values), 1)
            self.assertAlmostEqual(sum(i["probability"] for i in result["top_candidates"])
                                   + result["other_probability"], 1)
            self.assertEqual(values, sorted(values, reverse=True))

    def test_specific_observations_raise_relevant_candidate_without_fake_measurements(self):
        for event, cause in (("PLACE_FAILURE_INJECTED", "PlaceAlignmentError"),
                             ("PRODUCT_ID_MISMATCH", "IdentificationProblem"),
                             ("WORK_TIME_EXCEEDED", "CommunicationDelay"),
                             ("OPERATOR_INTERVENTION", "OperatorAction")):
            result = cause_candidates(self.record(error_count=1), [{"name": event}])
            self.assertEqual(result["top_candidates"][0]["id"], cause)
            self.assertIsNone(result["evidence"]["UnclassifiedError"])
            self.assertNotRegex(str(result), r"\d\s*mm|position_error_mm")
        result = cause_candidates(self.record(retry_count=1, error_count=1), [])
        self.assertEqual({i["id"] for i in result["top_candidates"][:2]},
                         {"InitialPositionError", "GripperProblem"})

    def test_absence_of_anomalies_is_not_a_fault_claim_or_duration_threshold(self):
        result = cause_candidates(self.record(work_time_ms=99999999), [])
        self.assertFalse(result["evidence"]["WorkTimeOverrun"])
        self.assertIn("이상 발생을 뜻하지 않습니다", result["evidence_note"])
        self.assertEqual(result["probability_meaning"], "현재 정의한 FMEA/Bayesian 모델 기준 원인 후보 확률")
        self.assertIn("실제 불량 확률이나 원인 확정값이 아닙니다", result["note"])
