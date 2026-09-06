"""Reload synthetic models and check inference, alignment and label exclusion."""

import argparse
from pathlib import Path
import sys

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from ai.modeling import (
    FEATURE_NAMES, MODEL_DIR, SCORE_NAMES, SEQUENCE_FEATURE_NAMES,
    SYNTHETIC_NOTICE, SyntheticModels,
)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-dir", type=Path, default=MODEL_DIR)
    args = parser.parse_args()
    print(SYNTHETIC_NOTICE)
    models = SyntheticModels(args.model_dir)
    names = ["NORMAL", "MODERATE_ABNORMAL", "STRONG_ABNORMAL"]
    rpf = pd.DataFrame([
        [7600, 0, 0, 0], [10500, 1, 0, 0], [24000, 4, 2, 2],
    ], columns=FEATURE_NAMES)
    sequences = pd.DataFrame([
        [800, 1100, 900, 550, 1000, 1500, 450],
        [820, 1120, 1200, 570, 1300, 1850, 460],
        [900, 1250, 3400, 600, 4000, 5100, 500],
    ], columns=SEQUENCE_FEATURE_NAMES)
    rpf["product_id"] = sequences["product_id"] = names
    scores = models.predict(rpf, sequences)
    assert list(scores.columns) == SCORE_NAMES
    assert np.isfinite(scores.to_numpy()).all(), "All three scores must be finite"
    assert scores.ge(0).all().all() and scores.le(1).all().all(), "Scores must be in [0, 1]"
    assert (scores.iloc[2] > scores.iloc[0]).all(), "Strong fixture should exceed the normal fixture"

    # Product joins and explicit feature selection must survive reordering and labels.
    shuffled = models.predict(rpf.loc[:, rpf.columns[::-1]], sequences.iloc[::-1])
    np.testing.assert_allclose(shuffled, scores, rtol=0, atol=0)
    with_labels = rpf.assign(grade="priority", inspection_result="fail")
    np.testing.assert_allclose(models.predict(with_labels, sequences), scores, rtol=0, atol=0)
    with_labels = rpf.assign(grade="normal", inspection_result="pass")
    np.testing.assert_allclose(models.predict(with_labels, sequences), scores, rtol=0, atol=0)
    np.testing.assert_allclose(
        models.predict(rpf.drop(columns="product_id"), sequences.drop(columns="product_id")),
        scores, rtol=0, atol=0,
    )
    invalid_sequences = sequences.copy()
    invalid_sequences.loc[0, "product_id"] = "UNKNOWN"
    invalid_features = rpf.copy()
    invalid_features.loc[0, "work_time_ms"] = np.nan
    for invalid_rpf, invalid_sequence in ((rpf, invalid_sequences), (invalid_features, sequences)):
        try:
            models.predict(invalid_rpf, invalid_sequence)
        except ValueError:
            pass
        else:
            raise AssertionError("Invalid model input should be rejected")

    for name, (_, row) in zip(names, scores.iterrows()):
        print(f"\n{name}")
        for score_name, value in row.items():
            print(f"{score_name}: {value:.4f}")
    print("\nPASS: all models reload; scores are finite and bounded; labels are excluded; IDs align.")


if __name__ == "__main__":
    main()
