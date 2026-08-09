"""
Exports the GradientBoostingClassifier trained by train_risk_model_multistate.py
(on REAL combined Iowa + Illinois + Virginia animal-vehicle-collision data —
see that script's docstring for full per-state provenance) to a CoreML
.mlpackage.

Writes to WildlifeRiskModel_multistate.mlpackage, a NEW file. This script
does NOT touch the existing live WildlifeRiskModel.mlpackage or the
Iowa-only WildlifeRiskModel_v2.mlpackage — swapping the live model over is a
separate, explicit, human-performed step.
"""

import json
from pathlib import Path

import joblib
import coremltools as ct

SCRATCH = Path(__file__).resolve().parent.parent / "scratchpad_data"
OUT_DIR = Path(__file__).resolve().parent.parent / "WildlifeAlert"


def main():
    clf = joblib.load(SCRATCH / "gbm_model_multistate.joblib")
    feature_names = json.loads((SCRATCH / "feature_names_multistate.json").read_text())

    model = ct.converters.sklearn.convert(
        clf,
        input_features=feature_names,
        output_feature_names="risk_label",
    )

    metrics = json.loads((SCRATCH / "training_metrics_multistate.json").read_text())
    model.short_description = (
        "WildlifeAlert collision-risk classifier, GradientBoostingClassifier, "
        f"trained on REAL combined multi-state data: {', '.join(metrics['states_included'])} "
        f"({metrics['total_animal_collision_records_combined']} real animal-collision records "
        f"of {metrics['total_raw_records_combined']} total crash records). "
        f"Test accuracy={metrics['accuracy']:.3f}, ROC AUC={metrics['roc_auc']:.3f}. "
        "See train_risk_model_multistate.py for full per-state provenance, which "
        "states were checked and excluded, and known limitations (no species "
        "field in any state, per-state road-type heuristics, per-state corridor "
        "clustering)."
    )
    model.version = "3.0-real-multistate-ia-il-va"

    out_path = OUT_DIR / "WildlifeRiskModel_multistate.mlpackage"
    model.save(str(out_path))
    print(f"Wrote {out_path}")


if __name__ == "__main__":
    main()
