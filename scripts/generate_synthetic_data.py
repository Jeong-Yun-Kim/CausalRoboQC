"""Generate reproducible RPF-like trial data; all durations are invented milliseconds."""

import argparse
from pathlib import Path
import sys

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from ai.modeling import DATA_DIR, RANDOM_SEED, SEQUENCE_FEATURE_NAMES, SYNTHETIC_NOTICE


def generate(sample_count: int = 2000) -> tuple[pd.DataFrame, pd.DataFrame]:
    if sample_count < 100:
        raise ValueError("Generate at least 100 samples to retain all synthetic regimes")
    rng = np.random.default_rng(RANDOM_SEED)
    normal_count = round(sample_count * 0.75)
    review_count = round(sample_count * 0.18)
    grades = np.array(
        ["normal"] * normal_count + ["review"] * review_count
        + ["priority"] * (sample_count - normal_count - review_count)
    )
    rng.shuffle(grades)
    # Grade is a synthetic generation regime, not a copy of production grade rules.
    regimes = {"normal": (0.15, 0.04, 0.015, 0.0),
               "review": (0.9, 0.4, 0.25, 0.55),
               "priority": (2.8, 1.5, 1.2, 1.5)}
    base_ms = np.array([800, 1100, 900, 550, 1000, 1500, 450], dtype=float)
    rpf_rows, sequence_rows = [], []
    for index, grade in enumerate(grades):
        retry_rate, error_rate, intervention_rate, severity = regimes[grade]
        retry, error, intervention = rng.poisson([retry_rate, error_rate, intervention_rate])
        # Shared cycle speed plus per-stage variation yields a repeatable normal pattern.
        durations = base_ms * rng.normal(1.0, 0.035) * rng.normal(1.0, 0.04, 7)
        if severity:
            affected = rng.random(3) < 0.65
            affected[rng.integers(3)] = True
            for stage in np.array([2, 4, 5])[affected]:
                durations[stage] *= (1 + severity * rng.uniform(0.4, 1.4))
                durations[stage] *= rng.lognormal(0.0, 0.12 * severity)
        durations[2] += retry * rng.uniform(300, 600)
        durations[5] += error * rng.uniform(500, 900)
        durations[4] += intervention * rng.uniform(500, 1100)
        durations = np.rint(np.maximum(durations, 100)).astype(int)
        # The final HOME return and waits are outside the seven stage summaries.
        overhead = max(100, rng.normal(1300, 180))
        work_time = round(durations.sum() + overhead + 700 * retry + 1000 * error + 1300 * intervention)
        logit = (-3.2 + 0.55 * retry + 0.85 * error + 0.5 * intervention
                 + 0.00038 * (work_time - 8000) + rng.normal(0, 0.6))
        fail_chance = 0.03 + 0.94 / (1 + np.exp(-np.clip(logit, -30, 30)))
        inspection = "fail" if rng.random() < fail_chance else "pass"
        product_id = f"SYN-P-{index + 1:05d}"
        rpf_rows.append([product_id, work_time, retry, error, intervention, grade, inspection])
        sequence_rows.append([product_id, *durations])
    rpf = pd.DataFrame(rpf_rows, columns=[
        "product_id", "work_time_ms", "retry_count", "error_count",
        "operator_interventions", "grade", "inspection_result",
    ])
    sequences = pd.DataFrame(sequence_rows, columns=["product_id", *SEQUENCE_FEATURE_NAMES])
    return rpf, sequences


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=DATA_DIR)
    parser.add_argument("--sample-count", type=int, default=2000)
    args = parser.parse_args()
    rpf, sequences = generate(args.sample_count)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    rpf.to_csv(args.output_dir / "rpf.csv", index=False)
    sequences.to_csv(args.output_dir / "rpf_sequences.csv", index=False)
    print(SYNTHETIC_NOTICE)
    print(f"seed={RANDOM_SEED}; products={len(rpf)}; sequences={len(sequences)}")
    print("Synthetic grades:", rpf["grade"].value_counts().to_dict())
    print("Synthetic inspection outcomes:", rpf["inspection_result"].value_counts().to_dict())
    print(f"Saved to {args.output_dir}")


if __name__ == "__main__":
    main()
