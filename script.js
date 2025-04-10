document.addEventListener("DOMContentLoaded", () => {
    loadMetrics();
    document.getElementById("download-csv").addEventListener("click", downloadCSV);
  });
  
  let currentSort = { column: null, order: 'asc' };
  
  async function loadMetrics() {
    try {
      const response = await fetch(`metrics.json?t=${new Date().getTime()}`);
      const data = await response.json();
      renderTable(data);
    } catch (err) {
      console.error("Error loading metrics:", err);
    }
  }
  
  function renderTable(data) {
    const tbody = document.querySelector("#repoTable tbody");
    tbody.innerHTML = "";
  
    data.forEach(repo => {
      const row = document.createElement("tr");
      row.innerHTML = `
        <td>${repo.repo}</td>
        <td>${repo.forked_from}</td>
        <td>${repo.open_issues}</td>
        <td>${repo.open_prs}</td>
        <td>${repo.triggered_on_push_or_pr ? "✅" : "❌"}</td>
        <td>${repo.release_version}</td>
        <td>${repo.tag}</td>
      `;
      tbody.appendChild(row);
    });
  
    addSorting(data);
  }
  
  function addSorting(data) {
    const headers = document.querySelectorAll("th");
    headers.forEach(header => {
      const column = header.getAttribute("data-column");
      header.onclick = () => {
        const newOrder = (currentSort.column === column && currentSort.order === 'asc') ? 'desc' : 'asc';
        currentSort = { column, order: newOrder };
  
        headers.forEach(h => h.classList.remove('asc', 'desc'));
        header.classList.add(newOrder);
  
        const sortedData = [...data].sort((a, b) => {
          const valA = a[column] || '';
          const valB = b[column] || '';
          return newOrder === 'asc'
            ? valA.toString().localeCompare(valB.toString())
            : valB.toString().localeCompare(valA.toString());
        });
  
        renderTable(sortedData);
      };
    });
  }
  
  function downloadCSV() {
    const rows = Array.from(document.querySelectorAll("table tr"));
    const csv = rows.map(row =>
      Array.from(row.querySelectorAll("th, td"))
        .map(cell => `"${cell.textContent.trim()}"`).join(",")
    ).join("\n");
  
    const blob = new Blob([csv], { type: "text/csv;charset=utf-8;" });
    const url = URL.createObjectURL(blob);
  
    const link = document.createElement("a");
    link.href = url;
    link.setAttribute("download", "metrics.csv");
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
  }