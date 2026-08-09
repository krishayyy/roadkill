const POSITIVE = "#3f8a5c";
const NEGATIVE = "#c0392b";
const BASELINE = "#8a8171";
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
        label: "Real collision records",
        data: states.map(([, s]) => s.total_animal_collisions),
        backgroundColor: BASELINE,
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
        label: "Baseline collisions / year",
        data: states.map(([, s]) => s.baseline_annual_collisions),
        backgroundColor: BASELINE,
        borderRadius: 6,
      }],
    },
    options: baseOpts(),
  });
}

function renderRocAuc(model) {
  const entries = Object.entries(model.per_state_roc_auc);
  new Chart(document.getElementById("chart-roc"), {
    type: "bar",
    data: {
      labels: entries.map(([code]) => code),
      datasets: [{
        label: "ROC AUC (spatial CV)",
        data: entries.map(([, v]) => v.roc_auc),
        backgroundColor: POSITIVE,
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
      labels: ["Leaky", "Honest"],
      datasets: [{
        data: [model.leaky_vs_honest.leaky_random_split_roc_auc, model.leaky_vs_honest.honest_spatial_cv_roc_auc],
        backgroundColor: [NEGATIVE, POSITIVE],
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
        backgroundColor: BASELINE,
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

  document.getElementById("headline-auc").textContent = Math.round(model.headline.honest_roc_auc * 100) + "%";
  document.getElementById("headline-precision").textContent = Math.round(model.headline.honest_average_precision * 100) + "%";
  document.getElementById("headline-accuracy").textContent = Math.round(model.headline.honest_accuracy * 100) + "%";

  const tbody = document.getElementById("state-table-body");
  tbody.innerHTML = Object.entries(sim.states).map(([code, s]) => `
    <tr>
      <td><strong>${s.name}</strong></td>
      <td>${s.total_animal_collisions.toLocaleString()}</td>
      <td>${s.years}</td>
      <td>${Math.round(s.baseline_annual_collisions).toLocaleString()}</td>
      <td>${s.source}</td>
    </tr>
  `).join("");
});
