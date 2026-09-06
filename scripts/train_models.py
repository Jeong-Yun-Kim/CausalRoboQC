"""Train and persist three small models for synthetic pipeline validation only."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import sys

import joblib
import numpy as np
import pandas as pd
import scipy
import sklearn
from sklearn.ensemble import IsolationForest, RandomForestClassifier
from sklearn.metrics import brier_score_loss, roc_auc_score
from sklearn.model_selection import train_test_split
from sklearn.preprocessing import StandardScaler
import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from ai.modeling import (
    Autoencoder, DATA_DIR, FEATURE_NAMES, MODEL_DIR, RANDOM_SEED,
    RISK_FEATURE_NAMES, SEQUENCE_FEATURE_NAMES, SYNTHETIC_NOTICE, SyntheticModels,
    align_sequences, fail_probabilities, fit_normalization, normalize_scores,
    numeric_features, reconstruction_errors,
)


def train(data_dir: Path, model_dir: Path) -> dict:
    np.random.seed(RANDOM_SEED)
    torch.manual_seed(RANDOM_SEED)
    torch.set_num_threads(1)
    torch.use_deterministic_algorithms(True)
    rpf = pd.read_csv(data_dir / "rpf.csv")
    sequences = align_sequences(rpf, pd.read_csv(data_dir / "rpf_sequences.csv"))
    features = numeric_features(rpf, FEATURE_NAMES)
    sequence_features = numeric_features(sequences, SEQUENCE_FEATURE_NAMES)
    if rpf["grade"].isna().any() or not rpf["grade"].isin(["normal", "review", "priority"]).all():
        raise ValueError("Expected synthetic grade labels: normal/review/priority")
    if rpf["inspection_result"].isna().any() or set(rpf["inspection_result"]) != {"pass", "fail"}:
        raise ValueError("Expected both synthetic inspection labels: pass/fail")
    # Split product IDs once, before fitting any scaler, model or normalization.
    train_indices, test_indices = train_test_split(
        np.arange(len(rpf)), test_size=0.2, random_state=RANDOM_SEED,
        stratify=rpf["grade"] + ":" + rpf["inspection_result"],
    )
    normal_indices = train_indices[rpf.iloc[train_indices]["grade"].eq("normal").to_numpy()]
    if len(normal_indices) < 20:
        raise ValueError("At least 20 normal training products are required")

    feature_scaler = StandardScaler().fit(features.iloc[normal_indices])
    isolation_forest = IsolationForest(
        n_estimators=128, max_samples=min(256, len(normal_indices)),
        contamination="auto", random_state=RANDOM_SEED, n_jobs=1,
    )
    isolation_forest.fit(feature_scaler.transform(features.iloc[normal_indices]))
    raw_anomaly = -isolation_forest.score_samples(feature_scaler.transform(features))
    anomaly_normalization = fit_normalization(
        raw_anomaly[normal_indices], "-IsolationForest.score_samples(StandardScaler(features))"
    )
    anomaly_scores = normalize_scores(raw_anomaly, anomaly_normalization)
    risk_features = features.assign(anomaly_score=anomaly_scores).loc[:, RISK_FEATURE_NAMES]
    random_forest = RandomForestClassifier(
        n_estimators=160, max_depth=8, min_samples_leaf=8,
        random_state=RANDOM_SEED, n_jobs=1,
    )
    random_forest.fit(risk_features.iloc[train_indices], rpf.iloc[train_indices]["inspection_result"])

    sequence_scaler = StandardScaler().fit(sequence_features.iloc[normal_indices])
    scaled_sequences = sequence_scaler.transform(sequence_features)
    architecture = {"input_dim": 7, "hidden_dim": 12, "latent_dim": 3}
    autoencoder = Autoencoder(**architecture).to("cpu")
    inputs = torch.as_tensor(scaled_sequences[normal_indices], dtype=torch.float32, device="cpu")
    epochs, batch_size, learning_rate = 160, 64, 0.005
    optimizer = torch.optim.Adam(autoencoder.parameters(), lr=learning_rate, weight_decay=1e-5)
    autoencoder.train()
    for _ in range(epochs):
        permutation = torch.randperm(len(inputs))
        for indices in permutation.split(batch_size):
            batch = inputs[indices]
            optimizer.zero_grad()
            loss = torch.nn.functional.mse_loss(autoencoder(batch), batch)
            loss.backward()
            optimizer.step()
    errors = reconstruction_errors(autoencoder, scaled_sequences)
    sequence_normalization = fit_normalization(
        errors[normal_indices], "mean((autoencoder(standardized_sequence)-standardized_sequence)^2)"
    )
    sequence_scores = normalize_scores(errors, sequence_normalization)
    risk_scores = fail_probabilities(random_forest, risk_features.iloc[test_indices])
    fail_targets = rpf.iloc[test_indices]["inspection_result"].eq("fail").astype(int)
    normal_test = test_indices[rpf.iloc[test_indices]["grade"].eq("normal").to_numpy()]
    metrics = {
        "scope": "held-out synthetic data only; not real manufacturing performance",
        "random_forest": {
            "roc_auc": float(roc_auc_score(fail_targets, risk_scores)),
            "brier_score": float(brier_score_loss(fail_targets, risk_scores)),
        },
        "autoencoder": {
            "normal_train_mean_reconstruction_error": float(errors[normal_indices].mean()),
            "normal_test_mean_reconstruction_error": float(errors[normal_test].mean()),
        },
        "test_mean_scores_by_synthetic_grade": {},
    }
    for grade in ("normal", "review", "priority"):
        indices = test_indices[rpf.iloc[test_indices]["grade"].eq(grade).to_numpy()]
        metrics["test_mean_scores_by_synthetic_grade"][grade] = {
            "sample_count": len(indices),
            "anomaly_score": float(anomaly_scores[indices].mean()),
            "timeseries_anomaly_score": float(sequence_scores[indices].mean()),
        }

    metadata = {
        "schema_version": 1,
        "synthetic_data": True,
        "intended_use": "ML/DL analysis pipeline validation in notebooks only",
        "limitations": [SYNTHETIC_NOTICE,
            "Durations, grade regimes and inspection outcomes are invented, not measured.",
            "Synthetic grades are not the production event-based RPF grade rules.",
            "The autoencoder uses seven stage durations per product, not continuous sensor data.",
            "Train/test products share a synthetic generator; real-process generalization is untested."],
        "random_seed": RANDOM_SEED,
        "sample_count": len(rpf),
        "sequence_sample_count": len(sequences),
        "grade_distribution": {str(k): int(v) for k, v in rpf["grade"].value_counts().items()},
        "inspection_distribution": {str(k): int(v) for k, v in rpf["inspection_result"].value_counts().items()},
        "feature_names": FEATURE_NAMES,
        "random_forest_feature_names": RISK_FEATURE_NAMES,
        "sequence_feature_names": SEQUENCE_FEATURE_NAMES,
        "duration_unit": "milliseconds",
        "excluded_input_columns": ["product_id", "grade", "inspection_result"],
        "grade_usage": "normal subset selection, split stratification and evaluation grouping; never a feature",
        "inspection_result_usage": "Random Forest target and split stratification only; never a feature",
        "trained_at_utc": datetime.now(timezone.utc).isoformat(),
        "versions": {"python": platform.python_version(), "numpy": np.__version__,
                     "pandas": pd.__version__, "scipy": scipy.__version__, "sklearn": sklearn.__version__,
                     "joblib": joblib.__version__, "torch": str(torch.__version__)},
        "split": {
            "method": "sklearn.model_selection.train_test_split before any fitting",
            "unit": "product_id", "test_size": 0.2, "random_state": RANDOM_SEED,
            "stratify": ["grade", "inspection_result"],
            "train_count": len(train_indices), "test_count": len(test_indices),
            "normal_train_count": len(normal_indices), "normal_test_count": len(normal_test),
            "train_product_ids_sha256": hashlib.sha256(
                "\n".join(sorted(rpf.iloc[train_indices]["product_id"])).encode()
            ).hexdigest(),
            "test_product_ids_sha256": hashlib.sha256(
                "\n".join(sorted(rpf.iloc[test_indices]["product_id"])).encode()
            ).hexdigest(),
        },
        "data_sha256": {name: hashlib.sha256((data_dir / name).read_bytes()).hexdigest()
                        for name in ("rpf.csv", "rpf_sequences.csv")},
        "models": {
            "isolation_forest": {"type": "sklearn.ensemble.IsolationForest",
                                 "parameters": isolation_forest.get_params(),
                                 "fit_population": "normal training products only",
                                 "output": "anomaly_score",
                                 "meaning": "unusualness relative to normal process features"},
            "random_forest": {"type": "sklearn.ensemble.RandomForestClassifier",
                              "parameters": random_forest.get_params(),
                              "fit_population": "all training products",
                              "target": "inspection_result", "positive_class": "fail",
                              "classes": random_forest.classes_.tolist(),
                              "output": "inspection_risk_score",
                              "meaning": "uncalibrated synthetic inspection risk trial score"},
            "autoencoder": {"type": "torch MLP Autoencoder", "architecture": architecture,
                            "device": "cpu", "epochs": epochs, "batch_size": batch_size,
                            "optimizer": "Adam", "learning_rate": learning_rate,
                            "weight_decay": 1e-5, "loss": "MSE", "torch_num_threads": 1,
                            "fit_population": "normal training products only",
                            "output": "timeseries_anomaly_score",
                            "meaning": "difference from normal stage-duration patterns"},
        },
        "scalers": {
            "feature_scaler": {"type": "StandardScaler", "fit_population": "normal training products only"},
            "sequence_scaler": {"type": "StandardScaler", "fit_population": "normal training products only"},
        },
        "score_normalization": {
            "anomaly_score": anomaly_normalization,
            "timeseries_anomaly_score": sequence_normalization,
            "inspection_risk_score": {
                "method": "RandomForestClassifier.predict_proba column for class fail",
                "range": [0.0, 1.0], "synthetic_trial_score": True,
                "calibrated": False, "real_process_probability": False,
            },
        },
        "synthetic_test_metrics": metrics,
    }
    model_dir.mkdir(parents=True, exist_ok=True)
    for name, model in (("isolation_forest", isolation_forest), ("feature_scaler", feature_scaler),
                        ("random_forest", random_forest), ("sequence_scaler", sequence_scaler)):
        joblib.dump(model, model_dir / f"{name}.joblib", compress=3)
    torch.save({"architecture": architecture, "state_dict": autoencoder.state_dict()},
               model_dir / "autoencoder.pt")
    (model_dir / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")

    # Verify every held-out prediction through the same loader notebooks will use.
    expected = np.column_stack([anomaly_scores[test_indices], risk_scores, sequence_scores[test_indices]])
    reloaded = SyntheticModels(model_dir).predict(rpf.iloc[test_indices], sequences.iloc[test_indices])
    np.testing.assert_allclose(reloaded.to_numpy(), expected, rtol=1e-6, atol=1e-7)
    print("Saved/reloaded predictions match for all held-out synthetic products.")
    return metadata


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, default=DATA_DIR)
    parser.add_argument("--model-dir", type=Path, default=MODEL_DIR)
    args = parser.parse_args()
    print(SYNTHETIC_NOTICE, flush=True)
    metadata = train(args.data_dir, args.model_dir)
    print(json.dumps(metadata["synthetic_test_metrics"], indent=2))
    print(f"Saved to {args.model_dir}")
    for path in sorted(args.model_dir.iterdir()):
        if path.is_file():
            print(f"{path.name}: {path.stat().st_size:,} bytes")


if __name__ == "__main__":
    main()
