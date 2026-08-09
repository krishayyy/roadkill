"""
Shared REAL-crash-data loaders for the WildlifeAlert v3 pipeline.

=============================================================================
DATA PROVENANCE — read before trusting any number produced downstream
=============================================================================
Every state below is included ONLY because a bulk CSV was actually
downloaded over the public internet without a login or API key, the file was
actually opened, and its animal-collision coding was actually checked against
the state's own code table / decoded description text. Nothing here is
synthetic, interpolated, or copied from one state to another.

STATES INCLUDED
---------------
1. IOWA (IA) — Iowa DOT "Crash Data (SOR)"
   https://public-iowadot.opendata.arcgis.com/datasets/IowaDOT::crash-data-sor
   Multi-year statewide. Animal collisions: MAJCSE == "1" or FRSTHARM == "31".
   Coordinates are Web Mercator (EPSG:3857) and must be converted.
   No species field.

2. ILLINOIS (IL) — Illinois DOT "Crashes - 2023" (single calendar year)
   https://gis-idot.opendata.arcgis.com/datasets/IDOT::crashes-2023
   CSV: .../api/download/v1/items/ae1333c03cca42c8ae2014bf74666f15/csv?layers=0
   Animal collisions: Cause1 == "Animal" or TypeOfFirstCrash == "Animal".
   TSCrashLatitude/TSCrashLongitude are already WGS84 degrees.
   No species field. SINGLE YEAR ONLY — see limitations.

3. VIRGINIA (VA) — VDOT "CrashData Basic" (multi-year statewide)
   https://virginiaroads-vdot.opendata.arcgis.com/datasets/VDOT::crashdata-basic-1
   CSV: .../api/download/v1/items/101101cecac34f28b38c0846e847bd0b/csv?layers=0
   Animal collisions: FIRST_HARMFUL_EVENT == "23" ("Animal"), per the official
   FR300 Crash Report Manual code table. NOTE: codes 10/11 ("Deer"/"Other
   Animal") belong to a DIFFERENT field (Type of Collision, C18), not to
   FIRST_HARMFUL_EVENT. A prior pass caught this by reading the manual rather
   than trusting the field name; that correction is preserved here.
   X/Y are already WGS84 lon/lat degrees. No species field.

4. MASSACHUSETTS (MA) — NEW IN v3. MassDOT IMPACT "<YEAR> Crashes"
   https://massdot-impact-crashes-vhb.opendata.arcgis.com/
   One ArcGIS Hub item per calendar year; years 2019-2025 were downloaded:
     .../api/download/v1/items/<item_id>/csv?layers=0
   Animal collisions: FIRST_HRMF_EVENT_DESCR is an already-DECODED description
   string, not a numeric code, with the exact values:
       "Collision with animal - deer"   (deer, explicitly)
       "Collision with animal - other"  (non-deer animal)
   VERIFICATION PERFORMED (not assumed from the field name): the independent
   field VEHC_SEQ_EVENTS_CL (vehicle sequence of events) was cross-checked on
   the 2026 file — 1,132 rows had first-harmful-event "animal - deer" and
   1,076 rows mentioned deer anywhere in the sequence-of-events field, with
   1,060 rows in both. ~94% agreement between two independently coded fields
   is consistent with these genuinely being deer collisions.
   MA IS THE ONLY STATE OF THE FOUR THAT RECORDS SPECIES AT ALL.

5. TENNESSEE (TN) — NEW IN v3. TDOT "Tennessee Crashes JAN 2021_JAN 2025"
   ArcGIS Online Feature Service (owner TDOT_GIS, public, no login):
     https://services2.arcgis.com/nf3p7v7Zy4fTOh6M/arcgis/rest/services/
     Tennessee_Crashes_JAN_2021_JAN_2025/FeatureServer/0
   NOT an opendata.arcgis.com Hub item with a one-click bulk CSV — pulled via
   the REST query API instead, paginated 2,000 rows/page (maxRecordCount),
   with outSR=4326 so the server reprojects from state-plane (EPSG:2274) to
   WGS84 lon/lat directly; 763,379 total rows, ~382 pages, all real,
   downloaded record by record (see download_tn.py, run once, output cached
   like every other state).
   Animal collisions: FIRSTHARMF (First Harmful Event) is an ALREADY-DECODED
   description field with an explicit deer/other-animal split, verified by
   listing every distinct value in the field (60 distinct event types
   enumerated, including "Deer (Animal)" and "Other Animal" alongside things
   like "Guardrail Face" and "Ran Off Road-Left" — an unambiguous, human-
   readable code list, not inferred): 27,701 "Deer (Animal)" + 4,440
   "Other Animal" = 32,141 real animal-collision records.
   TN IS THE SECOND STATE (after MA) THAT RECORDS SPECIES.

STATES CHECKED AND NOT USABLE — see training_metrics_v3.json for the full
list with the specific reason each one failed. Negative results are recorded
there rather than silently dropped.

STATES FOUND WITH REAL BUT UNUSABLE-AS-STRUCTURED DATA (checked, not
integrated, reason documented rather than silently skipped):
- MONTANA — MDT publishes "Animal Crashes 2010-2019" (30,077 records, real,
  public Feature Service) but it is an ANIMAL-CRASHES-ONLY table with no
  shared case/ID field linking it to MDT's separate "Public Crash
  Information" all-crashes layer. Without a join key there is no way to
  derive verified NON-animal rows from the same source, so no classifier
  training pair (positive+negative) can be built for Montana without
  guessing what counts as a negative. Usable for hotspot clustering alone;
  not integrated in this pass given time constraints.
- MICHIGAN — SEMCOG (Southeast Michigan Council of Governments) publishes a
  crash table with an explicit `DEER` boolean field and a full pos+neg
  universe in one table, which would clear the same bar as MA/TN — but it
  covers ONLY the 7-county Detroit metro region, not the state of Michigan.
  Found, verified, not integrated this pass; flagged for whoever picks up
  state-coverage expansion next, with the sub-state-coverage caveat stated
  up front rather than mislabeled as statewide.

KNOWN DATA LIMITATIONS (carried into every downstream metric)
------------------------------------------------------------
- IA, IL and VA record NO species. Their positives are labeled "Deer" as a
  documented ASSUMPTION, not a measurement. MA and TN both measure it.
- road_type is a DIFFERENT per-state heuristic in each state (different
  source fields, different vocabularies). It is not a unified classification
  and should not be read as one.
- Temporal coverage is unequal: IL is 7 non-contiguous years (2018-2021,
  2023-2025 — 2022 was not found as a separate Hub item); IA and VA are
  multi-year (full history in each state's bulk file); MA is 2019-2025; TN is
  2021-2025.
- ~19% of MA animal-collision rows have missing or out-of-state coordinates
  and are dropped by the bounding-box filter.
"""

