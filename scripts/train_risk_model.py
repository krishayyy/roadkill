"""
Trains WildlifeAlert's on-device collision-risk model on REAL crash data.

=============================================================================
DATA PROVENANCE (read this before trusting the metrics below)
=============================================================================
Source: Iowa DOT "Crash Data (SOR)" open dataset.
  Landing page: https://public-iowadot.opendata.arcgis.com/datasets/IowaDOT::crash-data-sor
  Bulk CSV endpoint actually used (public, no login, no API key):
    https://public-iowadot.opendata.arcgis.com/api/download/v1/items/7a1f786d55a2439a9bfa8f7a527936e8/csv?layers=0
  License: CC-BY 4.0. Downloaded 2026-08-09.
  Raw file: 608,017 crash records, statewide Iowa, roughly the prior 10
  years of reported crashes (issued 2021-06-24, continuously updated).
  Of those, 85,510 records (14.1%) are coded as animal-related, via either
    MAJCSE == 1  ("Major Cause: Animal"), or
    FRSTHARM == 31 ("First Harmful Event: Collision with Animal")
  per the official code table (Crash_Data.xlsx, sheets MajorCause/FirstHarm,
  fetched from https://cloud.iowadot.gov/gis/data/metadata/crash/Crash_Data.xlsx).

WHY IOWA, NOT CALIFORNIA:
  The original ask was California-specific (CROS roadkill observations,
  SWITRS crash data). Both were checked and found NOT bulk-downloadable in
  practice at the time of writing:
    - CROS (wildlifecrossing.net/california): the public site exposes a map
      and a "Note on Data" page, but bulk export of the underlying
      observation table requires a registered account
      ("access/download your entire set of observations" — i.e. login-
      gated). No anonymous bulk CSV/API endpoint was found.
    - SWITRS: CHP's SWITRS application is not a self-service bulk-download
      portal; data.ca.gov does not host a raw SWITRS animal-collision
      extract. Third-party mirrors exist (e.g. a Kaggle SWITRS dump), but
      those are not the primary source and their provenance/currency
      couldn't be independently verified here.
  Iowa DOT's ArcGIS Hub, by contrast, publishes a DCAT feed
  (public-iowadot.opendata.arcgis.com/api/feed/dcat-us/1.1.json) with a
  directly fetchable, unauthenticated CSV distribution — verified by
  actually downloading it (this script's input file). Per the project's
  "don't invent stats you can't defend" rule, this script is honest that
  the shipped model is trained on REAL Iowa animal-vehicle-collision data,
  not California data, and the app's hotspot/species framing should be
  read accordingly. If/when a genuine bulk CA export becomes available,
  swap DATA_PATH and rerun — the pipeline below is state-agnostic.

KNOWN LIMITATIONS (do not overstate what this model knows):
  - No species field: Iowa's SOR schema does not record animal species.
    Iowa's own DOT literature and national FARS data both point to
    white-tailed deer as the overwhelming majority of animal-vehicle
    crashes in Iowa's climate/geography, so all positive examples are
    labeled species="Deer" here. This is a documented assumption, not a
    measurement — the model has no ability to distinguish Deer/Elk/Moose
    and effectively degenerates to a single-species model.
  - Road type is inferred, not measured: derived from the free-text
    SYSTEMSTR route-name field (e.g. "I-80" / "US 6" -> highway; numbered
    county roads -> rural; anything else, including blank/not-reported ->
    residential fallback) rather than an authoritative road-classification
    join. This is a coarse simplification.
  - Weather is the crash-time weather actually recorded by the reporting
    officer (WEATHER code), not a separately joined historical-weather
    API, so no back-fill/estimation was needed here.
  - "corridor_base_severity" and "distance_to_nearest_corridor_m" are
    derived FROM this same real dataset (DBSCAN clusters of animal-crash
    points; severity = crash count in a point's cluster; distance =
    haversine distance to that cluster's centroid), not independently
    sourced ground truth about wildlife corridors. See cluster_hotspots.py
    for the clustering step that also produces the Firestore hotspot
    candidates.
  - This is Iowa-only. It says nothing calibrated about California,
    despite the app's UI referencing California hotspots — those hotspots
    are seeded from whatever real per-state data was actually obtained
    (see hotspot_candidates.json for exactly which state(s) that covers).

Model: GradientBoostingClassifier (matches the algorithm family described
in RiskMLModel.swift's doc comments for the previous synthetic model).
"""

import csv
import json
import math
import os
import random
from pathlib import Path

