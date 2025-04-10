let metricsData = [];
let sortKey = "";
let sortDirection = 1;

async function loadMetrics() {
  try {
    const response = await fetch(`metrics.json?t=${Date.now()}`);
    metricsData = await response.json();
    renderTable(metricsData);
  } catch (error) {
    console.error("Error loading metrics:", error);
  }
}

function renderTable(data) {
  const tableBody = document.querySelector("#repoTable tbody");
  tableBody.innerHTML = "";

  data.forEach(repo => {
    const row = `
      <tr>
        <td>${repo.repo}</td>
        <td>${repo.forked_from}</td>
        <td>${repo.open_issues}</td>
        <td>${repo.open_prs}</td>
        <td>${repo.triggered_on_push_or_pr ? "✅" : "❌"}</td>
        <td>${repo.release_version}</td>
        <td>${repo.tag}</td>
      </tr>`;
    tableBody.innerHTML += row;
  });
}

function sortByColumn(key) {
  if (sortKey === key) {
    sortDirection *= -1;
  } else {
    sortKey = key;
    sortDirection = 1;
  }

  const sorted = [...metricsData].sort((a, b) => {
    let valA = a[key] ?? "";
    let valB = b[key] ?? "";

    const isNumber = typeof valA === "number" && typeof valB === "number";
    if (!isNumber) {
      valA = valA.toString().toLowerCase();
      valB = valB.toString().toLowerCase();
    }

    return sortDirection * (valA > valB ? 1 : valA < valB ? -1 : 0);
  });

  renderTable(sorted);
  updateSortIndicators();
}

function updateSortIndicators() {
  document.querySelectorAll("th").forEach(th => {
    const key = th.dataset.key;
    th.classList.remove("asc", "desc");
    if (key === sortKey) {
      th.classList.add(sortDirection === 1 ? "asc" : "desc");
    }
  });
}

function downloadCSV() {
  let csv = "Repository,Forked From,Open Issues,Open PRs,CI Enabled,Latest Release Version,Latest Tag\n";
  metricsData.forEach(repo => {
    csv += `"${repo.repo}","${repo.forked_from || "-"}",${repo.open_issues},${repo.open_prs},${repo.triggered_on_push_or_pr ? "Yes" : "No"},"${repo.release_version || "-"}","${repo.tag || "-"}"\n`;
  });
  const blob = new Blob([csv], { type: "text/csv" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = "repo_metrics.csv";
  link.click();
  URL.revokeObjectURL(url);
}

document.addEventListener("DOMContentLoaded", () => {
  loadMetrics();

  document.querySelectorAll("th").forEach(th => {
    th.addEventListener("click", () => sortByColumn(th.dataset.key));
  });

  document.getElementById("darkToggle").addEventListener("click", () => {
    document.body.classList.toggle("dark");
  });

  document.getElementById("downloadCSV").addEventListener("click", downloadCSV);
});