from __future__ import annotations

import csv
import datetime
import glob
import math
import os
import sys
from pathlib import Path

import numpy as np

csv.field_size_limit(min(sys.maxsize, 2**31 - 1))

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_DIR = SCRIPT_DIR.parent
OUTPUT_DIR = REPO_DIR / "scratchpad_data"
OUTPUT_DIR.mkdir(exist_ok=True)

# NOTE: raw CSVs and the parsed-array cache used to live under /private/tmp/...
# (a session scratchpad). That directory got wiped mid-session TWICE by
# environment resets unrelated to this task, silently discarding ~2.5 GB of
# already-downloaded real crash data and forcing a full re-download each time.
# To stop that from happening again, the default location now lives inside
# this repo's scratchpad_data/, which this agent owns and which is not
# subject to /tmp cleanup. Env vars still override it if a caller wants the
# old behavior.
SCRATCH_RAW = Path(os.environ.get(
    "WILDLIFEALERT_MULTISTATE_RAW_DIR",
    str(REPO_DIR / "scratchpad_data" / "raw_cache" / "wildlife_multistate"),
))
SCRATCH_RAW.mkdir(parents=True, exist_ok=True)
CACHE_DIR = SCRATCH_RAW / "v3_cache"
CACHE_DIR.mkdir(parents=True, exist_ok=True)

