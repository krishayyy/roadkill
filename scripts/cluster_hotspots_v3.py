"""
v3 corridor clustering for WildlifeAlert.

Fixes three real defects in cluster_hotspots_multistate.py:

(1) PER-STATE DENSITY-AWARE eps  (was: one hardcoded 800 m for every state)
    A single eps across states with very different point densities produced a
    broken result. The actual observed failure was the OPPOSITE of a mega-
    cluster: at eps=800 m Illinois produced exactly ONE cluster of 15 points
    and left 16,446 of its 16,461 animal-collision points as DBSCAN NOISE,
    because Illinois only has a single year (2023) of data and is therefore
    far sparser than multi-year Iowa. (The figure 16,446 is the noise count,
    not a cluster size.)
    v3 derives eps per state from that state's own k-nearest-neighbour
    distance distribution, but NOT via the textbook k-distance knee. The knee
    was implemented first and measured, and it failed: it selects eps in the
    PERCOLATION regime, where DBSCAN chains along the continuous road network.
    On Iowa the knee picked eps=2593 m and produced a single cluster holding
    54,518 of 85,366 points (64%) spanning 441 km — the same mega-cluster
    pathology, just arrived at from the other direction. That measurement is
    kept in cluster_tuning_v3.json rather than quietly discarded.

    What v3 actually uses is a percolation-bounded sweep: walk a density-
    adaptive grid of candidate eps values (spanning this state's own 10th-90th
    percentile k-distance range) from largest to smallest, and take the
    LARGEST eps at which DBSCAN still does not percolate — i.e. no single
    cluster swallows more than MAX_CLUSTER_FRACTION of the state's points and
    the 95th-percentile cluster extent stays under MAX_CLUSTER_EXTENT_M. This
    keeps as much real agglomeration as the data supports while directly
    bounding the failure mode that broke both v2 and the knee attempt, and it
    adapts per state because the candidate grid is built from each state's own
    point density.

(2) REAL CLUSTER EXTENTS  (was: radiusMeters hardcoded to 1500 for every
    hotspot regardless of size). v3 measures each cluster's actual spatial
    extent from its own member points.

(3) ROAD-SEGMENT POLYLINES  (was: circles only). Collisions happen ALONG
    roads; a 1500 m circle covers a lot of terrain with no road on it. For
    clusters that are genuinely elongated, v3 fits an ordered polyline
    through the member points and reports a narrow buffer half-width instead
    of a fat circle radius.

Polylines are derived purely from the crash points themselves — there is NO
road-network / OSM snapping here. That was considered and deliberately not
done: doing it reliably needs either a paid routing API or a large offline
extract, and a wrong snap silently moves a hotspot onto the wrong road. A
PCA-ordered median path is simpler, fully reproducible from the same real
data, and fails visibly (we omit pathPoints) rather than silently.

Outputs:
  scratchpad_data/{state}_clusters_v3.json  — full cluster list per state
  scratchpad_data/hotspot_candidates_v2.json — app-facing candidates
This script does NOT write to Firestore.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np
from sklearn.cluster import DBSCAN
from sklearn.neighbors import NearestNeighbors

from wildlife_data_v3 import (
    EARTH_RADIUS_M, OUTPUT_DIR, STATE_SOURCES, available_states, load_state,
)

MIN_SAMPLES = 15
EPS_FLOOR_M = 200.0
EPS_CEIL_M = 4000.0
TOP_N_PER_STATE = 25

# Percolation guards. A "hotspot" a driver can act on is a road segment a few
# km long; a cluster spanning a whole county is not actionable and not a real
# corridor, it is DBSCAN chaining along the road network.
MAX_CLUSTER_FRACTION = 0.05     # no cluster may hold >5% of a state's points
MAX_CLUSTER_EXTENT_M = 12_000.0  # 95th-pct cluster extent ceiling
N_EPS_CANDIDATES = 14
# Clusters that still exceed this after tuning are dropped from the candidate
# list rather than shipped as a giant blob.
MAX_CANDIDATE_EXTENT_M = 25_000.0
# A hotspot is only worth shipping if it is specific enough to warn about.
# Ranking purely by crash count (what v2 did) selects diffuse metropolitan
# agglomerations: of the top 25 clusters per state by raw count, 87 of 100 had
# a real 85th-percentile extent at or above the 3 km clip. v2 did not surface
# this because it overwrote every radius with a flat 1500 m — so v2's shipped
# hotspots were largely urban blobs mislabelled as 1.5 km circles. v3 requires
# a candidate to be either road-shaped (has a polyline) or genuinely compact.
ACTIONABLE_MAX_CIRCLE_M = 1500.0

# Cluster-extent / polyline tuning. All are documented, not silently baked in.
EXTENT_PERCENTILE = 85          # radius covers this % of member points
CIRCLE_RADIUS_MIN_M = 150.0
CIRCLE_RADIUS_MAX_M = 3000.0
MIN_ELONGATION_FOR_PATH = 2.5   # sqrt(lambda1/lambda2); below this it's a blob
# A real road corridor is narrow. If the member points sit further than this
# from the fitted path, they are not strung along one road (typically a metro
# area with several roads) and we must NOT claim a road segment for them.
# Without this absolute cap the relative gate below passes buffers of >1 km,
# which is a 2.5 km-wide band, not a road.
PATH_MAX_BUFFER_M = 400.0
MIN_EXTENT_FOR_PATH_M = 400.0
TARGET_VERTEX_SPACING_M = 500.0
MAX_VERTICES = 12
MIN_POINTS_PER_VERTEX = 3
BUFFER_MIN_M = 100.0
BUFFER_MAX_M = 1500.0
# If the polyline buffer isn't meaningfully tighter than the plain circle, the
# polyline is not describing a road and we omit it rather than fake precision.
PATH_MUST_BEAT_CIRCLE_RATIO = 0.6


# --------------------------------------------------------------------------
# Local planar projection (equirectangular about a local origin). Accurate to
# well under a metre over the few-km spans of a single cluster.
# --------------------------------------------------------------------------
def to_local_m(lons, lats, lon0, lat0):
    k = math.cos(math.radians(lat0))
    x = (np.asarray(lons) - lon0) * k * (math.pi / 180.0) * EARTH_RADIUS_M
    y = (np.asarray(lats) - lat0) * (math.pi / 180.0) * EARTH_RADIUS_M
    return x, y


def to_lonlat(x, y, lon0, lat0):
    k = math.cos(math.radians(lat0))
    lon = lon0 + np.asarray(x) / (k * (math.pi / 180.0) * EARTH_RADIUS_M)
    lat = lat0 + np.asarray(y) / ((math.pi / 180.0) * EARTH_RADIUS_M)
    return lon, lat


# --------------------------------------------------------------------------
# (1) Per-state density-aware eps
# --------------------------------------------------------------------------
def _k_distances(lonlat: np.ndarray, k: int) -> np.ndarray:
    coords_rad = np.radians(lonlat[:, ::-1])  # (lat, lon) for haversine
    nn = NearestNeighbors(n_neighbors=k + 1, metric="haversine", algorithm="ball_tree")
    nn.fit(coords_rad)
    dists, _ = nn.kneighbors(coords_rad)
    return np.sort(dists[:, k] * EARTH_RADIUS_M)


def _knee_eps(kdist: np.ndarray) -> float:
    """The textbook k-distance knee. Retained ONLY so the tuning record can
    show what it would have chosen and why it was rejected."""
    cut = kdist[: max(int(0.99 * len(kdist)), 2)]
    xs = np.linspace(0.0, 1.0, len(cut))
    ys = (cut - cut[0]) / max(cut[-1] - cut[0], 1e-9)
    return float(cut[int(np.argmax(np.abs(ys - xs)))])


def _percolation_stats(lonlat: np.ndarray, eps_m: float, min_samples: int) -> dict:
    labels = dbscan_labels(lonlat, eps_m, min_samples)
    ids = [c for c in np.unique(labels) if c != -1]
    if not ids:
        return {"n_clusters": 0, "max_fraction": 0.0, "extent_p95_m": 0.0,
                "noise_fraction": 1.0}
    counts = np.array([(labels == c).sum() for c in ids])
    extents = []
    for c in ids:
        m = labels == c
        pts = lonlat[m]
        lon0, lat0 = float(pts[:, 0].mean()), float(pts[:, 1].mean())
        x, y = to_local_m(pts[:, 0], pts[:, 1], lon0, lat0)
        p = np.column_stack([x, y])
        cov = np.cov(p.T) if len(p) > 1 else np.zeros((2, 2))
        ev, evec = np.linalg.eigh(cov)
        t = p @ evec[:, int(np.argmax(ev))]
        extents.append(float(np.percentile(t, 98) - np.percentile(t, 2)))
    return {
        "n_clusters": len(ids),
        "max_fraction": float(counts.max() / len(lonlat)),
        "extent_p95_m": float(np.percentile(extents, 95)),
        "noise_fraction": float((labels == -1).sum() / len(lonlat)),
    }


def tune_eps_meters(lonlat: np.ndarray, min_samples: int = MIN_SAMPLES) -> dict:
    """Percolation-bounded, density-adaptive eps for one state.

    Candidate grid spans this state's own 10th-90th percentile k-distance, so
    a sparse state (Illinois, one year of data) is automatically offered
    larger eps values than a dense one (Iowa, multi-year). We then take the
    largest candidate that does NOT percolate."""
    n = len(lonlat)
    k = min(min_samples, n - 1)
    kdist = _k_distances(lonlat, k)
    lo = float(np.clip(np.percentile(kdist, 10), EPS_FLOOR_M, EPS_CEIL_M))
    hi = float(np.clip(np.percentile(kdist, 90), EPS_FLOOR_M, EPS_CEIL_M))
    if hi <= lo:
        hi = min(lo * 2.0, EPS_CEIL_M)
    grid = np.geomspace(lo, hi, N_EPS_CANDIDATES)

    trace, chosen, chosen_stats = [], None, None
    for eps in sorted(grid, reverse=True):
        st = _percolation_stats(lonlat, float(eps), min_samples)
        ok = (st["max_fraction"] <= MAX_CLUSTER_FRACTION
              and st["extent_p95_m"] <= MAX_CLUSTER_EXTENT_M)
        trace.append({"eps_m": round(float(eps), 1), "accepted": bool(ok), **{
            kk: round(vv, 4) if isinstance(vv, float) else vv for kk, vv in st.items()}})
        if ok and chosen is None:
            chosen, chosen_stats = float(eps), st
    if chosen is None:                      # nothing passed; take the tightest
        chosen = float(min(grid))
        chosen_stats = _percolation_stats(lonlat, chosen, min_samples)

    return {
        "eps_m": chosen,
        "min_samples": int(min_samples),
        "n_points": int(n),
        "k_distance_median_m": float(np.median(kdist)),
        "k_distance_p10_m": lo,
        "k_distance_p90_m": hi,
        "selection_rule": (f"largest eps with max_cluster_fraction<={MAX_CLUSTER_FRACTION} "
                           f"and extent_p95<={MAX_CLUSTER_EXTENT_M:.0f}m"),
        "chosen_stats": {kk: (round(vv, 4) if isinstance(vv, float) else vv)
                         for kk, vv in chosen_stats.items()},
        "rejected_knee_eps_m": round(_knee_eps(kdist), 1),
        "eps_sweep": trace,
    }


def dbscan_labels(lonlat: np.ndarray, eps_m: float, min_samples: int = MIN_SAMPLES):
    coords_rad = np.radians(lonlat[:, ::-1])
    db = DBSCAN(eps=eps_m / EARTH_RADIUS_M, min_samples=min_samples,
                metric="haversine", algorithm="ball_tree").fit(coords_rad)
    return db.labels_


def cluster_centroids(lonlat: np.ndarray, eps_m: float, min_samples: int = MIN_SAMPLES):
    """Minimal (lon, lat, count) centroid list — used by the training script to
    build corridor features from a TRAIN-ONLY subset of points."""
    if len(lonlat) < min_samples:
        return np.zeros((0, 2)), np.zeros(0, dtype=int)
    labels = dbscan_labels(lonlat, eps_m, min_samples)
    uniq = [c for c in np.unique(labels) if c != -1]
    if not uniq:
        return np.zeros((0, 2)), np.zeros(0, dtype=int)
    cent = np.array([lonlat[labels == c].mean(axis=0) for c in uniq])
    counts = np.array([int((labels == c).sum()) for c in uniq])
    return cent, counts


# --------------------------------------------------------------------------
# (2)+(3) Real extent and road-segment polyline for one cluster
# --------------------------------------------------------------------------
def _point_segment_dist(px, py, ax, ay, bx, by):
    vx, vy = bx - ax, by - ay
    L2 = vx * vx + vy * vy
    if L2 <= 1e-12:
        return np.hypot(px - ax, py - ay)
    t = np.clip(((px - ax) * vx + (py - ay) * vy) / L2, 0.0, 1.0)
    return np.hypot(px - (ax + t * vx), py - (ay + t * vy))


def _dist_to_polyline(x, y, vx, vy):
    d = None
    for i in range(len(vx) - 1):
        di = _point_segment_dist(x, y, vx[i], vy[i], vx[i + 1], vy[i + 1])
        d = di if d is None else np.minimum(d, di)
    return d


def cluster_geometry(member_lonlat: np.ndarray) -> dict:
    """Derives centroid, a REAL radius from the cluster's own spread, and — when
    the cluster is genuinely road-shaped — an ordered polyline plus a tighter
    buffer half-width."""
    lon0 = float(member_lonlat[:, 0].mean())
    lat0 = float(member_lonlat[:, 1].mean())
    x, y = to_local_m(member_lonlat[:, 0], member_lonlat[:, 1], lon0, lat0)

    circle_radius = float(np.clip(
        np.percentile(np.hypot(x, y), EXTENT_PERCENTILE),
        CIRCLE_RADIUS_MIN_M, CIRCLE_RADIUS_MAX_M))

    geom = {
        "lon": lon0, "lat": lat0,
        "radius_m": circle_radius,
        "circle_radius_m": circle_radius,
        "path": None,
        "elongation": None,
        "extent_m": None,
        "path_rejected_reason": None,
    }

    pts = np.column_stack([x, y])
    if len(pts) < MIN_POINTS_PER_VERTEX * 2:
        geom["path_rejected_reason"] = "too few points"
        return geom

    # Principal axis of the cluster.
    cov = np.cov(pts.T)
    evals, evecs = np.linalg.eigh(cov)
    order = np.argsort(evals)[::-1]
    evals, evecs = evals[order], evecs[:, order]
    if evals[1] <= 1e-9:
        elong = float("inf")
    else:
        elong = float(math.sqrt(max(evals[0], 0.0) / max(evals[1], 1e-9)))
    geom["elongation"] = None if math.isinf(elong) else elong

    t = pts @ evecs[:, 0]
    extent = float(np.percentile(t, 98) - np.percentile(t, 2))
    geom["extent_m"] = extent

    if elong < MIN_ELONGATION_FOR_PATH:
        geom["path_rejected_reason"] = f"blob-shaped (elongation {elong:.2f} < {MIN_ELONGATION_FOR_PATH})"
        return geom
    if extent < MIN_EXTENT_FOR_PATH_M:
        geom["path_rejected_reason"] = f"too short ({extent:.0f} m < {MIN_EXTENT_FOR_PATH_M:.0f} m)"
        return geom

    n_vert = int(np.clip(round(extent / TARGET_VERTEX_SPACING_M), 2, MAX_VERTICES))
    n_vert = min(n_vert, len(pts) // MIN_POINTS_PER_VERTEX)
    if n_vert < 2:
        geom["path_rejected_reason"] = "not enough points per vertex"
        return geom

    # Equal-count bins along the principal axis, so every vertex is backed by
    # the same number of real crash points. The vertex is the bin's MEDIAN
    # position (both along- and across-axis), which lets the path follow a
    # gently curving road instead of forcing a straight line.
    order_t = np.argsort(t)
    bins = np.array_split(order_t, n_vert)
    verts = np.array([np.median(pts[b], axis=0) for b in bins if len(b) > 0])
    if len(verts) < 2:
        geom["path_rejected_reason"] = "degenerate binning"
        return geom

    resid = _dist_to_polyline(pts[:, 0], pts[:, 1], verts[:, 0], verts[:, 1])
    buffer_m = float(np.clip(np.percentile(resid, EXTENT_PERCENTILE),
                             BUFFER_MIN_M, BUFFER_MAX_M))

    if buffer_m > PATH_MAX_BUFFER_M:
        geom["path_rejected_reason"] = (
            f"points spread {buffer_m:.0f} m from the fitted path, wider than "
            f"a road corridor ({PATH_MAX_BUFFER_M:.0f} m) — not a single road")
        return geom
    if buffer_m > PATH_MUST_BEAT_CIRCLE_RATIO * circle_radius:
        geom["path_rejected_reason"] = (
            f"polyline buffer {buffer_m:.0f} m not tighter than circle "
            f"{circle_radius:.0f} m")
        return geom

    vlon, vlat = to_lonlat(verts[:, 0], verts[:, 1], lon0, lat0)
    geom["path"] = [{"lat": round(float(la), 5), "lon": round(float(lo), 5)}
                    for lo, la in zip(vlon, vlat)]
    geom["radius_m"] = buffer_m
    geom["buffer_half_width_m"] = buffer_m
    return geom


# --------------------------------------------------------------------------
# Per-state driver
# --------------------------------------------------------------------------
def build_state(state: str) -> tuple[list, list, dict]:
    rec, county = load_state(state)
    mask = rec["label"] == 1
    lonlat = np.column_stack([rec["lon"][mask], rec["lat"][mask]])
    counties = county[mask]
    deer_coded = rec["deer_coded"][mask]
    n_pts = len(lonlat)
    print(f"[{state}] {n_pts:,} real animal-collision points")
    if n_pts < MIN_SAMPLES:
        return [], [], {"n_points": n_pts, "note": "too few points to cluster"}

    tune = tune_eps_meters(lonlat)
    print(f"[{state}] tuned eps = {tune['eps_m']:.0f} m "
          f"(median {MIN_SAMPLES}-NN distance {tune['k_distance_median_m']:.0f} m; "
          f"textbook knee would have picked {tune['rejected_knee_eps_m']:.0f} m "
          f"and percolated)")

    labels = dbscan_labels(lonlat, tune["eps_m"])
    ids = [c for c in np.unique(labels) if c != -1]
    n_noise = int((labels == -1).sum())
    print(f"[{state}] {len(ids)} clusters, {n_noise:,} noise "
          f"({100*n_noise/n_pts:.1f}% of points)")

    clusters = []
    for cid in ids:
        m = labels == cid
        geom = cluster_geometry(lonlat[m])
        cs = [c for c in counties[m] if c]
        clusters.append({
            "cluster_id": int(cid),
            "lon": geom["lon"], "lat": geom["lat"],
            "severity": int(m.sum()), "point_count": int(m.sum()),
            "deer_coded_count": int(deer_coded[m].sum()),
            "county": max(set(cs), key=cs.count) if cs else "Unknown",
            "radius_m": geom["radius_m"],
            "circle_radius_m": geom["circle_radius_m"],
            "elongation": geom["elongation"],
            "extent_m": geom["extent_m"],
            "path": geom["path"],
            "path_rejected_reason": geom["path_rejected_reason"],
        })
    clusters.sort(key=lambda c: -c["severity"])
    (OUTPUT_DIR / f"{state}_clusters_v3.json").write_text(json.dumps(clusters, indent=2))

    # Any cluster still spanning an implausible distance is a chaining
    # artefact, not a corridor a driver can be warned about. Drop rather than
    # ship as a giant blob; the count dropped is recorded.
    usable = [c for c in clusters
              if (c["extent_m"] or 0.0) <= MAX_CANDIDATE_EXTENT_M]
    n_dropped = len(clusters) - len(usable)
    if n_dropped:
        print(f"[{state}] dropped {n_dropped} cluster(s) exceeding "
              f"{MAX_CANDIDATE_EXTENT_M:.0f} m extent")
    actionable = [c for c in usable
                  if c["path"] or c["radius_m"] <= ACTIONABLE_MAX_CIRCLE_M]
    print(f"[{state}] {len(actionable)} of {len(usable)} clusters are "
          f"road-shaped or compact enough to ship as a hotspot")
    top = actionable[:TOP_N_PER_STATE]
    # Risk level is a WITHIN-STATE relative ranking of the selected hotspots,
    # not an absolute collision rate. States have very unequal temporal
    # coverage, so cross-state severity counts are not comparable.
    sevs = sorted(c["severity"] for c in top) or [0]
    t1 = sevs[len(sevs) // 3]
    t2 = sevs[(2 * len(sevs)) // 3]

    has_species = STATE_SOURCES[state]["has_species_field"]
    candidates = []
    for c in top:
        level = "Severe" if c["severity"] >= t2 else ("High" if c["severity"] >= t1 else "Moderate")
        county_part = f"{c['county'].title()} County " if c["county"] not in ("Unknown", "") else ""
        if has_species:
            pct = 100.0 * c["deer_coded_count"] / max(c["point_count"], 1)
            species_note = (f"{c['deer_coded_count']} of {c['point_count']} "
                            f"({pct:.0f}%) coded specifically as deer by the source")
        else:
            species_note = "source has no species field; species assumed Deer"
        shape = ("polyline of %d vertices, buffer half-width %.0f m"
                 % (len(c["path"]), c["radius_m"])) if c["path"] else \
                ("circle radius %.0f m (no road-shaped axis found: %s)"
                 % (c["radius_m"], c["path_rejected_reason"]))
        cand = {
            "name": f"{county_part}Deer Corridor ({state})",
            "lat": round(c["lat"], 5),
            "lon": round(c["lon"], 5),
            "radiusMeters": int(round(c["radius_m"])),
            "species": "Deer",
            "riskLevel": level,
            "source": (
                f"{STATE_SOURCES[state]['source']} — DBSCAN cluster of "
                f"{c['point_count']} real animal-vehicle crash reports "
                f"(eps {tune['eps_m']:.0f} m tuned to {state} point density); "
                f"{shape}; {species_note}"
            ),
            "state": state,
        }
        if c["path"]:
            cand["pathPoints"] = c["path"]
        candidates.append(cand)

    stats = {
        **tune,
        "n_clusters": len(clusters),
        "n_clusters_dropped_oversize": n_dropped,
        "n_clusters_actionable": len(actionable),
        "n_noise": n_noise,
        "noise_fraction": round(n_noise / n_pts, 4),
        "n_candidates_emitted": len(candidates),
        "n_candidates_with_polyline": sum(1 for c in candidates if "pathPoints" in c),
        "radius_m_min": round(min((c["radiusMeters"] for c in candidates), default=0)),
        "radius_m_max": round(max((c["radiusMeters"] for c in candidates), default=0)),
        "radius_m_median": round(float(np.median([c["radiusMeters"] for c in candidates]))) if candidates else 0,
    }
    return clusters, candidates, stats


def main():
    all_candidates, all_stats = [], {}
    for state in available_states():
        _, cands, stats = build_state(state)
        all_candidates.extend(cands)
        all_stats[state] = stats
        print()

    out = OUTPUT_DIR / "hotspot_candidates_v2.json"
    out.write_text(json.dumps(all_candidates, indent=2))
    (OUTPUT_DIR / "cluster_tuning_v3.json").write_text(json.dumps(all_stats, indent=2))

    print(f"Wrote {out} — {len(all_candidates)} candidates across "
          f"{len({c['state'] for c in all_candidates})} states, "
          f"{sum(1 for c in all_candidates if 'pathPoints' in c)} with pathPoints")
    print(f"Wrote {OUTPUT_DIR / 'cluster_tuning_v3.json'}")
    print("\nNOTE: this script does NOT write to Firestore.")


if __name__ == "__main__":
    main()
