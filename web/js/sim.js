const TICKS = 180;
const TICK_MS = 55;

let map, hotspotLayer, eventLayer;
let allFeatures = [];
let sim = null;
let currentScope = "ALL";
let adoption = 0.4;
let running = false;
let tickTimer = null;
let cum = { occurred: 0, prevented: 0 };
let sweepChart;

async function init() {
  const [hotspotsResp, simConfig] = await Promise.all([
    fetch("data/hotspots.geojson").then((r) => r.json()),
    fetch("data/sim_config.json").then((r) => r.json()),
  ]);
  allFeatures = hotspotsResp.features;
  sim = simConfig;

  map = L.map("map", { scrollWheelZoom: false }).setView([39.5, -87], 5);
  L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
    attribution: "&copy; OpenStreetMap contributors",
    maxZoom: 12,
  }).addTo(map);

  hotspotLayer = L.layerGroup().addTo(map);
  eventLayer = L.layerGroup().addTo(map);

  document.querySelectorAll(".tab-btn").forEach((btn) => {
    btn.addEventListener("click", () => setScope(btn.dataset.state));
  });

  const slider = document.getElementById("adoption-slider");
  slider.addEventListener("input", (e) => {
    adoption = Number(e.target.value) / 100;
    document.getElementById("adoption-value").textContent = e.target.value + "%";
    renderSweepChart();
    if (!running) updateKpisDeterministic();
  });

  document.getElementById("run-btn").addEventListener("click", runYear);
  document.getElementById("reset-btn").addEventListener("click", resetSim);

  setScope("ALL");
}

function scopedFeatures(scope) {
  return scope === "ALL" ? allFeatures : allFeatures.filter((f) => f.properties.state === scope);
}

function scopedBaseline(scope) {
  return scope === "ALL" ? sim.all.baseline_annual_collisions : sim.states[scope].baseline_annual_collisions;
}

function setScope(scope) {
  currentScope = scope;
  document.querySelectorAll(".tab-btn").forEach((b) => b.classList.toggle("active", b.dataset.state === scope));
  const note = document.getElementById("scope-note");
  if (scope === "ALL") {
    note.textContent = "Illinois is a single year (2023) and dominates the combined rate. Per-state sourcing on the Data page.";
  } else {
    const s = sim.states[scope];
    note.textContent = `Source: ${s.source}. ${s.years}-year span.`;
  }
  drawHotspots();
  fitBounds();
  resetSim();
  renderSweepChart();
}

const SEVERITY_FROM = [200, 148, 78];   // gold, low severity
const SEVERITY_TO = [192, 57, 43];      // red, high severity

function severityColor(t) {
  t = Math.max(0, Math.min(1, t));
  const rgb = SEVERITY_FROM.map((c, i) => Math.round(c + (SEVERITY_TO[i] - c) * t));
  return `rgb(${rgb[0]},${rgb[1]},${rgb[2]})`;
}

function drawHotspots() {
  hotspotLayer.clearLayers();
  const feats = scopedFeatures(currentScope);
  const sevs = feats.map((f) => Math.sqrt(f.properties.severity));
  const minS = Math.min(...sevs);
  const maxS = Math.max(...sevs);
  feats.forEach((f) => {
    const [lon, lat] = f.geometry.coordinates;
    const p = f.properties;
    const r = Math.max(3, Math.min(14, Math.sqrt(p.severity) * 0.5));
    const t = maxS > minS ? (Math.sqrt(p.severity) - minS) / (maxS - minS) : 0.5;
    const color = severityColor(t);
    L.circleMarker([lat, lon], {
      radius: r,
      color,
      weight: 1,
      fillColor: color,
      fillOpacity: 0.55,
    })
      .bindPopup(
        `<strong>${p.county || "Unknown county"} (${p.state})</strong><br>${p.severity.toLocaleString()} real historical crashes clustered here<br>~${(p.share_of_state * 100).toFixed(1)}% of ${p.state}'s clustered total`
      )
      .addTo(hotspotLayer);
  });
}

function fitBounds() {
  const feats = scopedFeatures(currentScope);
  if (!feats.length) return;
  const bounds = L.latLngBounds(feats.map((f) => [f.geometry.coordinates[1], f.geometry.coordinates[0]]));
  map.fitBounds(bounds.pad(0.15));
}

