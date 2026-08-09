const POSITIVE = "#3f8a5c";
const NEGATIVE = "#c0392b";
const GOLD = "#c8944e";
const MUTED_GRID = "#e3d9c0";

fetch("data/eps_sweep.json").then((r) => r.json()).then((d) => {
  const sweep = [...d.sweep].sort((a, b) => a.eps_m - b.eps_m);
  const labels = sweep.map((p) => Math.round(p.eps_m));
  const values = sweep.map((p) => p.max_fraction * 100);
  const colors = sweep.map((p) => (p.accepted ? POSITIVE : NEGATIVE));

  new Chart(document.getElementById("chart-eps-sweep"), {
    type: "line",
    data: {
      labels,
      datasets: [
        {
          label: "Largest cluster's share of all points",
          data: values,
          borderColor: POSITIVE,
          backgroundColor: "rgba(63,138,92,0.12)",
          fill: true,
          tension: 0.25,
          pointBackgroundColor: colors,
          pointBorderColor: colors,
          pointRadius: sweep.map((p) => (Math.abs(p.eps_m - d.chosen_eps_m) < 1 ? 8 : 4)),
        },
        {
          label: "5% percolation limit",
          data: labels.map(() => d.max_cluster_fraction_limit * 100),
          borderColor: GOLD,
          borderDash: [6, 6],
          pointRadius: 0,
          fill: false,
        },
      ],
    },
    options: {
      responsive: true,
      plugins: {
        legend: { position: "bottom", labels: { boxWidth: 14 } },
        tooltip: {
          callbacks: {
            title: (items) => `eps = ${items[0].label} m`,
            label: (ctx) => ctx.datasetIndex === 0 ? `${ctx.formattedValue}% of all Iowa points in one cluster` : "5% limit",
          },
        },
      },
      scales: {
        x: { title: { display: true, text: "Candidate eps (meters) — DBSCAN neighborhood radius" }, grid: { display: false } },
        y: { title: { display: true, text: "% of state's points swallowed by largest cluster" }, grid: { color: MUTED_GRID }, beginAtZero: true },
      },
    },
  });

  document.getElementById("eps-chosen").textContent = Math.round(d.chosen_eps_m).toLocaleString() + " m";
  document.getElementById("eps-knee").textContent = Math.round(d.rejected_knee_eps_m).toLocaleString() + " m";
});