from sklearn.ensemble import GradientBoostingClassifier
from sklearn.model_selection import train_test_split
from sklearn.metrics import accuracy_score, roc_auc_score

SCRIPT_DIR = Path(__file__).resolve().parent

# The raw 194MB Iowa DOT CSV is a downloaded third-party dataset, not source
# code — it is intentionally NOT checked into this repo. Set
# WILDLIFEALERT_CRASH_CSV to point at wherever you downloaded it (see the
# module docstring above for the exact bulk-download URL used), or leave it
# at the default local path used during development.
DATA_PATH = Path(os.environ.get(
    "WILDLIFEALERT_CRASH_CSV",
    "/private/tmp/claude-501/-Users-krishay/7ec306c8-56c7-4f9b-b533-c9639a7ead4d/scratchpad/wildlife_data/iowa_crash_sor.csv",
))
OUTPUT_DIR = SCRIPT_DIR.parent / "scratchpad_data"
OUTPUT_DIR.mkdir(exist_ok=True)

WEB_MERCATOR_R = 6378137.0


def web_mercator_to_lonlat(x: float, y: float) -> tuple[float, float]:
    """Iowa DOT's X/Y columns are EPSG:3857 (Web Mercator) meters, not raw
    lon/lat degrees (confirmed by inspecting raw values — e.g. X ~
    -10198423, well outside any lon/lat range). Converts to WGS84 degrees."""
    lon = (x / WEB_MERCATOR_R) * (180.0 / math.pi)
    lat = (2 * math.atan(math.exp(y / WEB_MERCATOR_R)) - math.pi / 2) * (180.0 / math.pi)
    return lon, lat


WEATHER_MAP = {
    "1": "clear", "2": "cloudy", "3": "fog", "4": "rain", "5": "rain",
    "6": "snow", "7": "snow", "8": "snow",
}


def infer_road_type(systemstr: str) -> str:
    s = (systemstr or "").strip().upper()
    if s.startswith("I-") or s.startswith("US "):
        return "highway"
    if s.isdigit() or (s and s[0].isdigit()):
        return "rural"
    return "residential"


def load_rows(path: Path, cap: int | None = None):
    """Loads the raw Iowa CSV, keeping only rows with usable coordinates
    and a parseable crash datetime. Returns list of dicts with engineered
    features + the real (X, Y) point used later for clustering."""
    rows = []
    with open(path, encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        for i, r in enumerate(reader):
            if cap and i >= cap:
                break
            try:
                raw_x, raw_y = float(r["X"]), float(r["Y"])
                if raw_x == 0 or raw_y == 0:
                    continue
                x, y = web_mercator_to_lonlat(raw_x, raw_y)  # -> lon, lat
                if not (-180 <= x <= -80 and 30 <= y <= 55):
                    continue  # sanity bound: should land within/near Iowa
                month = int(r["CRASH_MONTH"])
                timestr = r.get("TIMESTR", "").strip()
                if not timestr:
                    continue
                hour = int(timestr[:2]) if len(timestr) >= 2 and timestr[:2].isdigit() else None
                if hour is None or not (0 <= hour <= 23):
                    continue
            except (ValueError, KeyError):
                continue

            is_animal = r.get("MAJCSE") == "1" or r.get("FRSTHARM") == "31"
            weather = WEATHER_MAP.get(r.get("WEATHER", "").strip(), "clear")
            road_type = infer_road_type(r.get("SYSTEMSTR", ""))

            rows.append({
                "lon": x, "lat": y,
                "hour_of_day": hour, "month": month,
                "weather": weather, "road_type": road_type,
                "label": 1 if is_animal else 0,
            })
    return rows


def build_training_frame(rows, clusters):
    """Attaches corridor_base_severity / distance_to_nearest_corridor_m
    from real DBSCAN clusters (see cluster_hotspots.py) and one-hot
    encodes categorical features to match RiskMLModel.swift's schema."""
    X, y = [], []
    for r in rows:
        dist_m, severity = nearest_cluster(r["lon"], r["lat"], clusters)
        feat = {
            "hour_of_day": float(r["hour_of_day"]),
            "month": float(r["month"]),
            "distance_to_nearest_corridor_m": dist_m,
            "corridor_base_severity": severity,
            "weather_condition_clear": 1.0 if r["weather"] == "clear" else 0.0,
            "weather_condition_cloudy": 1.0 if r["weather"] == "cloudy" else 0.0,
            "weather_condition_fog": 1.0 if r["weather"] == "fog" else 0.0,
            "weather_condition_rain": 1.0 if r["weather"] == "rain" else 0.0,
            "weather_condition_snow": 1.0 if r["weather"] == "snow" else 0.0,
            # Species is always "Deer" — see KNOWN LIMITATIONS above; Iowa's
            # SOR schema has no species field, deer is the documented
            # assumption for the overwhelming majority of animal crashes.
            "species_Deer": 1.0,
            "species_Elk": 0.0,
            "species_Moose": 0.0,
            "road_type_highway": 1.0 if r["road_type"] == "highway" else 0.0,
            "road_type_residential": 1.0 if r["road_type"] == "residential" else 0.0,
            "road_type_rural": 1.0 if r["road_type"] == "rural" else 0.0,
        }
        X.append(list(feat.values()))
        y.append(r["label"])
    feature_names = list(feat.keys())
    return X, y, feature_names


def haversine_m(lon1, lat1, lon2, lat2):
    R = 6371000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dlambda / 2) ** 2
    return 2 * R * math.asin(math.sqrt(a))


