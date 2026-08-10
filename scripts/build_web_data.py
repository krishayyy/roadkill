#!/usr/bin/env python3
"""
Build web/data/*.json from the real, already-computed hotspot clusters and
model evaluation results in scratchpad_data/. No new data collection or
model training happens here — this reshapes existing real outputs for the
web demo and calibrates the collision simulation against real annual totals.

Run: python3 scripts/build_web_data.py
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRATCH = ROOT / "scratchpad_data"
OUT = ROOT / "web" / "data"
OUT.mkdir(parents=True, exist_ok=True)

# Real animal-collision record totals per state (from README.md / the
# training data's per-state provenance in training_evaluations_v3.json).
# "years" is the number of calendar years each source covers, used only to
# annualize the total into a per-year rate for the simulation baseline.
# IL, MA, TN are documented source spans (confirmed). IA and VA sources are
# described only as "multi-year statewide" with no exact span recorded
# during ingestion (see scripts/wildlife_data_v3.py) — those two are
# labeled "assumed" rather than presented as precisely known.
STATES = {
    "IA": {"name": "Iowa",          "total_animal_collisions": 85398,  "years": 10, "years_confirmed": False,
           "source": "Iowa DOT Crash Data (SOR)"},
    "IL": {"name": "Illinois",      "total_animal_collisions": 114386, "years": 1,  "years_confirmed": True,
           "source": "Illinois DOT Crashes (2023 only)"},
    "VA": {"name": "Virginia",      "total_animal_collisions": 61653,  "years": 8,  "years_confirmed": False,
           "source": "VDOT CrashData Basic"},
    "MA": {"name": "Massachusetts", "total_animal_collisions": 25047,  "years": 6,  "years_confirmed": True,
           "source": "MassDOT IMPACT (2019-2025)"},
    "TN": {"name": "Tennessee",     "total_animal_collisions": 32164,  "years": 4,  "years_confirmed": True,
           "source": "TDOT Crashes (Jan 2021-Jan 2025)"},
}

# Alert effectiveness: chance an in-time alert causes the driver to avoid a
# collision they'd otherwise have had. Published field studies of animal
# detection / roadside warning systems typically report 30-50% collision
# reduction; we use 50%, the top of that commonly-cited range.
ALERT_EFFECTIVENESS = 0.50

# Cost/injury/death multipliers, derived from commonly-cited national
# wildlife-vehicle collision figures (~1-2M collisions/yr, ~$8-10B/yr cost,
# ~26,000 injuries/yr, ~200 deaths/yr — e.g. IIHS/State Farm claims data).
# We anchor on the midpoint of each published range, not the combination
# that maximizes cost per collision.
NATIONAL_ANNUAL_COLLISIONS = 1_500_000
NATIONAL_ANNUAL_COST_USD = 9_000_000_000
NATIONAL_ANNUAL_INJURIES = 26_000
NATIONAL_ANNUAL_DEATHS = 200

COST_PER_COLLISION = round(NATIONAL_ANNUAL_COST_USD / NATIONAL_ANNUAL_COLLISIONS)
INJURY_RATE = NATIONAL_ANNUAL_INJURIES / NATIONAL_ANNUAL_COLLISIONS
DEATH_RATE = NATIONAL_ANNUAL_DEATHS / NATIONAL_ANNUAL_COLLISIONS


def build_hotspots_geojson():
    """Merge the 5 states' real DBSCAN cluster files into one GeoJSON, with
    each hotspot's share of its state's annual collisions (for the sim's
    spatial event placement) precomputed."""
    features = []
    for code, meta in STATES.items():
        path = SCRATCH / f"{code}_clusters_v3.json"
        clusters = json.loads(path.read_text())
        state_severity_sum = sum(c.get("severity", 0) for c in clusters)
        for c in clusters:
            share = (c.get("severity", 0) / state_severity_sum) if state_severity_sum else 0
            features.append({
                "type": "Feature",
                "geometry": {"type": "Point", "coordinates": [c["lon"], c["lat"]]},
                "properties": {
                    "state": code,
                    "cluster_id": c.get("cluster_id"),
                    "county": c.get("county"),
                    "severity": c.get("severity", 0),
                    "radius_m": c.get("radius_m") or c.get("circle_radius_m") or 1500,
                    "share_of_state": share,
                },
            })
    geojson = {"type": "FeatureCollection", "features": features}
    (OUT / "hotspots.geojson").write_text(json.dumps(geojson))
    print(f"hotspots.geojson: {len(features)} real hotspots across {len(STATES)} states")


def build_sim_config():
    """Calibrate each state's baseline annual collision rate against its
    real reported total, plus the shared simulation constants."""
    states_out = {}
    for code, meta in STATES.items():
        annual = meta["total_animal_collisions"] / meta["years"]
        states_out[code] = {
            "name": meta["name"],
            "source": meta["source"],
            "total_animal_collisions": meta["total_animal_collisions"],
            "years": meta["years"],
            "years_confirmed": meta["years_confirmed"],
            "baseline_annual_collisions": round(annual, 1),
        }

    all_total = sum(s["total_animal_collisions"] for s in states_out.values())
    all_annual = sum(s["baseline_annual_collisions"] for s in states_out.values())

    config = {
        "alert_effectiveness": ALERT_EFFECTIVENESS,
        "cost_per_collision_usd": COST_PER_COLLISION,
        "injury_rate_per_collision": round(INJURY_RATE, 5),
        "death_rate_per_collision": round(DEATH_RATE, 6),
        "sources": {
            "effectiveness": "Published animal-detection/warning-system field studies typically cite 30-50% collision reduction; 50% used here.",
            "cost_injury": f"National estimate: ~{NATIONAL_ANNUAL_COLLISIONS:,} wildlife-vehicle collisions/yr, ~${NATIONAL_ANNUAL_COST_USD/1e9:.1f}B/yr in costs, ~{NATIONAL_ANNUAL_INJURIES:,} injuries/yr, ~{NATIONAL_ANNUAL_DEATHS} deaths/yr (commonly cited insurance/DOT figures).",
        },
        "states": states_out,
        "all": {
            "name": "All 5 States",
            "total_animal_collisions": all_total,
            "baseline_annual_collisions": round(all_annual, 1),
        },
    }
    (OUT / "sim_config.json").write_text(json.dumps(config, indent=2))
    print(f"sim_config.json: baseline {all_annual:,.0f} real collisions/yr across all states")


def build_model_metrics():
    """Trim the full training evaluation JSON down to what the charts need."""
    src = json.loads((SCRATCH / "training_evaluations_v3.json").read_text())
    out = {
        "headline": src["headline"],
        "per_state_roc_auc": src["v3_full_dataset"]["evaluations"]["crossfit_spatial_cv"]["per_state_roc_auc"],
        "feature_importances": src["v3_full_dataset"]["final_model_feature_importances"],
        "leaky_vs_honest": {
            "leaky_random_split_roc_auc": src["v3_full_dataset"]["evaluations"]["leaky_random_split"]["roc_auc"],
            "honest_spatial_cv_roc_auc": src["v3_full_dataset"]["evaluations"]["crossfit_spatial_cv"]["roc_auc"],
        },
    }
    (OUT / "model_metrics.json").write_text(json.dumps(out, indent=2))
    print("model_metrics.json written")


def build_eps_sweep():
    """Iowa's real percolation-bounded eps tuning trace — the largest real
    dataset, and the exact example the clustering script's own docstring
    uses to explain why the textbook k-distance knee was rejected."""
    tuning = json.loads((SCRATCH / "cluster_tuning_v3.json").read_text())
    ia = tuning["IA"]
    out = {
        "state": "IA",
        "chosen_eps_m": ia["eps_m"],
        "rejected_knee_eps_m": ia["rejected_knee_eps_m"],
        "max_cluster_fraction_limit": 0.05,
        "sweep": [
            {"eps_m": p["eps_m"], "max_fraction": p["max_fraction"], "accepted": p["accepted"]}
            for p in ia["eps_sweep"]
        ],
    }
    (OUT / "eps_sweep.json").write_text(json.dumps(out, indent=2))
    print("eps_sweep.json written (Iowa, real percolation tuning trace)")


if __name__ == "__main__":
    build_hotspots_geojson()
    build_sim_config()
    build_model_metrics()
    build_eps_sweep()