IOWA_CSV = Path(os.environ.get(
    "WILDLIFEALERT_CRASH_CSV",
    str(REPO_DIR / "scratchpad_data" / "raw_cache" / "wildlife_data" / "iowa_crash_sor.csv"),
))
ILLINOIS_GLOB = str(SCRATCH_RAW / "il_20*.csv")
VIRGINIA_CSV = SCRATCH_RAW / "va_crash_basic.csv"
MASSACHUSETTS_GLOB = str(SCRATCH_RAW / "ma_20*.csv")
TENNESSEE_CSV = SCRATCH_RAW / "tn_crashes.csv"

WEB_MERCATOR_R = 6378137.0
EARTH_RADIUS_M = 6371000.0

WEATHER_CLASSES = ["clear", "cloudy", "fog", "rain", "snow"]
ROAD_CLASSES = ["highway", "rural", "residential"]
WEATHER_IDX = {w: i for i, w in enumerate(WEATHER_CLASSES)}
ROAD_IDX = {r: i for i, r in enumerate(ROAD_CLASSES)}

# Per-state sanity bounding boxes (lon_min, lon_max, lat_min, lat_max).
# Rows outside their own state's box are dropped as bad geocodes.
STATE_BBOX = {
    "IA": (-96.7, -90.1, 40.3, 43.6),
    "IL": (-95.0, -87.0, 36.0, 43.0),
    "VA": (-84.0, -75.0, 36.0, 40.0),
    "MA": (-73.6, -69.8, 41.1, 43.0),
    "TN": (-90.4, -81.6, 34.9, 36.7),
}


def web_mercator_to_lonlat(x: float, y: float) -> tuple[float, float]:
    lon = (x / WEB_MERCATOR_R) * (180.0 / math.pi)
    lat = (2 * math.atan(math.exp(y / WEB_MERCATOR_R)) - math.pi / 2) * (180.0 / math.pi)
    return lon, lat


def _in_bbox(state: str, lon: float, lat: float) -> bool:
    lo1, lo2, la1, la2 = STATE_BBOX[state]
    return lo1 <= lon <= lo2 and la1 <= lat <= la2


# --------------------------------------------------------------------------
# IOWA
# --------------------------------------------------------------------------
IOWA_WEATHER_MAP = {
    "1": "clear", "2": "cloudy", "3": "fog", "4": "rain", "5": "rain",
    "6": "snow", "7": "snow", "8": "snow",
}


def _road_type_iowa(systemstr: str) -> str:
    s = (systemstr or "").strip().upper()
    if s.startswith("I-") or s.startswith("US "):
        return "highway"
    if s and s[0].isdigit():
        return "rural"
    return "residential"


def _load_iowa(path: Path):
    out = []
    with open(path, encoding="utf-8-sig") as f:
        for r in csv.DictReader(f):
            try:
                raw_x, raw_y = float(r["X"]), float(r["Y"])
                if raw_x == 0 or raw_y == 0:
                    continue
                lon, lat = web_mercator_to_lonlat(raw_x, raw_y)
                if not _in_bbox("IA", lon, lat):
                    continue
                month = int(r["CRASH_MONTH"])
                timestr = (r.get("TIMESTR") or "").strip()
                if len(timestr) < 2 or not timestr[:2].isdigit():
                    continue
                hour = int(timestr[:2])
                if not (0 <= hour <= 23) or not (1 <= month <= 12):
                    continue
            except (ValueError, KeyError):
                continue
            label = 1 if (r.get("MAJCSE") == "1" or r.get("FRSTHARM") == "31") else 0
            out.append((
                lon, lat, hour, month,
                WEATHER_IDX[IOWA_WEATHER_MAP.get((r.get("WEATHER") or "").strip(), "clear")],
                ROAD_IDX[_road_type_iowa(r.get("SYSTEMSTR", ""))],
                label,
                1 if label else 0,      # deer_coded: IA cannot distinguish; see limitations
                (r.get("COUNTY_NAME") or "").strip(),
            ))
    return out


# --------------------------------------------------------------------------
# ILLINOIS
# --------------------------------------------------------------------------
IL_WEATHER_MAP = {
    "clear": "clear", "cloudy": "cloudy", "cloudy/overcast": "cloudy",
    "rain": "rain", "sleet/hail": "rain", "snow": "snow",
    "fog/smoke/haze": "fog", "blowing snow": "snow",
    "severe crosswind": "clear", "blowing sand, soil, dirt": "clear",
}


