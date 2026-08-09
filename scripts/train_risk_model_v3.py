"""
v3 training for WildlifeAlert's on-device collision-risk model.

=============================================================================
WHAT THIS FIXES: LABEL LEAKAGE IN THE CORRIDOR FEATURES
=============================================================================
Two of the fifteen features are

    distance_to_nearest_corridor_m
    corridor_base_severity

In v2 these were computed from DBSCAN clusters built on the animal-collision
points of the WHOLE dataset — including the very rows being scored. A row
with label=1 therefore helped create the cluster whose distance was then fed
back in as a predictor of that same row's label. That is circular, and it
inflates the reported ROC AUC by an amount that had never been measured.

v3 measures it, three ways, and reports all of them side by side:

  leaky_random_split
      v2 reproduced exactly: clusters from ALL positives (including test
      rows), fixed eps=800 m, plain random 80/20 row split. This is the
      number the old pipeline published.

  crossfit_random_split
      Clusters rebuilt inside each fold from TRAIN-fold positives only, but
      folds are still random rows. This removes the "my own crash built my
      own corridor" leak. It does NOT remove spatial leakage: a different
      crash 50 m away can still be in the training fold.

  crossfit_spatial_cv          <-- THE HONEST HEADLINE NUMBER
      Whole geographic blocks (0.2 deg ~ 22 km) are held out as units, and
      each fold's corridor features are computed from that fold's training
      positives only. A scored point's own neighbourhood contributed nothing
      to the corridors it is measured against. This is what "does this model
      work somewhere it hasn't already memorised" actually means.

  nocorridor_random_split / nocorridor_spatial_cv
      Corridor features dropped entirely, so the honest contribution of the
      two features (rather than of the leak) can be read off directly.

A LOWER honest number than v2's 0.8671 is the correct outcome, and no
hyperparameter was changed to soften it. The estimator is byte-identical to
v2's: GradientBoostingClassifier(n_estimators=150, max_depth=3,
learning_rate=0.1, random_state=42), so every difference below is
attributable to the evaluation fix and the data change, not to tuning.

=============================================================================
WHICH MODEL IS ACTUALLY EXPORTED
=============================================================================
The exported model is fit on OUT-OF-FOLD corridor features from the spatial
CV, not on full-data corridor features. Reason: if the final model is fit on
corridor features that were built with the training rows' own labels, the
leak is baked into the MODEL's learned weights, not just into the metric —
it would learn "distance ~ 0 implies animal collision" far more strongly
than is true for a location it has never seen. Fitting on out-of-fold
features means the learned relationship holds under the condition that
actually applies in the app: a driver's current position did not contribute
to the shipped corridor set.

Residual mismatch, stated plainly: at inference the app measures distance
against the FULL shipped hotspot set, which is denser than any single
training fold's set, so real-world distances will run slightly shorter than
the ones the model was fit on. This biases the model slightly conservative
(it will under- rather than over-react to corridor proximity). It is not
corrected for, because correcting it would require re-introducing the leak.

See wildlife_data_v3.py for full per-state data provenance.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.metrics import accuracy_score, average_precision_score, roc_auc_score
from sklearn.model_selection import StratifiedGroupKFold, train_test_split
from sklearn.neighbors import BallTree

from cluster_hotspots_v3 import MIN_SAMPLES, cluster_centroids, tune_eps_meters
from wildlife_data_v3 import (
    EARTH_RADIUS_M, OUTPUT_DIR, ROAD_CLASSES, STATE_SOURCES, WEATHER_CLASSES,
    available_states, load_state,
)

RANDOM_SEED = 42
NEG_PER_POS = 2
N_SPLITS = 5
BLOCK_DEG = 0.2                 # ~22 km spatial holdout blocks
V2_FIXED_EPS_M = 800.0          # what v2 used for every state
NO_CLUSTER_DISTANCE_M = 1_000_000.0

FEATURE_NAMES = [
    "hour_of_day", "month",
    "distance_to_nearest_corridor_m", "corridor_base_severity",
    "weather_condition_clear", "weather_condition_cloudy",
    "weather_condition_fog", "weather_condition_rain", "weather_condition_snow",
    "species_Deer", "species_Elk", "species_Moose",
    "road_type_highway", "road_type_residential", "road_type_rural",
]
CORRIDOR_COLS = [2, 3]
NON_CORRIDOR_COLS = [i for i in range(len(FEATURE_NAMES)) if i not in CORRIDOR_COLS]


def new_estimator() -> GradientBoostingClassifier:
    """Identical to v2. Deliberately not tuned."""
    return GradientBoostingClassifier(
        n_estimators=150, max_depth=3, learning_rate=0.1, random_state=RANDOM_SEED)


# --------------------------------------------------------------------------
# Sample assembly
# --------------------------------------------------------------------------
def build_sample(states: list[str]):
    lon, lat, hour, month, weather, road, label, state_idx = ([] for _ in range(8))
    for si, st in enumerate(states):
        rec, _ = load_state(st)
        lon.append(rec["lon"]); lat.append(rec["lat"])
        hour.append(rec["hour"]); month.append(rec["month"])
        weather.append(rec["weather"]); road.append(rec["road"])
        label.append(rec["label"])
        state_idx.append(np.full(len(rec), si, dtype=np.int16))
    d = dict(
        lon=np.concatenate(lon), lat=np.concatenate(lat),
        hour=np.concatenate(hour), month=np.concatenate(month),
        weather=np.concatenate(weather), road=np.concatenate(road),
        label=np.concatenate(label).astype(np.int8),
        state=np.concatenate(state_idx),
    )

    rng = np.random.default_rng(RANDOM_SEED)
    pos = np.flatnonzero(d["label"] == 1)
    neg = np.flatnonzero(d["label"] == 0)
    rng.shuffle(neg)
    keep = np.concatenate([pos, neg[: len(pos) * NEG_PER_POS]])
    rng.shuffle(keep)
    return {k: v[keep] for k, v in d.items()}


def base_matrix(s: dict) -> np.ndarray:
    """The thirteen non-corridor features, in the exact order RiskMLModel.swift
    passes them (corridor columns are filled in separately)."""
    n = len(s["label"])
    X = np.zeros((n, len(FEATURE_NAMES)), dtype=np.float64)
    X[:, 0] = s["hour"]
    X[:, 1] = s["month"]
    for i, w in enumerate(WEATHER_CLASSES):          # clear cloudy fog rain snow
        X[:, 4 + i] = (s["weather"] == i)
    X[:, 9] = 1.0                                    # species_Deer
    # species_Elk (10) and species_Moose (11) stay 0 for every training row —
    # no state in the dataset records elk or moose. See limitations.
    road_col = {"highway": 12, "residential": 13, "rural": 14}
    for i, r in enumerate(ROAD_CLASSES):
        X[:, road_col[r]] = (s["road"] == i)
    return X


def spatial_blocks(s: dict) -> np.ndarray:
    by = np.floor(s["lat"] / BLOCK_DEG).astype(np.int64)
    bx = np.floor(s["lon"] / BLOCK_DEG).astype(np.int64)
    return (s["state"].astype(np.int64) * 10_000_000
            + (by + 1000) * 10_000 + (bx + 2000))


# --------------------------------------------------------------------------
# Corridor features
# --------------------------------------------------------------------------
def fit_corridors(s: dict, fit_idx: np.ndarray, states: list[str],
                  eps_by_state: dict, severity_rescale: bool = True) -> dict:
    """Builds per-state corridor clusters using ONLY the rows in fit_idx."""
    out = {}
    for si, st in enumerate(states):
        in_state = s["state"] == si
        pos_all = np.flatnonzero(in_state & (s["label"] == 1))
        m = np.zeros(len(s["label"]), dtype=bool)
        m[fit_idx] = True
        pos_fit = np.flatnonzero(in_state & (s["label"] == 1) & m)
        if len(pos_fit) < MIN_SAMPLES:
            out[si] = (None, None)
            continue
        lonlat = np.column_stack([s["lon"][pos_fit], s["lat"][pos_fit]])
        cent, counts = cluster_centroids(lonlat, eps_by_state[st], MIN_SAMPLES)
        if len(cent) == 0:
            out[si] = (None, None)
            continue
        sev = counts.astype(np.float64)
        if severity_rescale:
            # A fold sees only ~(k-1)/k of the positives, so its cluster counts
            # are systematically smaller than the full-data counts the app will
            # ship. Rescale so severity means the same thing in every fold.
            sev = sev * (len(pos_all) / max(len(pos_fit), 1))
        tree = BallTree(np.radians(cent[:, ::-1]), metric="haversine")
        out[si] = (tree, sev)
    return out


def apply_corridors(s: dict, idx: np.ndarray, corridors: dict, X: np.ndarray) -> None:
    """Writes distance / severity into X rows `idx` in place."""
    for si, (tree, sev) in corridors.items():
        rows = idx[s["state"][idx] == si]
        if len(rows) == 0:
            continue
        if tree is None:
            X[rows, 2] = NO_CLUSTER_DISTANCE_M
            X[rows, 3] = 0.0
            continue
        q = np.radians(np.column_stack([s["lat"][rows], s["lon"][rows]]))
        dist, ind = tree.query(q, k=1)
        X[rows, 2] = dist[:, 0] * EARTH_RADIUS_M
        X[rows, 3] = sev[ind[:, 0]]


# --------------------------------------------------------------------------
# Evaluations
# --------------------------------------------------------------------------
def _scores(y, pred, prob):
    return {
        "accuracy": float(accuracy_score(y, pred)),
        "roc_auc": float(roc_auc_score(y, prob)),
        "average_precision": float(average_precision_score(y, prob)),
    }


def eval_single_split(X: np.ndarray, y: np.ndarray, cols: list[int]):
    Xtr, Xte, ytr, yte = train_test_split(
        X[:, cols], y, test_size=0.2, random_state=RANDOM_SEED, stratify=y)
    clf = new_estimator().fit(Xtr, ytr)
    prob = clf.predict_proba(Xte)[:, 1]
    r = _scores(yte, clf.predict(Xte), prob)
    r.update(n_train=int(len(ytr)), n_test=int(len(yte)))
    return r


def eval_cv(s: dict, X_base: np.ndarray, states: list[str], eps_by_state: dict,
            groups: np.ndarray, use_corridor: bool, refit_corridors: bool,
            label: str):
    """Cross-validated evaluation. When refit_corridors is True the corridor
    columns are rebuilt inside every fold from that fold's training rows only.
    Returns pooled out-of-fold scores plus the out-of-fold feature matrix."""
    y = s["label"].astype(int)
    X = X_base.copy()
    oof_prob = np.zeros(len(y))
    oof_X = X_base.copy()
    cv = StratifiedGroupKFold(n_splits=N_SPLITS, shuffle=True, random_state=RANDOM_SEED)
    fold_scores = []
    for f, (tr, te) in enumerate(cv.split(X, y, groups=groups)):
        if use_corridor and refit_corridors:
            corr = fit_corridors(s, tr, states, eps_by_state)
            apply_corridors(s, tr, corr, X)
            apply_corridors(s, te, corr, X)
            oof_X[te, 2] = X[te, 2]
            oof_X[te, 3] = X[te, 3]
        cols = list(range(len(FEATURE_NAMES))) if use_corridor else NON_CORRIDOR_COLS
        clf = new_estimator().fit(X[np.ix_(tr, cols)], y[tr])
        p = clf.predict_proba(X[np.ix_(te, cols)])[:, 1]
        oof_prob[te] = p
        fold_scores.append(_scores(y[te], (p >= 0.5).astype(int), p))
        print(f"    [{label}] fold {f+1}/{N_SPLITS} "
              f"auc={fold_scores[-1]['roc_auc']:.4f} n_test={len(te)}", flush=True)
    pooled = _scores(y, (oof_prob >= 0.5).astype(int), oof_prob)
    pooled["fold_roc_auc"] = [round(fs["roc_auc"], 4) for fs in fold_scores]
    pooled["roc_auc_fold_std"] = float(np.std([fs["roc_auc"] for fs in fold_scores]))
    pooled["n_evaluated"] = int(len(y))
    per_state = {}
    for si, st in enumerate(states):
        m = s["state"] == si
        if m.sum() > 100 and len(np.unique(y[m])) == 2:
            per_state[st] = {
                "roc_auc": float(roc_auc_score(y[m], oof_prob[m])),
                "n": int(m.sum()),
            }
    pooled["per_state_roc_auc"] = per_state
    return pooled, oof_X, oof_prob


# --------------------------------------------------------------------------
def run(states: list[str], do_export_artifacts: bool):
    print(f"\n{'='*72}\nSTATES: {', '.join(states)}\n{'='*72}")
    s = build_sample(states)
    y = s["label"].astype(int)
    print(f"Balanced sample: {len(y):,} rows "
          f"({int(y.sum()):,} animal / {int((1-y).sum()):,} non-animal)")

    eps_by_state = {}
    for si, st in enumerate(states):
        pos = np.flatnonzero((s["state"] == si) & (s["label"] == 1))
        lonlat = np.column_stack([s["lon"][pos], s["lat"][pos]])
        t = tune_eps_meters(lonlat)
        eps_by_state[st] = t["eps_m"]
        print(f"  {st}: tuned eps {t['eps_m']:.0f} m over {len(pos):,} positives")

    X_base = base_matrix(s)
    groups = spatial_blocks(s)
    print(f"Spatial holdout blocks ({BLOCK_DEG} deg): {len(np.unique(groups)):,}")

    results = {}
    all_idx = np.arange(len(y))

    # --- v2 reproduction: leaky corridors, fixed eps, random split -----------
    print("\n[1/5] leaky_random_split (v2 reproduction)")
    Xl = X_base.copy()
    corr_leaky = fit_corridors(s, all_idx, states,
                               {st: V2_FIXED_EPS_M for st in states},
                               severity_rescale=False)
    apply_corridors(s, all_idx, corr_leaky, Xl)
    results["leaky_random_split"] = eval_single_split(
        Xl, y, list(range(len(FEATURE_NAMES))))
    print("   ", results["leaky_random_split"])

    # --- corridor features removed, random split ----------------------------
    print("\n[2/5] nocorridor_random_split")
    results["nocorridor_random_split"] = eval_single_split(X_base, y, NON_CORRIDOR_COLS)
    print("   ", results["nocorridor_random_split"])

    # --- cross-fitted corridors, still a random split -----------------------
    print("\n[3/5] crossfit_random_split")
    Xc = X_base.copy()
    tr, te = train_test_split(all_idx, test_size=0.2, random_state=RANDOM_SEED, stratify=y)
    corr_cf = fit_corridors(s, tr, states, eps_by_state)
    apply_corridors(s, tr, corr_cf, Xc)
    apply_corridors(s, te, corr_cf, Xc)
    clf = new_estimator().fit(Xc[tr], y[tr])
    p = clf.predict_proba(Xc[te])[:, 1]
    results["crossfit_random_split"] = _scores(y[te], (p >= 0.5).astype(int), p)
    results["crossfit_random_split"].update(n_train=int(len(tr)), n_test=int(len(te)))
    print("   ", results["crossfit_random_split"])

    # --- THE HONEST NUMBER: cross-fitted corridors + spatial block CV --------
    print("\n[4/5] crossfit_spatial_cv  <-- honest headline")
    pooled, oof_X, _ = eval_cv(s, X_base, states, eps_by_state, groups,
                               use_corridor=True, refit_corridors=True,
                               label="crossfit_spatial_cv")
    results["crossfit_spatial_cv"] = pooled
    print("   ", {k: v for k, v in pooled.items() if k != "per_state_roc_auc"})

    # --- corridor features removed, spatial CV ------------------------------
    print("\n[5/5] nocorridor_spatial_cv")
    pooled_nc, _, _ = eval_cv(s, X_base, states, eps_by_state, groups,
                              use_corridor=False, refit_corridors=False,
                              label="nocorridor_spatial_cv")
    results["nocorridor_spatial_cv"] = pooled_nc
    print("   ", {k: v for k, v in pooled_nc.items() if k != "per_state_roc_auc"})

    payload = {
        "states": states,
        "sample_rows": int(len(y)),
        "positive_rows": int(y.sum()),
        "tuned_eps_m_by_state": eps_by_state,
        "spatial_block_degrees": BLOCK_DEG,
        "n_spatial_blocks": int(len(np.unique(groups))),
        "evaluations": results,
    }

    if do_export_artifacts:
        print("\nFitting FINAL exportable model on out-of-fold corridor features ...")
        final = new_estimator().fit(oof_X, y)
        import joblib
        joblib.dump(final, OUTPUT_DIR / "gbm_model_v3.joblib")
        (OUTPUT_DIR / "feature_names_v3.json").write_text(json.dumps(FEATURE_NAMES))
        payload["final_model_feature_importances"] = {
            n: round(float(v), 5) for n, v in
            sorted(zip(FEATURE_NAMES, final.feature_importances_),
                   key=lambda kv: -kv[1])
        }
        print(f"Wrote {OUTPUT_DIR / 'gbm_model_v3.joblib'}")
    return payload


def main():
    states_all = available_states()
    v2_states = ["IA", "IL", "VA"]
    three = [st for st in states_all if st in v2_states]

    # Apples-to-apples first: EXACTLY the three states v2 used (IA/IL/VA), so
    # the leakage delta is not confounded with the new states (MA, TN) added
    # in this pass. Filtering by "not MA" alone would leave TN in this list
    # once TN became available — this must be an explicit allow-list, not a
    # deny-list, to stay correct as more states are added later.
    same_states = run(three, do_export_artifacts=False)
    # Then the actual v3 dataset.
    full = run(states_all, do_export_artifacts=True)

    hl = full["evaluations"]["crossfit_spatial_cv"]
    old = same_states["evaluations"]["leaky_random_split"]

    out = {
        "headline": {
            "honest_roc_auc": round(hl["roc_auc"], 4),
            "honest_accuracy": round(hl["accuracy"], 4),
            "honest_average_precision": round(hl["average_precision"], 4),
            "evaluation": "crossfit_spatial_cv",
            "v2_published_roc_auc": 0.8671254159213179,
            "v2_reproduced_roc_auc_same_3_states": round(old["roc_auc"], 4),
        },
        "comparison_same_3_states_IA_IL_VA": same_states,
        "v3_full_dataset": full,
        "per_state_provenance": {st: STATE_SOURCES[st] for st in states_all},
        "feature_names": FEATURE_NAMES,
    }
    (OUTPUT_DIR / "training_evaluations_v3.json").write_text(json.dumps(out, indent=2))
    print(f"\nWrote {OUTPUT_DIR / 'training_evaluations_v3.json'}")


if __name__ == "__main__":
    sys.exit(main())
