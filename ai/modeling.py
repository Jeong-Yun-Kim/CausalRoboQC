"""Notebook helpers for synthetic-only ML/DL pipeline experiments."""

import json
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
import torch
from torch import nn


ROOT = Path(__file__).resolve().parents[1]
DATA_DIR = ROOT / "data" / "synthetic"
MODEL_DIR = ROOT / "ai" / "models"
RANDOM_SEED = 42
FEATURE_NAMES = [
    "work_time_ms", "retry_count", "error_count", "operator_interventions"
]
SEQUENCE_FEATURE_NAMES = [
    "HOME", "PICK_ABOVE", "PICK", "GRAB", "LIFT", "PLACE", "RELEASE"
]
RISK_FEATURE_NAMES = FEATURE_NAMES + ["anomaly_score"]
SCORE_NAMES = [
    "anomaly_score", "inspection_risk_score", "timeseries_anomaly_score"
]
SYNTHETIC_NOTICE = (
    "SYNTHETIC DATA ONLY: pipeline validation, not real manufacturing performance. "
    "Anomaly scores are not defect probabilities; inspection risk is an "
    "uncalibrated synthetic-data trial score."
)


class Autoencoder(nn.Module):
    """Small CPU-compatible 7 -> 12 -> 3 -> 12 -> 7 autoencoder."""

    def __init__(self, input_dim: int = 7, hidden_dim: int = 12, latent_dim: int = 3):
        super().__init__()
        self.network = nn.Sequential(
            nn.Linear(input_dim, hidden_dim),
            nn.ReLU(),
            nn.Linear(hidden_dim, latent_dim),
            nn.ReLU(),
            nn.Linear(latent_dim, hidden_dim),
            nn.ReLU(),
            nn.Linear(hidden_dim, input_dim),
        )

    def forward(self, values: torch.Tensor) -> torch.Tensor:
        return self.network(values)


def numeric_features(frame: pd.DataFrame, names: list[str]) -> pd.DataFrame:
    """Select an explicit feature allowlist; labels and IDs never enter models."""
    missing = set(names) - set(frame.columns)
    if missing:
        raise ValueError(f"Missing features: {sorted(missing)}")
    values = frame.loc[:, names].astype(float)
    if values.empty or not np.isfinite(values.to_numpy()).all():
        raise ValueError("Features must be nonempty, finite numeric values")
    if (values.to_numpy() < 0).any():
        raise ValueError("Durations and counts must be nonnegative")
    for name in ("retry_count", "error_count", "operator_interventions"):
        if name in values and (values[name] % 1 != 0).any():
            raise ValueError(f"{name} must contain integer counts")
    return values


def align_sequences(rpf: pd.DataFrame, sequences: pd.DataFrame) -> pd.DataFrame:
    """Join by product ID when supplied, otherwise use positional notebook rows."""
    if len(rpf) != len(sequences):
        raise ValueError("RPF and sequence sample counts differ")
    has_ids = ["product_id" in frame for frame in (rpf, sequences)]
    if any(has_ids) and not all(has_ids):
        raise ValueError("Provide product_id in both frames or neither")
    if all(has_ids):
        for frame in (rpf, sequences):
            if frame["product_id"].isna().any() or not frame["product_id"].is_unique:
                raise ValueError("product_id must be nonempty and unique")
        if set(rpf["product_id"]) != set(sequences["product_id"]):
            raise ValueError("RPF and sequence product IDs differ")
        return sequences.set_index("product_id").loc[rpf["product_id"]].reset_index()
    return sequences.reset_index(drop=True)


def fit_normalization(normal_raw_scores: np.ndarray, raw_definition: str) -> dict:
    """Use normal training scores only; the normal 99th percentile maps to 0.5."""
    lower, reference = np.quantile(normal_raw_scores, [0.05, 0.99])
    return {
        "method": "bounded_excess_ratio",
        "raw_score": raw_definition,
        "fit_population": "grade == normal in training partition only",
        "lower_quantile": 0.05,
        "reference_quantile": 0.99,
        "lower": float(lower),
        "reference": float(reference),
        "scale": float(max(reference - lower, 1e-12)),
        "formula": "excess=max(raw-lower,0); score=excess/(excess+scale)",
        "range": [0.0, 1.0],
        "interpretation": "0 at/below normal p05; 0.5 at normal p99; tends to 1",
        "is_defect_probability": False,
    }


def normalize_scores(raw_scores: np.ndarray, parameters: dict) -> np.ndarray:
    excess = np.maximum(np.asarray(raw_scores, dtype=float) - parameters["lower"], 0)
    return np.clip(excess / (excess + parameters["scale"]), 0.0, 1.0)


def reconstruction_errors(model: Autoencoder, scaled_sequences: np.ndarray) -> np.ndarray:
    model.eval()
    with torch.inference_mode():
        inputs = torch.as_tensor(scaled_sequences, dtype=torch.float32, device="cpu")
        return ((model(inputs) - inputs) ** 2).mean(dim=1).numpy()


def fail_probabilities(model, features: pd.DataFrame) -> np.ndarray:
    """Locate fail explicitly rather than assuming predict_proba column order."""
    fail_index = list(model.classes_).index("fail")
    return model.predict_proba(features)[:, fail_index]


class SyntheticModels:
    """Load trusted local artifacts once, then predict from notebook DataFrames."""

    def __init__(self, model_dir: Path = MODEL_DIR):
        model_dir = Path(model_dir)
        self.metadata = json.loads((model_dir / "metadata.json").read_text(encoding="utf-8"))
        if self.metadata.get("synthetic_data") is not True:
            raise ValueError("This loader expects synthetic trial artifacts")
        if self.metadata["feature_names"] != FEATURE_NAMES:
            raise ValueError("Artifact RPF feature order differs from this code")
        if self.metadata["sequence_feature_names"] != SEQUENCE_FEATURE_NAMES:
            raise ValueError("Artifact sequence order differs from this code")
        self.feature_scaler = joblib.load(model_dir / "feature_scaler.joblib")
        self.isolation_forest = joblib.load(model_dir / "isolation_forest.joblib")
        self.random_forest = joblib.load(model_dir / "random_forest.joblib")
        self.sequence_scaler = joblib.load(model_dir / "sequence_scaler.joblib")
        checkpoint = torch.load(model_dir / "autoencoder.pt", map_location="cpu", weights_only=True)
        self.autoencoder = Autoencoder(**checkpoint["architecture"])
        self.autoencoder.load_state_dict(checkpoint["state_dict"])
        self.autoencoder.eval()

    def predict(self, rpf: pd.DataFrame, sequences: pd.DataFrame) -> pd.DataFrame:
        sequences = align_sequences(rpf, sequences)
        features = numeric_features(rpf, FEATURE_NAMES)
        sequence_features = numeric_features(sequences, SEQUENCE_FEATURE_NAMES)
        normalization = self.metadata["score_normalization"]
        raw_anomaly = -self.isolation_forest.score_samples(self.feature_scaler.transform(features))
        anomaly = normalize_scores(raw_anomaly, normalization["anomaly_score"])
        risk_features = features.assign(anomaly_score=anomaly).loc[:, RISK_FEATURE_NAMES]
        errors = reconstruction_errors(self.autoencoder, self.sequence_scaler.transform(sequence_features))
        return pd.DataFrame({
            "anomaly_score": anomaly,
            "inspection_risk_score": fail_probabilities(self.random_forest, risk_features),
            "timeseries_anomaly_score": normalize_scores(errors, normalization["timeseries_anomaly_score"]),
        }, index=rpf.index)
