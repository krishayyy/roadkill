"""
Exports the GradientBoostingClassifier trained by train_risk_model.py (on
REAL Iowa DOT animal-vehicle-collision data — see that script's docstring
for full provenance) to a CoreML .mlpackage.

Writes to WildlifeRiskModel_v2.mlpackage, a NEW file alongside the existing
shipped WildlifeRiskModel.mlpackage. This script intentionally does NOT
overwrite the live model — swapping RiskMLModel.swift over to the new file
(or renaming it into place) is a separate, explicit step so the live app
isn't silently repointed at a differently-scoped model.
"""

import json
from pathlib import Path

import joblib
import coremltools as ct

SCRATCH = Path(__file__).resolve().parent.parent / "scratchpad_data"
OUT_DIR = Path(__file__).resolve().parent.parent / "WildlifeAlert"


def main():
    clf = joblib.load(SCRATCH / "gbm_model.joblib")
    feature_names = json.loads((SCRATCH / "feature_names.json").read_text())

    model = ct.converters.sklearn.convert(
        clf,
        input_features=feature_names,
        output_feature_names="risk_label",
    )

    metrics = json.loads((SCRATCH / "training_metrics.json").read_text())
    model.short_description = (
        "WildlifeAlert collision-risk classifier, GradientBoostingClassifier, "
        f"trained on REAL data: {metrics['source_dataset']} "
        f"({metrics['animal_collision_records']} real animal-collision records "
        f"of {metrics['total_raw_records']} total crash records). "
        f"Test accuracy={metrics['accuracy']:.3f}, ROC AUC={metrics['roc_auc']:.3f}. "
        "Iowa-only real data; NOT California-specific. See train_risk_model.py "
        "for full provenance and known limitations (no species field, "
        "inferred road type, corridor features derived from same dataset)."
    )
    model.version = "2.0-real-iowa"

    out_path = OUT_DIR / "WildlifeRiskModel_v2.mlpackage"
    model.save(str(out_path))
    print(f"Wrote {out_path}")


if __name__ == "__main__":
    main()