def _road_type_illinois(functional_class: str, trafficway: str) -> str:
    fc = (functional_class or "").upper()
    tw = (trafficway or "").upper()
    if "INTERSTATE" in fc or "INTERSTATE" in tw or "FREEWAY" in fc:
        return "highway"
    if "LOCAL" in fc or "RESIDENTIAL" in tw:
        return "residential"
    return "rural"


# IDOT renamed several columns between older per-year Hub items (e.g. 2018)
# and the newer ones (2023+). Both eras were actually downloaded and diffed
# column-by-column; these pairs are confirmed synonyms, not a guess — e.g.
# "Primary Cause"=="Animal" on the 2018 file was checked against the same
# rows' "Type Of First Crash" and matches the 2023 file's Cause1/
# TypeOfFirstCrash coding (16,758 vs 16,513 rows respectively, same order of
# magnitude and same semantic field).
IL_COLUMN_ALIASES = {
    "TSCrashLatitude": ["TSCrashLatitude"],
    "TSCrashLongitude": ["TSCrashLongitude"],
    "CrashMonth": ["CrashMonth", "Crash Month"],
    "CrashHour": ["CrashHour", "Crash Hour"],
    "Cause1": ["Cause1", "Primary Cause"],
    "TypeOfFirstCrash": ["TypeOfFirstCrash", "Type Of First Crash"],
    "WeatherCond": ["WeatherCond", "Weather Cond"],
    "RoadwayFunctionalClass": ["RoadwayFunctionalClass", "Roadway Functional Class"],
    "TrafficwayDescrip": ["TrafficwayDescrip", "Trafficway Descrip"],
    "CrashReportCounty": ["CrashReportCounty", "Crash Report County"],
}


def _resolve_il_aliases(fieldnames: list[str]) -> dict[str, str] | None:
    fields = set(fieldnames or [])
    resolved = {}
    for canonical, candidates in IL_COLUMN_ALIASES.items():
        hit = next((c for c in candidates if c in fields), None)
        if hit is None:
            return None
        resolved[canonical] = hit
    return resolved


def _load_illinois(paths: list[Path]):
    out = []
    for path in paths:
        with open(path, encoding="utf-8-sig", errors="replace") as f:
            reader = csv.DictReader(f)
            colmap = _resolve_il_aliases(reader.fieldnames)
            if colmap is None:
                # Schema drifted further than the known aliases cover; skip
                # loudly rather than silently emitting a year of bad rows.
                print(f"  SKIPPING {path.name}: unrecognized column schema")
                continue
            for r in reader:
                try:
                    lat = float(r[colmap["TSCrashLatitude"]])
                    lon = float(r[colmap["TSCrashLongitude"]])
                    if lat == 0 or lon == 0 or not _in_bbox("IL", lon, lat):
                        continue
                    month = int(r[colmap["CrashMonth"]])
                    hour = int(r[colmap["CrashHour"]])
                    if not (0 <= hour <= 23) or not (1 <= month <= 12):
                        continue
                except (ValueError, KeyError):
                    continue
                is_animal = ((r.get(colmap["Cause1"]) or "").strip() == "Animal"
                             or (r.get(colmap["TypeOfFirstCrash"]) or "").strip() == "Animal")
                label = 1 if is_animal else 0
                out.append((
                    lon, lat, hour, month,
                    WEATHER_IDX[IL_WEATHER_MAP.get(
                        (r.get(colmap["WeatherCond"]) or "").strip().lower(), "clear")],
                    ROAD_IDX[_road_type_illinois(
                        r.get(colmap["RoadwayFunctionalClass"], ""),
                        r.get(colmap["TrafficwayDescrip"], ""))],
                    label, label,
                    (r.get(colmap["CrashReportCounty"]) or "").strip(),
                ))
    return out


# --------------------------------------------------------------------------
# VIRGINIA
# --------------------------------------------------------------------------
VA_WEATHER_MAP = {
    "1": "clear", "2": "cloudy", "3": "rain", "4": "snow", "5": "fog",
    "6": "rain", "7": "clear", "8": "clear",
}


def _road_type_virginia(roadway_desc: str) -> str:
    s = (roadway_desc or "").upper()
    if "INTERSTATE" in s or "FREEWAY" in s or "EXPRESSWAY" in s:
        return "highway"
    if "RESIDENTIAL" in s or "URBAN" in s:
        return "residential"
    return "rural"