function weightedRandomFeature(feats) {
  const total = feats.reduce((s, f) => s + f.properties.severity, 0);
  let r = Math.random() * total;
  for (const f of feats) {
    r -= f.properties.severity;
    if (r <= 0) return f;
  }
  return feats[feats.length - 1];
}

function resetSim() {
  clearInterval(tickTimer);
  running = false;
  document.getElementById("run-btn").textContent = "Run 1 simulated year ▶";
  document.getElementById("run-btn").disabled = false;
  eventLayer.clearLayers();
  cum = { occurred: 0, prevented: 0 };
  updateKpisDeterministic();
}

function setKpis(baseline, occurred, prevented) {
  setText("kpi-baseline", fmtInt(baseline));
  setText("kpi-occurred", fmtInt(occurred));
  setText("kpi-prevented", fmtInt(prevented));
  setText("kpi-cost", fmtUsd(prevented * sim.cost_per_collision_usd));
  setText("kpi-injuries", fmtInt(prevented * sim.injury_rate_per_collision));
  setText("kpi-animals", fmtInt(prevented));
  setText("kpi-reduction", (baseline > 0 ? Math.round((prevented / baseline) * 100) : 0) + "%");
}

function updateKpisDeterministic() {
  const baseline = scopedBaseline(currentScope);
  const prevented = baseline * adoption * sim.alert_effectiveness;
  setKpis(baseline, baseline - prevented, prevented);
}

function setText(id, v) {
  document.getElementById(id).textContent = v;
}

function runYear() {
  if (running) return;
  running = true;
  document.getElementById("run-btn").textContent = "Running…";
  document.getElementById("run-btn").disabled = true;
  eventLayer.clearLayers();
  cum = { occurred: 0, prevented: 0 };
  const feats = scopedFeatures(currentScope);
  const baseline = scopedBaseline(currentScope);
  const perTick = baseline / TICKS;
  const pPrevented = adoption * sim.alert_effectiveness;
  let tick = 0;

  tickTimer = setInterval(() => {
    tick++;
    const prevented = Math.random() < pPrevented;
    const feat = weightedRandomFeature(feats);
    dropEventMarker(feat, prevented);
    if (prevented) cum.prevented += perTick;
    else cum.occurred += perTick;

    setKpis(baseline, cum.occurred, cum.prevented);

    if (tick >= TICKS) {
      clearInterval(tickTimer);
      running = false;
      document.getElementById("run-btn").textContent = "Run again ▶";
      document.getElementById("run-btn").disabled = false;
    }
  }, TICK_MS);
}

function dropEventMarker(feat, prevented) {
  const [lon, lat] = feat.geometry.coordinates;
  const jitter = () => (Math.random() - 0.5) * 0.06;
  const marker = L.circleMarker([lat + jitter(), lon + jitter()], {
    radius: 7,
    color: prevented ? "#3f8a5c" : "#c0392b",
    fillColor: prevented ? "#3f8a5c" : "#c0392b",
    fillOpacity: 0.85,
    weight: 2,
  }).addTo(eventLayer);
  setTimeout(() => eventLayer.removeLayer(marker), 1300);
}

function renderSweepChart() {
  const baseline = scopedBaseline(currentScope);
  const steps = [];
  for (let a = 0; a <= 100; a += 10) steps.push(a);
  const collisions = steps.map((a) => baseline - baseline * (a / 100) * sim.alert_effectiveness);
  const ctx = document.getElementById("chart-sweep");
  if (sweepChart) sweepChart.destroy();
  sweepChart = new Chart(ctx, {
    type: "line",
    data: {
      labels: steps.map((s) => s + "%"),
      datasets: [
        {
          label: "Simulated annual collisions",
          data: collisions,
          borderColor: "#3f8a5c",
          backgroundColor: "rgba(63,138,92,0.15)",
          fill: true,
          tension: 0.35,
          pointRadius: 3,
        },
      ],
    },
    options: {
      responsive: true,
      plugins: {
        legend: { display: false },
        tooltip: { callbacks: { title: (items) => `Adoption: ${items[0].label}` } },
      },
      scales: {
        x: { title: { display: true, text: "App adoption rate" }, grid: { display: false } },
        y: { grid: { color: "#e3d9c0" }, title: { display: true, text: "Annual collisions" } },
      },
    },
  });
}

init();
