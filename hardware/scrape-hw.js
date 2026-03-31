// Run this in your browser DevTools console on:
// https://www.cosmos-lab.org/portal/status/hardware-search
//
// 1. Set filters to show ALL nodes (or clear all filters)
// 2. Open DevTools (F12) -> Console
// 3. Paste this script and press Enter
// 4. It clicks through all pages and collects every row
// 5. Outputs CSV to console — copy/paste or download

(async function scrapeHardwareTable() {
  const delay = ms => new Promise(r => setTimeout(r, ms));
  const allRows = [];

  // Headers from the table
  const headers = [
    'Node', 'Domain', 'Type', 'Category', 'CPU', 'RAM', 'Disk',
    'GPU', 'FPGA', 'USRP', 'WiFi', 'Devices'
  ];

  let page = 1;
  let totalPages = 1;

  while (page <= totalPages) {
    // Parse current page info
    const pageInfo = document.querySelector('span[class*="text-slate"]');
    const pageSpans = [...document.querySelectorAll('span')].filter(
      s => s.textContent.match(/Page \d+\/\d+/)
    );
    if (pageSpans.length > 0) {
      const m = pageSpans[0].textContent.match(/Page (\d+)\/(\d+)/);
      if (m) totalPages = parseInt(m[2]);
    }

    // Extract rows from the current page
    const tbody = document.querySelector('table tbody');
    if (tbody) {
      const rows = tbody.querySelectorAll('tr');
      for (const row of rows) {
        const cells = row.querySelectorAll('td');
        const rowData = {};
        cells.forEach((cell, i) => {
          // Use title attribute if available (has full text when truncated)
          const val = cell.getAttribute('title') || cell.textContent.trim();
          rowData[headers[i] || `col${i}`] = val;
        });
        if (rowData.Node) allRows.push(rowData);
      }
    }

    console.log(`Scraped page ${page}/${totalPages} (${allRows.length} rows so far)`);

    // Click Next if not on last page
    if (page < totalPages) {
      const nextBtn = [...document.querySelectorAll('button')].find(
        b => b.textContent.trim() === 'Next' && !b.disabled
      );
      if (nextBtn) {
        nextBtn.click();
        await delay(1500); // Wait for page to load
      } else {
        console.warn('Next button not found or disabled — stopping');
        break;
      }
    }
    page++;
  }

  // Build CSV
  const csvLines = [headers.join(',')];
  for (const row of allRows) {
    const line = headers.map(h => {
      const val = (row[h] || '-').replace(/"/g, '""');
      return `"${val}"`;
    });
    csvLines.push(line.join(','));
  }
  const csv = csvLines.join('\n');

  // Output to console
  console.log(`\n=== DONE: ${allRows.length} nodes scraped ===\n`);
  console.log(csv);

  // Auto-download as file
  const blob = new Blob([csv], { type: 'text/csv' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = 'cosmos_hardware_inventory.csv';
  a.click();
  URL.revokeObjectURL(url);

  console.log('CSV file downloaded as cosmos_hardware_inventory.csv');
  return allRows;
})();
