"""
Exports the v3 GradientBoostingClassifier (train_risk_model_v3.py — leakage
fixed, trained on out-of-fold corridor features, combined real data from IA,
IL, VA, MA, TN) to a NEW CoreML .mlpackage.

Writes to WildlifeAlert/WildlifeRiskModel_v3.mlpackage. Does NOT touch the
live WildlifeRiskModel.mlpackage or any other existing .mlpackage — swapping
the live model is an explicit, separate, human-performed step (per this
project's ownership rules, that swap belongs to the coordinator, not this
script).

Input schema is BYTE-IDENTICAL to v2's (same 15 feature names, same order —
see FEATURE_NAMES in train_risk_model_v3.py), so RiskMLModel.swift's
WildlifeRiskModelInput fields need NOT change if this model is swapped in.
"""

import json
from pathlib import Path

import joblib
import coremltools as ct

SCRATCH = Path(__file__).resolve().parent.parent / "scratchpad_data"
OUT_DIR = Path(__file__).resolve().parent.parent / "WildlifeAlert"


def main():
    clf = joblib.load(SCRATCH / "gbm_model_v3.joblib")
    feature_names = json.loads((SCRATCH / "feature_names_v3.json").read_text())
    evals = json.loads((SCRATCH / "training_evaluations_v3.json").read_text())
    headline = evals["headline"]

    model = ct.converters.sklearn.convert(
        clf,
        input_features=feature_names,
        output_feature_names="risk_label",
    )

    states = evals["v3_full_dataset"]["states"]
    model.short_description = (
        "WildlifeAlert collision-risk classifier v3, GradientBoostingClassifier, "
        f"trained on REAL combined multi-state data: {', '.join(states)}. "
        f"HONEST held-out metric (crossfit_spatial_cv, whole geographic blocks "
        f"held out, corridor features rebuilt per-fold from training data only): "
        f"ROC AUC={headline['honest_roc_auc']:.4f}, accuracy={headline['honest_accuracy']:.4f}. "
        f"For comparison, the v2 pipeline reported ROC AUC={headline['v2_published_roc_auc']:.4f} "
        f"using corridor features computed with label leakage (clusters built from "
        f"the same rows being scored) and a plain random row split; reproducing "
        f"that exact leaky setup on the SAME 3 states (IA/IL/VA) gives "
        f"{headline['v2_reproduced_roc_auc_same_3_states']:.4f} here, confirming "
        f"leakage — not new data or a different model — explains most of the gap. "
        f"See scripts/train_risk_model_v3.py and scratchpad_data/"
        f"training_evaluations_v3.json for the full 5-way evaluation and every "
        f"documented limitation."
    )
    model.version = "3.0-real-multistate-leakage-fixed-ia-il-va-ma-tn"

    out_path = OUT_DIR / "WildlifeRiskModel_v3.mlpackage"
    model.save(str(out_path))
    print(f"Wrote {out_path}")
    print(f"Feature schema ({len(feature_names)} features, same order as v2): {feature_names}")


if __name__ == "__main__":
    main()