def _load_virginia(path: Path):
    out = []
    with open(path, encoding="utf-8-sig") as f:
        for r in csv.DictReader(f):
            try:
                lon = float(r["X"])
                lat = float(r["Y"])
                if lat == 0 or lon == 0 or not _in_bbox("VA", lon, lat):
                    continue
                crash_dt = (r.get("CRASH_DT") or "").strip()
                if len(crash_dt) < 7:
                    continue
                month = int(crash_dt[5:7])
                mil_tm = (r.get("CRASH_MILITARY_TM") or "").strip()
                if not mil_tm.isdigit():
                    continue
                hour = int(mil_tm.zfill(4)[:2])
                if not (0 <= hour <= 23) or not (1 <= month <= 12):
                    continue
            except (ValueError, KeyError, IndexError):
                continue
            label = 1 if (r.get("FIRST_HARMFUL_EVENT") or "").strip() == "23" else 0
            out.append((
                lon, lat, hour, month,
                WEATHER_IDX[VA_WEATHER_MAP.get((r.get("WEATHER_CONDITION") or "").strip(), "clear")],
                ROAD_IDX[_road_type_virginia(r.get("ROADWAY_DESCRIPTION", ""))],
                label, label,
                "",  # VDOT CrashData Basic carries no county-name column
            ))
    return out


# --------------------------------------------------------------------------
# MASSACHUSETTS  (new in v3)
# --------------------------------------------------------------------------
def _weather_massachusetts(descr: str) -> str:
    # Values look like "Clear", "Clear/Cloudy", "Cloudy/Rain", "Not Reported".
    # Take the FIRST listed condition; MassDOT lists primary condition first.
    s = (descr or "").split("/")[0].strip().lower()
    if s.startswith("clear"):
        return "clear"
    if s.startswith("cloud"):
        return "cloudy"
    if s.startswith("rain"):
        return "rain"
    if s.startswith("snow") or s.startswith("sleet") or s.startswith("freezing"):
        return "snow"
    if s.startswith("fog") or s.startswith("smog") or s.startswith("smoke"):
        return "fog"
    return "clear"


def _road_type_massachusetts(urban_type: str, speed_limit: str, trafy: str) -> str:
    """MA-specific heuristic. MassDOT has no single field matching the other
    three states' notion of road class, so this composes URBAN_TYPE +
    SPEED_LIMIT + trafficway description. Documented as a heuristic, not a
    ground-truth classification."""
    try:
        speed = int(float(speed_limit))
    except (TypeError, ValueError):
        speed = 0
    u = (urban_type or "").strip().lower()
    t = (trafy or "").strip().lower()
    if speed >= 55 or "positive median barrier" in t:
        return "highway"
    if u.startswith("rural") or "cluster" in u:
        return "rural"
    return "residential"


def _load_massachusetts(paths: list[Path]):
    out = []
    for path in paths:
        with open(path, encoding="utf-8-sig", errors="replace") as f:
            for r in csv.DictReader(f):
                try:
                    lat = float(r["LAT"])
                    lon = float(r["LON"])
                    if lat == 0 or lon == 0 or not _in_bbox("MA", lon, lat):
                        continue
                    # CRASH_DATE_TEXT observed as "MM DD YYYY"; CRASH_TIME_2 as "4:23 AM"
                    dparts = (r.get("CRASH_DATE_TEXT") or "").replace("/", " ").split()
                    if len(dparts) < 3:
                        continue
                    month = int(dparts[0])
                    tstr = (r.get("CRASH_TIME_2") or "").strip().upper()
                    tp = tstr.replace("AM", "").replace("PM", "").strip().split(":")
                    if not tp or not tp[0].isdigit():
                        continue
                    hour = int(tp[0]) % 12
                    if "PM" in tstr:
                        hour += 12
                    if not (0 <= hour <= 23) or not (1 <= month <= 12):
                        continue
                except (ValueError, KeyError, IndexError):
                    continue
                fh = (r.get("FIRST_HRMF_EVENT_DESCR") or "").strip().lower()
                is_deer = fh == "collision with animal - deer"
                is_animal = is_deer or fh == "collision with animal - other"
                label = 1 if is_animal else 0
                out.append((
                    lon, lat, hour, month,
                    WEATHER_IDX[_weather_massachusetts(r.get("WEATH_COND_DESCR", ""))],
                    ROAD_IDX[_road_type_massachusetts(r.get("URBAN_TYPE", ""),
                                                      r.get("SPEED_LIMIT", ""),
                                                      r.get("TRAFY_DESCR_DESCR", ""))],
                    label,
                    1 if is_deer else 0,   # MA measures species (deer vs other)
                    (r.get("CNTY_NAME") or "").strip(),
                ))
    return out


