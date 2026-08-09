"""
Trains WildlifeAlert's on-device collision-risk model on REAL crash data from
MULTIPLE states, extending the Iowa-only pipeline in train_risk_model.py.

=============================================================================
DATA PROVENANCE — read this before trusting any metric below
=============================================================================
This script combines three REAL, independently-downloaded state crash
datasets. Nothing here is synthetic or extrapolated between states — a
state is included only because a bulk CSV download was actually performed
and the resulting file was actually inspected for a real animal-collision
code.

1. IOWA — Iowa DOT "Crash Data (SOR)"
   https://public-iowadot.opendata.arcgis.com/datasets/IowaDOT::crash-data-sor
   Same file used by train_risk_model.py. 606,986 total records, 85,398
   animal-collision records (MAJCSE==1 or FRSTHARM==31). No species field
   (assumed Deer, per that script's documented limitation).

2. ILLINOIS — Illinois DOT "Crashes - 2023" (statewide, IDOT ArcGIS Hub)
   Landing page: https://gis-idot.opendata.arcgis.com/datasets/IDOT::crashes-2023
   Bulk CSV actually downloaded (public, no login, no API key):
     https://gis-idot.opendata.arcgis.com/api/download/v1/items/ae1333c03cca42c8ae2014bf74666f15/csv?layers=0
   300,144 total records for calendar year 2023 only (single year — IDOT
   also publishes 2009-2025 as separate yearly datasets and a
   dataset-per-year "Illinois Deer Crashes" series; only 2023 was pulled
   here to keep scope real-but-bounded, not to cherry-pick a good year).
   Animal collisions identified via the official Cause1 label == "Animal"
   or TypeOfFirstCrash == "Animal" (verified by inspecting real label
   values in the downloaded file, matching IDOT's crash coding).
   Coordinates (TSCrashLatitude/TSCrashLongitude) are already WGS84
   degrees — no Web Mercator conversion needed (unlike Iowa).
   No species field.

3. VIRGINIA — VDOT "CrashData Basic" (Virginia Roads ArcGIS Hub)
   Landing page: https://virginiaroads-vdot.opendata.arcgis.com/datasets/VDOT::crashdata-basic-1
   Bulk CSV actually downloaded (public, no login, no API key):
     https://virginiaroads-vdot.opendata.arcgis.com/api/download/v1/items/101101cecac34f28b38c0846e847bd0b/csv?layers=0
   1,130,320 total records, statewide, multi-year. Animal collisions
   identified via FIRST_HARMFUL_EVENT == 23 ("Animal"), per the official
   code table in VDOT/DMV's FR300 Crash Report Manual (Crash Events
   section, code 23 = Animal; codes 10/11 "Deer"/"Other Animal" belong to
   a *different* field, Type of Collision C18, not FIRST_HARMFUL_EVENT —
   confirmed by reading the manual, not assumed from the field name).
   61,653 records (5.45%) coded as animal collisions.
   X/Y columns are already WGS84 lon/lat degrees.
   No species field.

STATES CHECKED AND NOT INCLUDED (honest negative results, not silently
skipped):
  - Ohio: OGRIP portal (ogrip-geohio.opendata.arcgis.com) DCAT feed
    returned 404; ODOT's own crash tools (ohtrafficdata.dps.ohio.gov) are
    an interactive query app, not a bulk-download endpoint. No working
    unauthenticated bulk CSV found in the time available.
  - Pennsylvania: data-pennshare.opendata.arcgis.com DCAT feed loads but
    lists no dataset with "crash" in its title (PennDOT's PDF-based
    "OPEN DATA PORTAL Database Primer" describes a different, non-Hub
    delivery mechanism). Not verified as a working bulk CSV endpoint.
  - Minnesota: no opendata.arcgis.com Hub portal found; MnDOT's crash
    tooling (MnCMAT2) is a desktop/query application, not a bulk-download
    API.
  - Wisconsin: crash data lives on WisTransPortal (transportal.cee.wisc.edu),
    a request-form-based system, not an open ArcGIS Hub bulk CSV endpoint.
  - Utah: crash layer is served from a UDOT ArcGIS REST FeatureServer
    (maps.udot.utah.gov), not an opendata.arcgis.com Hub item; not
    confirmed bulk-downloadable without further query-pagination work.
  - Kentucky: opendata-kygeonet.opendata.arcgis.com DCAT feed loads but
    lists no crash dataset.
  - Colorado: data-cdot.opendata.arcgis.com DCAT feed returned an empty
    dataset list at the time of writing; CDOT's own site states granular
    crash data requires an open-records request.
  - North Carolina, Tennessee, Wyoming, Michigan, New York, Maine,
    Montana: no working opendata.arcgis.com Hub crash dataset with a
    confirmed bulk CSV endpoint was found in the time available. This is
    "not yet obtained", not "doesn't exist" — several of these states
    likely do publish something discoverable with more digging (e.g.
    Michigan Traffic Crash Facts' query tool, NY's data.ny.gov Socrata
    portal), but nothing was actually bulk-downloaded and verified, so
    they are excluded rather than guessed at.

KNOWN LIMITATIONS (same spirit as train_risk_model.py):
  - None of the three states record species; all positive examples across
    all three states are labeled species="Deer" (documented assumption,
    not measured — see train_risk_model.py's original caveat, which
    applies identically here).
  - road_type is inferred per-state from different source fields (Iowa:
    free-text route name; Illinois: RoadwayFunctionalClass text; Virginia:
    ROADWAY_DESCRIPTION / route name), not a single unified authoritative
    classification — a state-specific heuristic per state, not a shared
    ground truth.
  - Illinois is a single year (2023) while Iowa and Virginia are
    multi-year; this is a real difference in temporal coverage between
    states, not corrected for.
  - corridor_base_severity / distance_to_nearest_corridor_m are computed
    per-state (a Virginia crash is only ever compared to Virginia
    clusters, etc.) via cluster_hotspots_multistate.py, then unioned —
    not a single nationwide DBSCAN pass. This avoids nonsensical
    cross-country "nearest cluster" distances but means the feature's
    meaning is state-relative, same as Iowa's original.
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
OUTPUT_DIR = SCRIPT_DIR.parent / "scratchpad_data"
OUTPUT_DIR.mkdir(exist_ok=True)

SCRATCH_RAW = Path(os.environ.get(
    "WILDLIFEALERT_MULTISTATE_RAW_DIR",
    "/private/tmp/claude-501/-Users-krishay/7ec306c8-56c7-4f9b-b533-c9639a7ead4d/scratchpad/wildlife_multistate",
))
IOWA_CSV = Path(os.environ.get(
    "WILDLIFEALERT_CRASH_CSV",
    "/private/tmp/claude-501/-Users-krishay/7ec306c8-56c7-4f9b-b533-c9639a7ead4d/scratchpad/wildlife_data/iowa_crash_sor.csv",
))
ILLINOIS_CSV = SCRATCH_RAW / "il_crashes_2023.csv"
VIRGINIA_CSV = SCRATCH_RAW / "va_crash_basic.csv"

WEB_MERCATOR_R = 6378137.0


def web_mercator_to_lonlat(x: float, y: float) -> tuple[float, float]:
    lon = (x / WEB_MERCATOR_R) * (180.0 / math.pi)
    lat = (2 * math.atan(math.exp(y / WEB_MERCATOR_R)) - math.pi / 2) * (180.0 / math.pi)
    return lon, lat


IOWA_WEATHER_MAP = {
    "1": "clear", "2": "cloudy", "3": "fog", "4": "rain", "5": "rain",
    "6": "snow", "7": "snow", "8": "snow",
}


def infer_road_type_iowa(systemstr: str) -> str:
    s = (systemstr or "").strip().upper()
    if s.startswith("I-") or s.startswith("US "):
        return "highway"
    if s.isdigit() or (s and s[0].isdigit()):
        return "rural"
    return "residential"


def load_iowa(path: Path):
    """Reuses the same parsing logic as train_risk_model.py's load_rows."""
    rows = []
    with open(path, encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        for r in reader:
            try:
                raw_x, raw_y = float(r["X"]), float(r["Y"])
                if raw_x == 0 or raw_y == 0:
                    continue
                lon, lat = web_mercator_to_lonlat(raw_x, raw_y)
                if not (-180 <= lon <= -80 and 30 <= lat <= 55):
                    continue
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
            weather = IOWA_WEATHER_MAP.get(r.get("WEATHER", "").strip(), "clear")
            road_type = infer_road_type_iowa(r.get("SYSTEMSTR", ""))
            rows.append({
                "state": "IA", "lon": lon, "lat": lat,
                "hour_of_day": hour, "month": month,
                "weather": weather, "road_type": road_type,
                "label": 1 if is_animal else 0,
            })
    return rows


IL_WEATHER_MAP = {
    "clear": "clear", "cloudy": "cloudy", "cloudy/overcast": "cloudy",
    "rain": "rain", "sleet/hail": "rain", "snow": "snow",
    "fog/smoke/haze": "fog", "blowing snow": "snow",
    "severe crosswind": "clear", "blowing sand, soil, dirt": "clear",
}


def infer_road_type_illinois(functional_class: str, trafficway: str) -> str:
    fc = (functional_class or "").upper()
    tw = (trafficway or "").upper()
    if "INTERSTATE" in fc or "INTERSTATE" in tw or "FREEWAY" in fc:
        return "highway"
    if "COLLECTOR" in fc or "ARTERIAL" in fc and "MINOR" in fc:
        return "rural"
    if "LOCAL" in fc or "RESIDENTIAL" in tw:
        return "residential"
    return "rural"


def load_illinois(path: Path):
    rows = []
    with open(path, encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        for r in reader:
            try:
                lat = float(r["TSCrashLatitude"])
                lon = float(r["TSCrashLongitude"])
                if lat == 0 or lon == 0:
                    continue
                if not (-95 <= lon <= -87 and 36 <= lat <= 43):
                    continue  # sanity bound for Illinois
                month = int(r["CrashMonth"])
                hour = int(r["CrashHour"])
                if not (0 <= hour <= 23):
                    continue
            except (ValueError, KeyError):
                continue
            cause1 = (r.get("Cause1") or "").strip()
            first_crash = (r.get("TypeOfFirstCrash") or "").strip()
            is_animal = cause1 == "Animal" or first_crash == "Animal"
            weather = IL_WEATHER_MAP.get((r.get("WeatherCond") or "").strip().lower(), "clear")
            road_type = infer_road_type_illinois(
                r.get("RoadwayFunctionalClass", ""), r.get("TrafficwayDescrip", "")
            )
            rows.append({
                "state": "IL", "lon": lon, "lat": lat,
                "hour_of_day": hour, "month": month,
                "weather": weather, "road_type": road_type,
                "label": 1 if is_animal else 0,
            })
    return rows


VA_WEATHER_MAP = {
    "1": "clear", "2": "cloudy", "3": "rain", "4": "snow", "5": "fog",
    "6": "rain", "7": "clear", "8": "clear",
}


def infer_road_type_virginia(roadway_desc: str) -> str:
    s = (roadway_desc or "").upper()
    if "INTERSTATE" in s or "FREEWAY" in s or "EXPRESSWAY" in s:
        return "highway"
    if "RESIDENTIAL" in s or "URBAN" in s:
        return "residential"
    return "rural"


def load_virginia(path: Path):
    rows = []
    with open(path, encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        for r in reader:
            try:
                lon = float(r["X"])
                lat = float(r["Y"])
                if lat == 0 or lon == 0:
                    continue
                if not (-84 <= lon <= -75 and 36 <= lat <= 40):
                    continue  # sanity bound for Virginia
                crash_dt = (r.get("CRASH_DT") or "").strip()
                if not crash_dt:
                    continue
                # Format observed: "2017/11/03 00:00:00+00"
                month = int(crash_dt[5:7])
                mil_tm = (r.get("CRASH_MILITARY_TM") or "").strip()
                if not mil_tm or not mil_tm.isdigit():
                    continue
                mil_tm = mil_tm.zfill(4)
                hour = int(mil_tm[:2])
                if not (0 <= hour <= 23):
                    continue
            except (ValueError, KeyError, IndexError):
                continue
            is_animal = (r.get("FIRST_HARMFUL_EVENT") or "").strip() == "23"
            weather = VA_WEATHER_MAP.get((r.get("WEATHER_CONDITION") or "").strip(), "clear")
            road_type = infer_road_type_virginia(r.get("ROADWAY_DESCRIPTION", ""))
            rows.append({
                "state": "VA", "lon": lon, "lat": lat,
                "hour_of_day": hour, "month": month,
                "weather": weather, "road_type": road_type,
                "label": 1 if is_animal else 0,
            })
    return rows


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


def build_training_frame(rows, clusters_by_state):
    X, y, feat = [], [], None
    for r in rows:
        clusters = clusters_by_state.get(r["state"], [])
        dist_m, severity = nearest_cluster(r["lon"], r["lat"], clusters) if clusters else (1_000_000.0, 0.0)
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


def main():
    print("Loading real multi-state crash data ...")
    per_state_stats = {}

    print(f"  Iowa: {IOWA_CSV}")
    iowa_rows = load_iowa(IOWA_CSV)
    per_state_stats["IA"] = {
        "total_usable_rows": len(iowa_rows),
        "animal_rows": sum(r["label"] for r in iowa_rows),
        "source": "Iowa DOT Crash Data (SOR)",
        "source_url": "https://public-iowadot.opendata.arcgis.com/datasets/IowaDOT::crash-data-sor",
    }

    print(f"  Illinois: {ILLINOIS_CSV}")
    il_rows = load_illinois(ILLINOIS_CSV)
    per_state_stats["IL"] = {
        "total_usable_rows": len(il_rows),
        "animal_rows": sum(r["label"] for r in il_rows),
        "source": "Illinois DOT Crashes - 2023 (single year)",
        "source_url": "https://gis-idot.opendata.arcgis.com/datasets/IDOT::crashes-2023",
    }

    print(f"  Virginia: {VIRGINIA_CSV}")
    va_rows = load_virginia(VIRGINIA_CSV)
    per_state_stats["VA"] = {
        "total_usable_rows": len(va_rows),
        "animal_rows": sum(r["label"] for r in va_rows),
        "source": "VDOT CrashData Basic (multi-year, statewide)",
        "source_url": "https://virginiaroads-vdot.opendata.arcgis.com/datasets/VDOT::crashdata-basic-1",
    }

    for state, stats in per_state_stats.items():
        print(f"    {state}: {stats['total_usable_rows']} usable rows, "
              f"{stats['animal_rows']} real animal-collision rows "
              f"({100*stats['animal_rows']/max(stats['total_usable_rows'],1):.2f}%)")

    all_rows = iowa_rows + il_rows + va_rows
    print(f"\nCombined real rows across 3 states: {len(all_rows)}")

    # Load per-state DBSCAN clusters (produced by cluster_hotspots_multistate.py,
    # which must run first).
    clusters_by_state = {}
    for state, fname in [("IA", "iowa_clusters.json"), ("IL", "illinois_clusters.json"), ("VA", "virginia_clusters.json")]:
        p = OUTPUT_DIR / fname
        if p.exists():
            clusters_by_state[state] = json.loads(p.read_text())
        else:
            clusters_by_state[state] = []
    print("Loaded per-state real DBSCAN clusters: "
          + ", ".join(f"{s}={len(c)}" for s, c in clusters_by_state.items()))

    # Balance classes overall (keep all animal rows, sample non-animal ~2:1),
    # same approach as the Iowa-only script, applied to the combined pool.
    animal_rows_all = [r for r in all_rows if r["label"] == 1]
    non_animal_all = [r for r in all_rows if r["label"] == 0]
    random.seed(42)
    random.shuffle(non_animal_all)
    sampled = animal_rows_all + non_animal_all[: len(animal_rows_all) * 2]
    random.shuffle(sampled)

    X, y, feature_names = build_training_frame(sampled, clusters_by_state)
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

    print(f"\n=== REAL metrics on held-out combined multi-state test set (n={len(y_test)}) ===")
    print(f"Accuracy: {acc:.4f}")
    print(f"ROC AUC:  {auc:.4f}")
    print(f"Training rows: {len(X_train)}  Test rows: {len(X_test)}")

    metrics = {
        "states_included": ["IA", "IL", "VA"],
        "per_state": per_state_stats,
        "total_raw_records_combined": sum(s["total_usable_rows"] for s in per_state_stats.values()),
        "total_animal_collision_records_combined": sum(s["animal_rows"] for s in per_state_stats.values()),
        "training_rows": len(X_train),
        "test_rows": len(X_test),
        "accuracy": acc,
        "roc_auc": auc,
        "feature_names": feature_names,
        "states_checked_but_excluded": [
            "OH (no working bulk CSV endpoint found)",
            "PA (portal has no crash-titled dataset in its DCAT feed)",
            "MN (no ArcGIS Hub portal found; query-tool only)",
            "WI (WisTransPortal is request-form based, not bulk API)",
            "UT (crash layer is a REST FeatureServer, not an Hub bulk CSV item)",
            "KY (portal has no crash dataset in its DCAT feed)",
            "CO (portal DCAT feed had no crash datasets; CDOT states granular data requires open-records request)",
            "NC, TN, WY, MI, NY, ME, MT (no working ArcGIS Hub bulk CSV endpoint found in time available - not yet obtained, not confirmed absent)",
        ],
        "limitations": [
            "No species field in any of the 3 states' source data; all positives labeled Deer.",
            "road_type inferred per-state from different heuristics (not a unified classification).",
            "Illinois is a single year (2023); Iowa and Virginia are multi-year.",
            "corridor features are computed per-state (state-relative), not a single nationwide clustering pass.",
        ],
    }
    (OUTPUT_DIR / "training_metrics_multistate.json").write_text(json.dumps(metrics, indent=2))
    print(f"\nWrote {OUTPUT_DIR / 'training_metrics_multistate.json'}")

    import joblib
    joblib.dump(clf, OUTPUT_DIR / "gbm_model_multistate.joblib")
    (OUTPUT_DIR / "feature_names_multistate.json").write_text(json.dumps(feature_names))
    print(f"Wrote {OUTPUT_DIR / 'gbm_model_multistate.joblib'}")


if __name__ == "__main__":
    main()
