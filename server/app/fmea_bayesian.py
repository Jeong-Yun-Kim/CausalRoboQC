"""Exact enumeration of a small discrete BN; assumptions live in FMEA config.

P(C, E) = P(C) * product P(E_i | C). C is a *single dominant hypothesis*,
not six independent fault-presence variables. Its posterior sums to one.
No physical measurements, learned parameters, or model-score pseudo-evidence.
"""

from functools import lru_cache
import json
import math
from pathlib import Path


CONFIG = Path(__file__).resolve().parents[1] / "config" / "fmea_bayesian.json"


@lru_cache(maxsize=1)
def load_model() -> dict:
    model = json.loads(CONFIG.read_text(encoding="utf-8"))
    causes, evidence = model["causes"], model["evidence"]
    if len({cause["id"] for cause in causes}) != len(causes):
        raise ValueError("Duplicate FMEA causes")
    for cause in causes:
        if set(cause["cpt_true"]) != set(evidence):
            raise ValueError("Incomplete Bayesian CPT")
        if any(not math.isfinite(p) or not 0 < p < 1
               for p in [cause["prior"], *cause["cpt_true"].values()]):
            raise ValueError("Bayesian probabilities must be finite and strictly between 0 and 1")
    if not math.isclose(math.fsum(cause["prior"] for cause in causes), 1.0, abs_tol=1e-12):
        raise ValueError("Bayesian priors must sum to one")
    return model


def observed_evidence(record: dict, events: list[dict], model: dict) -> dict:
    names = {event["name"] for event in events}
    complete = record.get("status") == "completed"
    observed = {}
    for name, definition in model["evidence"].items():
        count = record.get(definition.get("count", ""))
        positive = bool(names.intersection(definition["events"])) or (
            isinstance(count, (int, float)) and count > 0)
        observed[name] = True if positive else False if complete else None
    # error_count includes retry/failure/intervention events. Do not count those
    # same observations again as independent error evidence. Unknown != false.
    if any(value is True for name, value in observed.items() if name != "UnclassifiedError"):
        observed["UnclassifiedError"] = None
    return observed


def cause_candidates(record: dict, events: list[dict]) -> dict:
    model = load_model()
    observed = observed_evidence(record, events, model)
    weights = []
    for cause in model["causes"]:
        weight = cause["prior"]
        for name, value in observed.items():
            if value is not None:
                p = cause["cpt_true"][name]
                weight *= p if value else 1 - p
        weights.append(weight)
    total = math.fsum(weights)
    candidates = sorted([
        {"id": cause["id"], "cause": cause["cause"], "probability": weight / total,
         "check": cause["check"]}
        for cause, weight in zip(model["causes"], weights)
    ], key=lambda item: item["probability"], reverse=True)
    positive = [model["evidence"][name]["label"] for name, value in observed.items() if value is True]
    return {
        "model_version": model["version"], "probability_meaning": model["probability_meaning"],
        "note": "단일 주원인 가설 간 비교이며 실제 불량 확률이나 원인 확정값이 아닙니다.",
        "evidence": observed, "observed_labels": positive,
        "evidence_note": "관측 근거: " + ", ".join(positive) if positive else
            "기록된 이상 관측이 없어 후보 분포만 제시합니다. 이상 발생을 뜻하지 않습니다.",
        "candidates": candidates, "top_candidates": candidates[:3],
        "other_probability": math.fsum(item["probability"] for item in candidates[3:]),
    }