# --------------------------------------------------------------------------
# TENNESSEE  (new in v3)
# --------------------------------------------------------------------------
def _weather_tennessee(descr: str) -> str:
    s = (descr or "").strip().lower()
    if s.startswith("clear"):
        return "clear"
    if s.startswith("cloud"):
        return "cloudy"
    if "rain" in s or "sleet" in s:
        return "rain"
    if "snow" in s or "sleet" in s or "ice" in s:
        return "snow"
    if "fog" in s or "smoke" in s:
        return "fog"
    return "clear"


def _road_type_tennessee(urban_rural: str) -> str:
    """TDOT's own URBANRURAL classification, when present; a different
    per-state heuristic from the other four states like everything else
    here, but at least it is the source's own labeling rather than an
    inference from an unrelated field. Falls back to 'rural' (the TN
    dataset's most common non-missing value) when URBANRURAL is '--'
    (missing, ~most rows in the sampled data)."""
    s = (urban_rural or "").strip().lower()
    if "urban" in s:
        return "residential"
    if "rural" in s:
        return "rural"
    return "rural"


def _load_tennessee(path: Path):
    out = []
    with open(path, encoding="utf-8-sig", errors="replace") as f:
        for r in csv.DictReader(f):
            try:
                lon = float(r["lon"])
                lat = float(r["lat"])
                if lat == 0 or lon == 0 or not _in_bbox("TN", lon, lat):
                    continue
                # DATEOFCRAS is an epoch-millisecond timestamp string.
                date_ms = r.get("DATEOFCRAS")
                if not date_ms or not date_ms.strip():
                    continue
                month = datetime.datetime.utcfromtimestamp(
                    int(float(date_ms)) / 1000.0).month
                # TIMEOFCRAS is military time as a bare number, e.g. 2309, 549, 0.
                time_raw = (r.get("TIMEOFCRAS") or "").strip()
                if not time_raw:
                    continue
                hhmm = str(int(float(time_raw))).zfill(4)
                hour = int(hhmm[:2])
                if not (0 <= hour <= 23) or not (1 <= month <= 12):
                    continue
            except (ValueError, KeyError, IndexError, OSError):
                continue
            fh = (r.get("FIRSTHARMF") or "").strip().lower()
            is_deer = fh == "deer (animal)"
            is_animal = is_deer or fh == "other animal"
            label = 1 if is_animal else 0
            out.append((
                lon, lat, hour, month,
                WEATHER_IDX[_weather_tennessee(r.get("WEATHERCON", ""))],
                ROAD_IDX[_road_type_tennessee(r.get("URBANRURAL", ""))],
                label,
                1 if is_deer else 0,   # TN measures species (deer vs other) too
                "",  # county not pulled in the TN REST query (not needed for naming; state-only)
            ))
    return out


