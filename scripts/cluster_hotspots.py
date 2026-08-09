"""
Density-clusters REAL animal-vehicle-collision points (Iowa DOT Crash Data
SOR — see train_risk_model.py's docstring for full provenance) into named
corridor "hotspots" for two consumers:

  1. iowa_clusters.json — cluster centroids + crash-count severity, used by
     train_risk_model.py to compute distance_to_nearest_corridor_m and
     corridor_base_severity as real (not hand-picked) features.
  2. hotspot_candidates.json — the same clusters reshaped into the
     Firestore `wildlifeHotspots` document shape the app expects, for
     whoever performs the actual Firestore write. NOT written to Firestore
     by this script — that is a separate, explicitly-gated step.

Clustering method: DBSCAN on raw lat/lon (haversine metric), eps chosen so
points within ~800m of each other join a cluster, min_samples=15 so a
"hotspot" requires a real, repeated concentration of animal-crash reports,
not a couple of isolated incidents. This is intentionally simple and
documented rather than tuned to produce a particular headline number.
"""

import csv
import json
import math
from pathlib import Path

import numpy as np
from sklearn.cluster import DBSCAN

from train_risk_model import DATA_PATH, WEATHER_MAP, infer_road_type, web_mercator_to_lonlat  # noqa: F401

OUTPUT_DIR = Path(__file__).resolve().parent.parent / "scratchpad_data"
OUTPUT_DIR.mkdir(exist_ok=True)

EARTH_RADIUS_M = 6371000.0
EPS_METERS = 800.0
MIN_SAMPLES = 15


def load_animal_points(path: Path):
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


def main():
    print(f"Loading real animal-crash points from {DATA_PATH} ...")
    pts = load_animal_points(DATA_PATH)
    print(f"Loaded {len(pts)} real animal-collision points")

    coords_rad = np.radians([[lat, lon] for lon, lat, _ in pts])
    eps_rad = EPS_METERS / EARTH_RADIUS_M
    db = DBSCAN(eps=eps_rad, min_samples=MIN_SAMPLES, metric="haversine").fit(coords_rad)
    labels = db.labels_

    n_clusters = len(set(labels)) - (1 if -1 in labels else 0)
    n_noise = int(np.sum(labels == -1))
    print(f"DBSCAN found {n_clusters} real corridor clusters "
          f"({n_noise} points classified as noise / not part of a corridor)")

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
        severity = len(member_idx)  # real crash count in this cluster
        clusters.append({
            "cluster_id": int(cluster_id),
            "lon": centroid_lon,
            "lat": centroid_lat,
            "severity": severity,
            "county": county,
            "point_count": len(member_idx),
        })

    clusters.sort(key=lambda c: -c["severity"])

    (OUTPUT_DIR / "iowa_clusters.json").write_text(json.dumps(clusters, indent=2))
    print(f"Wrote {OUTPUT_DIR / 'iowa_clusters.json'} ({len(clusters)} clusters)")

    # Map real crash-count severity to the app's RiskLevel enum
    # (Hotspot.swift: "Moderate" | "High" | "Severe" — a string category, not
    # a float). Terciles are computed over the real cluster-size
    # distribution itself, not arbitrary hand-picked cutoffs.
    top_n = clusters[:25]  # cap candidate list to the strongest real corridors
    sevs = sorted(c["severity"] for c in top_n)
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
        candidates.append({
            "name": f"{c['county']} County Deer Corridor (IA)",
            "lat": round(c["lat"], 5),
            "lon": round(c["lon"], 5),
            "radiusMeters": 1500,
            "species": "Deer",
            "riskLevel": risk_level_for(c["severity"]),
            "source": (
                "Iowa DOT Crash Data (SOR), public-iowadot.opendata.arcgis.com, "
                f"DBSCAN cluster of {c['point_count']} real animal-vehicle crash reports"
            ),
            "state": "IA",
        })

    (OUTPUT_DIR / "hotspot_candidates.json").write_text(json.dumps(candidates, indent=2))
    print(f"Wrote {OUTPUT_DIR / 'hotspot_candidates.json'} ({len(candidates)} candidates, top real clusters only)")
    print("\nNOTE: this script does NOT write to Firestore. It only produces the")
    print("candidate JSON for whoever performs the gated Firestore write.")


if __name__ == "__main__":
    main()
