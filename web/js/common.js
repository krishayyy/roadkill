// Shared helpers: nav active-state + number formatting used across pages.
function markActiveNav() {
  const path = location.pathname.split("/").pop() || "index.html";
  document.querySelectorAll(".nav-links a").forEach((a) => {
    if (a.getAttribute("href") === path) a.classList.add("active");
  });
}
document.addEventListener("DOMContentLoaded", markActiveNav);

function fmtInt(n) {
  return Math.round(n).toLocaleString("en-US");
}
function fmtUsd(n) {
  if (n >= 1_000_000) return "$" + (n / 1_000_000).toFixed(2) + "M";
  if (n >= 1_000) return "$" + (n / 1_000).toFixed(1) + "k";
  return "$" + fmtInt(n);
}
