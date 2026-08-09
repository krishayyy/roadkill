const GREEN = "#4c7a5e";
const GREEN_DARK = "#2f4a3b";
const GOLD = "#c8944e";
const TERRA = "#b1553d";
const MUTED_GRID = "#e3d9c0";

Chart.defaults.font.family = "Inter, sans-serif";
Chart.defaults.color = "#6b6555";

function baseOpts(extra) {
  return Object.assign({
    responsive: true,
    plugins: { legend: { display: false } },
    scales: {
      x: { grid: { display: false } },
      y: { grid: { color: MUTED_GRID }, beginAtZero: true },
    },
  }, extra || {});
}

async function loadData() {
  const [sim, model] = await Promise.all([
    fetch("data/sim_config.json").then((r) => r.json()),
    fetch("data/model_metrics.json").then((r) => r.json()),
  ]);
  return { sim, model };
}

function renderCollisionsByState(sim) {
  const states = Object.entries(sim.states);
  new Chart(document.getElementById("chart-collisions"), {
    type: "bar",
    data: {
      labels: states.map(([code]) => code),
      datasets: [{
        label: "Real animal-collision records",
        data: states.map(([, s]) => s.total_animal_collisions),
        backgroundColor: GREEN,
        borderRadius: 6,
      }],
    },
    options: baseOpts(),
  });
}

function renderAnnualRate(sim) {
  const states = Object.entries(sim.states);
  new Chart(document.getElementById("chart-annual"), {
    type: "bar",
    data: {
      labels: states.map(([code]) => code),
      datasets: [{
        label: "Baseline collisions / year (calibrated)",
        data: states.map(([, s]) => s.baseline_annual_collisions),
        backgroundColor: states.map(([, s]) => (s.years_confirmed ? GREEN : GOLD)),
        borderRadius: 6,
      }],
    },
    options: baseOpts({
      plugins: {
        legend: { display: false },
        tooltip: {
          callbacks: {
            afterLabel: (ctx) => {
              const s = states[ctx.dataIndex][1];
              return s.years_confirmed
                ? `Confirmed span: ${s.years} yr(s)`
                : `Assumed span: ${s.years} yr(s) — not confirmed in source metadata`;
            },
          },
        },
      },
    }),
  });
}

function renderRocAuc(model) {
  const entries = Object.entries(model.per_state_roc_auc);
  new Chart(document.getElementById("chart-roc"), {
    type: "bar",
    data: {
      labels: entries.map(([code]) => code),
      datasets: [{
        label: "Honest ROC AUC (spatial CV)",
        data: entries.map(([, v]) => v.roc_auc),
        backgroundColor: GREEN_DARK,
        borderRadius: 6,
      }],
    },
    options: baseOpts({ scales: { x: { grid: { display: false } }, y: { min: 0.5, max: 1, grid: { color: MUTED_GRID } } } }),
  });
}

function renderLeakyVsHonest(model) {
  new Chart(document.getElementById("chart-leaky"), {
    type: "bar",
    data: {
      labels: ["Leaky random split", "Honest spatial CV"],
      datasets: [{
        data: [model.leaky_vs_honest.leaky_random_split_roc_auc, model.leaky_vs_honest.honest_spatial_cv_roc_auc],
        backgroundColor: [TERRA, GREEN],
        borderRadius: 6,
      }],
    },
    options: baseOpts({ indexAxis: "y", scales: { x: { min: 0.5, max: 1, grid: { color: MUTED_GRID } }, y: { grid: { display: false } } } }),
  });
}

function renderFeatureImportance(model) {
  const entries = Object.entries(model.feature_importances)
    .filter(([, v]) => v > 0)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 8);
  new Chart(document.getElementById("chart-features"), {
    type: "bar",
    data: {
      labels: entries.map(([k]) => k.replace(/_/g, " ")),
      datasets: [{
        data: entries.map(([, v]) => v),
        backgroundColor: GREEN,
        borderRadius: 6,
      }],
    },
    options: baseOpts({ indexAxis: "y", scales: { x: { grid: { color: MUTED_GRID } }, y: { grid: { display: false } } } }),
  });
}

loadData().then(({ sim, model }) => {
  renderCollisionsByState(sim);
  renderAnnualRate(sim);
  renderRocAuc(model);
  renderLeakyVsHonest(model);
  renderFeatureImportance(model);

  document.getElementById("headline-auc").textContent = model.headline.honest_roc_auc.toFixed(3);
  document.getElementById("headline-precision").textContent = model.headline.honest_average_precision.toFixed(3);
  document.getElementById("headline-accuracy").textContent = (model.headline.honest_accuracy * 100).toFixed(1) + "%";

  const tbody = document.getElementById("state-table-body");
  tbody.innerHTML = Object.entries(sim.states).map(([code, s]) => `
    <tr>
      <td><strong>${s.name}</strong> <span class="pill pill-muted">${code}</span></td>
      <td>${s.total_animal_collisions.toLocaleString()}</td>
      <td>${s.years}${s.years_confirmed ? "" : " (assumed)"}</td>
      <td>${Math.round(s.baseline_annual_collisions).toLocaleString()}</td>
      <td>${s.source}</td>
    </tr>
  `).join("");
});