def nearest_cluster(lon, lat, clusters):
    best_dist, best_sev = float("inf"), 0.0
    for c in clusters:
        d = haversine_m(lon, lat, c["lon"], c["lat"])
        if d < best_dist:
            best_dist, best_sev = d, c["severity"]
    return best_dist, best_sev


def main():
    print(f"Loading {DATA_PATH} ...")
    rows = load_rows(DATA_PATH)
    animal_rows = [r for r in rows if r["label"] == 1]
    print(f"Usable rows (valid coords + time): {len(rows)}")
    print(f"Animal-collision rows: {len(animal_rows)} ({100*len(animal_rows)/len(rows):.1f}%)")

    # Import clusters produced by cluster_hotspots.py (must run first).
    clusters_path = OUTPUT_DIR / "iowa_clusters.json"
    clusters = json.loads(clusters_path.read_text())
    print(f"Loaded {len(clusters)} real animal-crash clusters for corridor features")

    # Balance classes: keep all animal rows, sample non-animal rows to
    # roughly a 1:2 ratio so training isn't drowned out by the 6:1 raw
    # imbalance, while staying honest that it's a resampled, not fabricated
    # dataset — every row is a real crash record.
    non_animal = [r for r in rows if r["label"] == 0]
    random.seed(42)
    random.shuffle(non_animal)
    sampled = animal_rows + non_animal[: len(animal_rows) * 2]
    random.shuffle(sampled)

    X, y, feature_names = build_training_frame(sampled, clusters)
    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.2, random_state=42, stratify=y
    )

    clf = GradientBoostingClassifier(
        n_estimators=150, max_depth=3, learning_rate=0.1, random_state=42
    )
    clf.fit(X_train, y_train)

    preds = clf.predict(X_test)
    probs = clf.predict_proba(X_test)[:, 1]
    acc = accuracy_score(y_test, preds)
    auc = roc_auc_score(y_test, probs)

    print(f"\n=== REAL metrics on held-out Iowa test set (n={len(y_test)}) ===")
    print(f"Accuracy: {acc:.4f}")
    print(f"ROC AUC:  {auc:.4f}")
    print(f"Training rows: {len(X_train)}  Test rows: {len(X_test)}")
    print(f"Feature order: {feature_names}")

    metrics = {
        "source_dataset": "Iowa DOT Crash Data (SOR)",
        "source_url": "https://public-iowadot.opendata.arcgis.com/datasets/IowaDOT::crash-data-sor",
        "total_raw_records": len(rows),
        "animal_collision_records": len(animal_rows),
        "training_rows": len(X_train),
        "test_rows": len(X_test),
        "accuracy": acc,
        "roc_auc": auc,
        "feature_names": feature_names,
        "limitations": [
            "No species field in source data; all positives labeled Deer.",
            "road_type inferred from route-name string, not authoritative classification.",
            "Iowa-only; not California-specific despite app's CA framing.",
            "corridor features derived from clustering this same dataset, not independent ground truth.",
        ],
    }
    (OUTPUT_DIR / "training_metrics.json").write_text(json.dumps(metrics, indent=2))
    print(f"\nWrote {OUTPUT_DIR / 'training_metrics.json'}")

    import joblib
    joblib.dump(clf, OUTPUT_DIR / "gbm_model.joblib")
    (OUTPUT_DIR / "feature_names.json").write_text(json.dumps(feature_names))
    print(f"Wrote {OUTPUT_DIR / 'gbm_model.joblib'}")


if __name__ == "__main__":
    main()