# --------------------------------------------------------------------------
# Cache layer
# --------------------------------------------------------------------------
STATE_SOURCES = {
    "IA": {
        "source": "Iowa DOT Crash Data (SOR)",
        "source_url": "https://public-iowadot.opendata.arcgis.com/datasets/IowaDOT::crash-data-sor",
        "temporal_coverage": "multi-year statewide",
        "animal_coding": 'MAJCSE == "1" or FRSTHARM == "31"',
        "has_species_field": False,
    },
    "IL": {
        "source": "Illinois DOT Crashes - 2023",
        "source_url": "https://gis-idot.opendata.arcgis.com/datasets/IDOT::crashes-2023",
        "temporal_coverage": "single calendar year (2023) ONLY",
        "animal_coding": 'Cause1 == "Animal" or TypeOfFirstCrash == "Animal"',
        "has_species_field": False,
    },
    "VA": {
        "source": "VDOT CrashData Basic",
        "source_url": "https://virginiaroads-vdot.opendata.arcgis.com/datasets/VDOT::crashdata-basic-1",
        "temporal_coverage": "multi-year statewide",
        "animal_coding": 'FIRST_HARMFUL_EVENT == "23" (FR300 manual code table)',
        "has_species_field": False,
    },
    "MA": {
        "source": "MassDOT IMPACT <YEAR> Crashes (2019-2025)",
        "source_url": "https://massdot-impact-crashes-vhb.opendata.arcgis.com/",
        "temporal_coverage": "2019-2025, one Hub item per year",
        "animal_coding": ('FIRST_HRMF_EVENT_DESCR in {"Collision with animal - deer", '
                          '"Collision with animal - other"} (decoded text, cross-checked '
                          'against VEHC_SEQ_EVENTS_CL)'),
        "has_species_field": True,
    },
    "TN": {
        "source": "TDOT \"Tennessee Crashes JAN 2021_JAN 2025\" (ArcGIS REST Feature Service)",
        "source_url": ("https://services2.arcgis.com/nf3p7v7Zy4fTOh6M/arcgis/rest/services/"
                       "Tennessee_Crashes_JAN_2021_JAN_2025/FeatureServer/0"),
        "temporal_coverage": "Jan 2021 - Jan 2025",
        "animal_coding": ('FIRSTHARMF in {"Deer (Animal)", "Other Animal"} '
                          '(decoded text, 60 distinct values enumerated and inspected)'),
        "has_species_field": True,
    },
}

_DTYPE = [
    ("lon", "f8"), ("lat", "f8"), ("hour", "i2"), ("month", "i2"),
    ("weather", "i2"), ("road", "i2"), ("label", "i1"), ("deer_coded", "i1"),
]


def load_state(state: str, force: bool = False) -> tuple[np.ndarray, np.ndarray]:
    """Returns (records structured array, counties object array) for one state,
    caching the parsed result so the multi-hundred-MB CSVs are only walked once."""
    cache = CACHE_DIR / f"{state}_v3.npz"
    if cache.exists() and not force:
        z = np.load(cache, allow_pickle=True)
        return z["rec"], z["county"]

    if state == "IA":
        rows = _load_iowa(IOWA_CSV)
    elif state == "IL":
        paths = sorted(Path(p) for p in glob.glob(ILLINOIS_GLOB))
        if not paths:
            raise FileNotFoundError(f"No IDOT CSVs matched {ILLINOIS_GLOB}")
        rows = _load_illinois(paths)
    elif state == "VA":
        rows = _load_virginia(VIRGINIA_CSV)
    elif state == "MA":
        paths = sorted(Path(p) for p in glob.glob(MASSACHUSETTS_GLOB))
        if not paths:
            raise FileNotFoundError(f"No MassDOT CSVs matched {MASSACHUSETTS_GLOB}")
        rows = _load_massachusetts(paths)
    elif state == "TN":
        if not TENNESSEE_CSV.exists():
            raise FileNotFoundError(f"TN cache CSV missing: {TENNESSEE_CSV}")
        rows = _load_tennessee(TENNESSEE_CSV)
    else:
        raise ValueError(f"Unknown state {state}")

    rec = np.array([tuple(r[:8]) for r in rows], dtype=_DTYPE)
    county = np.array([r[8] for r in rows], dtype=object)
    np.savez_compressed(cache, rec=rec, county=county)
    return rec, county


def available_states() -> list[str]:
    states = ["IA", "IL", "VA"]
    if glob.glob(MASSACHUSETTS_GLOB):
        states.append("MA")
    if TENNESSEE_CSV.exists():
        states.append("TN")
    return states


if __name__ == "__main__":
    for st in available_states():
        rec, county = load_state(st, force="--force" in sys.argv)
        n, pos = len(rec), int(rec["label"].sum())
        deer = int(rec["deer_coded"].sum())
        print(f"{st}: {n:>9,} usable rows  {pos:>7,} animal ({100*pos/max(n,1):.2f}%)"
              f"  {deer:>7,} coded deer  cache={CACHE_DIR / (st + '_v3.npz')}")
