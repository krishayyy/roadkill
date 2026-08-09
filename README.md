# WildlifeAlert

A native iOS driving app that warns drivers about wildlife-collision risk zones — deer, elk, and moose corridors — in real time, using MapKit navigation, live Firestore-backed hotspot data, and an on-device machine learning model trained on real state crash records.

Think Waze, but for animal strikes: it warns you before you enter a known collision corridor, not after.

## What it does

- **Turn-by-turn navigation** (MapKit) with a live risk gauge that updates as you drive — pick **live GPS** or **simulate the drive** for testing/demos
- **Speed- and direction-aware alerts**: warnings fire ahead of a hotspot based on your current speed and whether you're actually approaching it — not just because you're nearby, and not if you're driving away
- **Background alerting**: region monitoring wakes the app even when it's backgrounded or killed, with local notifications
- **A transparent risk score**, not a black box: severity, distance decay, time-of-day (dawn/dusk peaks), season (fall rut), weather, live traffic pace, recent crowdsourced sightings, and a machine learning prediction are all shown as separate, named factors — never a single unexplained number
- **Haptics, audio-ducked voice alerts**, dark/night-mode-biased map styling, and a pre-trip risk summary before you even start driving

## The data — real, not synthetic

Every hotspot is derived from real, publicly published state crash records — not hand-picked guesses:

| State | Source | Real records | Animal-collision records |
|---|---|---|---|
| Iowa | Iowa DOT Crash Data (SOR) | 606,986 | 85,398 |
| Illinois | Illinois DOT Crashes (7 years) | — | 114,386 |
| Virginia | VDOT CrashData Basic | 1,130,302 | 61,653 |
| Massachusetts | MassDOT IMPACT (2019–2025) | 864,000+ | 25,047 |
| Tennessee | TDOT Crashes (2021–2025) | 767,000+ | 32,164 |

Hotspots are derived by density-based clustering (DBSCAN, tuned per state) of the real animal-collision coordinates, with genuine road-segment geometry — most corridors are rendered as a buffered polyline along the actual road, not a generic circle.

**States that were checked and found not usable are documented, not silently skipped**: Ohio, Pennsylvania, Minnesota, Wisconsin, Utah, Kentucky, and Colorado all lack a public, no-login bulk-download crash dataset as of this writing. That's stated plainly in the code rather than papered over.

## The model — honestly evaluated

A `GradientBoostingClassifier` trained on the real crash data above, blended with the transparent rule-based engine (not a replacement for it). An earlier version of this model reported a ROC AUC of 0.867 — that number had label leakage (it used cluster-derived features to predict cluster-derived labels). After a proper spatial cross-validation fix:

- **Honest ROC AUC: 0.8205** — down from the leaky 0.867, which is the expected and correct direction for fixing a leak, not a regression
- Species features (deer/elk/moose) carry ~zero predictive importance, because none of the five source datasets have a real species field — worth knowing if you're deciding what to trust the model on
- Full methodology and every known limitation: `scratchpad_data/training_evaluations_v3.json`

## Project structure

```
WildlifeAlert/          # iOS app source (Swift, MapKit, CoreML)
WildlifeAlertTests/      # XCTest coverage for the risk engine and alert logic
scripts/                 # Python data pipeline: sourcing, clustering, training, CoreML export
scratchpad_data/         # Cluster results, training metrics, hotspot candidates (small JSON only —
                         # raw multi-GB CSVs and model binaries are gitignored)
```

## Building

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen) and a Firebase project (Firestore) of your own.

```bash
xcodegen generate
open WildlifeAlert.xcodeproj
```

You'll need your own `WildlifeAlert/GoogleService-Info.plist` (gitignored) from a Firebase project with a `wildlifeHotspots` collection seeded via the scripts in `scripts/`.

## Retraining the model

```bash
cd scripts
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt  # scikit-learn, coremltools, pandas
python3 wildlife_data_v3.py      # download + cache real state crash data
python3 cluster_hotspots_v3.py   # per-state density-aware clustering
python3 train_risk_model_v3.py   # leakage-audited training with honest spatial CV
python3 export_coreml_v3.py      # export to WildlifeRiskModel.mlpackage
```

## Known limitations

- Real data currently covers 5 states; everywhere else falls back to the rule-based engine alone
- CarPlay support is scaffolded but non-functional — it requires Apple's manual CarPlay Navigation entitlement approval
- WeatherKit requires a paid Apple Developer Program team; on a free/personal team the app falls back to deterministic mock weather automatically
