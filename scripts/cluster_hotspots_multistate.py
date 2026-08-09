"""
Density-clusters REAL animal-vehicle-collision points per state (Iowa,
Illinois, Virginia — see train_risk_model_multistate.py's docstring for
full provenance of each) into named corridor "hotspots", extending
cluster_hotspots.py to multiple states.

Writes, per state:
  {state}_clusters.json — cluster centroids + crash-count severity, used by
    train_risk_model_multistate.py for corridor features (state-relative:
    a Virginia crash is only ever matched against Virginia clusters).

And combined:
  hotspot_candidates_multistate.json — all states' top clusters reshaped
    into the Firestore `wildlifeHotspots` document shape. NOT written to
    Firestore by this script.

Clustering method: identical to cluster_hotspots.py — DBSCAN on raw
lat/lon (haversine metric), eps ~800m, min_samples=15.
"""

import csv
import json
from pathlib import Path

import numpy as np
from sklearn.cluster import DBSCAN

from train_risk_model_multistate import (
    IOWA_CSV, ILLINOIS_CSV, VIRGINIA_CSV,
    web_mercator_to_lonlat,
)

OUTPUT_DIR = Path(__file__).resolve().parent.parent / "scratchpad_data"
OUTPUT_DIR.mkdir(exist_ok=True)

EARTH_RADIUS_M = 6371000.0
EPS_METERS = 800.0
MIN_SAMPLES = 15


def load_iowa_animal_points(path: Path):
    pts = []
    with open(path, encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        for r in reader:
            if r.get("MAJCSE") != "1" and r.get("FRSTHARM") != "31":
                continue
            try:
                raw_x, raw_y = float(r["X"]), float(r["Y"])
                if raw_x == 0 or raw_y == 0:
                    continue
                lon, lat = web_mercator_to_lonlat(raw_x, raw_y)
                if not (-180 <= lon <= -80 and 30 <= lat <= 55):
                    continue
            except (ValueError, KeyError):
                continue
            pts.append((lon, lat, r.get("COUNTY_NAME", "").strip()))
    return pts


def load_illinois_animal_points(path: Path):
    pts = []
    with open(path, encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        for r in reader:
            cause1 = (r.get("Cause1") or "").strip()
            first_crash = (r.get("TypeOfFirstCrash") or "").strip()
            if cause1 != "Animal" and first_crash != "Animal":
                continue
            try:
                lat = float(r["TSCrashLatitude"])
                lon = float(r["TSCrashLongitude"])
                if lat == 0 or lon == 0:
                    continue
                if not (-95 <= lon <= -87 and 36 <= lat <= 43):
                    continue
            except (ValueError, KeyError):
                continue
            county = (r.get("CrashReportCounty") or "").strip()
            pts.append((lon, lat, county))
    return pts


def load_virginia_animal_points(path: Path):
    pts = []
    with open(path, encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        for r in reader:
            if (r.get("FIRST_HARMFUL_EVENT") or "").strip() != "23":
                continue
            try:
                lon = float(r["X"])
                lat = float(r["Y"])
                if lat == 0 or lon == 0:
                    continue
                if not (-84 <= lon <= -75 and 36 <= lat <= 40):
                    continue
            except (ValueError, KeyError):
                continue
            pts.append((lon, lat, ""))  # VA CrashData Basic has no county name field
    return pts


def cluster_state(state_code: str, pts, name_suffix: str):
    print(f"[{state_code}] {len(pts)} real animal-collision points loaded")
    if len(pts) < MIN_SAMPLES:
        print(f"[{state_code}] too few points to cluster, skipping")
        return [], []

    coords_rad = np.radians([[lat, lon] for lon, lat, _ in pts])
    eps_rad = EPS_METERS / EARTH_RADIUS_M
    db = DBSCAN(eps=eps_rad, min_samples=MIN_SAMPLES, metric="haversine").fit(coords_rad)
    labels = db.labels_

    n_clusters = len(set(labels)) - (1 if -1 in labels else 0)
    n_noise = int(np.sum(labels == -1))
    print(f"[{state_code}] DBSCAN found {n_clusters} real corridor clusters "
          f"({n_noise} points classified as noise)")

    clusters = []
    for cluster_id in sorted(set(labels)):
        if cluster_id == -1:
            continue
        member_idx = np.where(labels == cluster_id)[0]
        lons = [pts[i][0] for i in member_idx]
        lats = [pts[i][1] for i in member_idx]
        counties = [pts[i][2] for i in member_idx if pts[i][2]]
        centroid_lon, centroid_lat = float(np.mean(lons)), float(np.mean(lats))
        county = max(set(counties), key=counties.count) if counties else "Unknown"
        severity = len(member_idx)
        clusters.append({
            "cluster_id": int(cluster_id),
            "lon": centroid_lon,
            "lat": centroid_lat,
            "severity": severity,
            "county": county,
            "point_count": len(member_idx),
        })
    clusters.sort(key=lambda c: -c["severity"])

    (OUTPUT_DIR / f"{name_suffix}_clusters.json").write_text(json.dumps(clusters, indent=2))
    print(f"[{state_code}] Wrote {OUTPUT_DIR / (name_suffix + '_clusters.json')} ({len(clusters)} clusters)")

    top_n = clusters[:25]
    sevs = sorted(c["severity"] for c in top_n) if top_n else [0]
    t1 = sevs[len(sevs) // 3]
    t2 = sevs[(2 * len(sevs)) // 3]

    def risk_level_for(severity):
        if severity >= t2:
            return "Severe"
        if severity >= t1:
            return "High"
        return "Moderate"

    candidates = []
    for c in top_n:
        county_part = f"{c['county']} County " if c["county"] != "Unknown" else ""
        candidates.append({
            "name": f"{county_part}Deer Corridor ({state_code})",
            "lat": round(c["lat"], 5),
            "lon": round(c["lon"], 5),
            "radiusMeters": 1500,
            "species": "Deer",
            "riskLevel": risk_level_for(c["severity"]),
            "source": (
                f"{name_suffix} real crash dataset, DBSCAN cluster of "
                f"{c['point_count']} real animal-vehicle crash reports"
            ),
            "state": state_code,
        })
    return clusters, candidates


def main():
    all_candidates = []

    iowa_pts = load_iowa_animal_points(IOWA_CSV)
    _, iowa_candidates = cluster_state("IA", iowa_pts, "iowa")
    all_candidates.extend(iowa_candidates)

    il_pts = load_illinois_animal_points(ILLINOIS_CSV)
    _, il_candidates = cluster_state("IL", il_pts, "illinois")
    all_candidates.extend(il_candidates)

    va_pts = load_virginia_animal_points(VIRGINIA_CSV)
    _, va_candidates = cluster_state("VA", va_pts, "virginia")
    all_candidates.extend(va_candidates)

    (OUTPUT_DIR / "hotspot_candidates_multistate.json").write_text(json.dumps(all_candidates, indent=2))
    print(f"\nWrote {OUTPUT_DIR / 'hotspot_candidates_multistate.json'} "
          f"({len(all_candidates)} total candidates across {len({c['state'] for c in all_candidates})} states)")
    print("\nNOTE: this script does NOT write to Firestore. It only produces the")
    print("candidate JSON for whoever performs the gated Firestore write.")


if __name__ == "__main__":
    main()
