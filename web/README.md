# WildlifeAlert web demo

Static site: landing page, real-data dashboard, and an interactive collision
simulation on a real OpenStreetMap-based hotspot map. No build step, no
framework — plain HTML/CSS/JS + Leaflet + Chart.js via CDN.

## Run locally

```bash
cd web
python3 -m http.server 8000
# open http://localhost:8000
```

## Regenerate the data files

`data/hotspots.geojson`, `data/sim_config.json`, and `data/model_metrics.json`
are generated from the real cluster/evaluation data in `scratchpad_data/`.
Regenerate after re-running the model pipeline in `scripts/`:

```bash
python3 scripts/build_web_data.py
```

## Deploy (Render)

`render.yaml` at the repo root is a Render Blueprint. In the Render
dashboard: **New → Blueprint**, point it at this repo, and it will deploy
`web/` as a static site with no build step (the data files are pre-generated
and committed).
