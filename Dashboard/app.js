// ====== CONFIG — loaded from config.js (generated from the root .env) ======
// Run `python scripts/build_dashboard_config.py` after editing .env.
const { API_URL = "", SECRET = "" } = window.FINANCE_CONFIG || {};
if (!API_URL || !SECRET) {
  console.error(
    "Dashboard config missing: run `python scripts/build_dashboard_config.py` to create Dashboard/config.js from .env"
  );
}
// ===================================================================

// ---- category catalogue (shared by the form dropdown) ----
const CATEGORIES = {
  expense: [
    "Food & Drink",
    "Groceries",
    "Transport",
    "Shopping",
    "Paylater",
    "Bills & Utilities",
    "Rent / Mortgage",
    "Health",
    "Entertainment",
    "Education",
    "Subscriptions",
    "Travel",
    "Gifts & Donations",
    "Family",
    "Fees & Charges",
    "Other",
  ],
  income: [
    "Salary",
    "Bonus",
    "Freelance",
    "Business",
    "Investment Income",
    "Asset Sale",
    "Gift",
    "Refund",
    "Other",
  ],
  invest: ["Stocks", "Gold", "Mutual Fund", "Crypto", "Other"],
};

let period = "monthly";
let allTxns = []; // full transaction cache (fetched once per load)
let tablePage = 1;
let sortCol = "date",
  sortDir = "desc";
let allHoldings = []; // holdings cache
let holdPage = 1;
let holdSortCol = "buyDate",
  holdSortDir = "desc";
let categoryChart = null; // Chart.js instance for expenses-by-category

const fmt = (v) => "Rp " + Math.round(v).toLocaleString("id-ID");

document.getElementById("filters").addEventListener("click", (e) => {
  if (e.target.tagName !== "BUTTON") return;
  period = e.target.dataset.p;
  document
    .querySelectorAll("#filters button")
    .forEach((b) => b.classList.remove("active"));
  e.target.classList.add("active");
  load();
});

async function load() {
  setStatus("Loading…");
  try {
    const sumRes = await fetch(
      `${API_URL}?action=summary&period=${period}&secret=${SECRET}`,
    );
    const sum = (await sumRes.json()).data;
    renderMetrics(sum);

    const accRes = await fetch(`${API_URL}?action=accounts&secret=${SECRET}`);
    const accData = (await accRes.json()).data;
    renderBalances(accData);

    const allRes = await fetch(`${API_URL}?action=read&secret=${SECRET}`);
    allTxns = (await allRes.json()).data || [];
    tablePage = 1;
    applyTableView();
    renderCategoryChart();
    setStatus(`Synced • ${allTxns.length} total transactions`);
  } catch (err) {
    setStatus("Error: " + err.message);
  }
  loadHoldings();
}

// ---- expenses-by-category chart (respects the active period) ----

function periodStartDate() {
  // returns a YYYY-MM-DD lower bound for the active period, or "" for all-time
  const now = new Date();
  const pad = (n) => String(n).padStart(2, "0");
  const ymd = (d) =>
    `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  if (period === "daily") {
    return ymd(now);
  }
  if (period === "monthly") {
    return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-01`;
  }
  if (period === "quarterly") {
    const qStartMonth = Math.floor(now.getMonth() / 3) * 3;
    return `${now.getFullYear()}-${pad(qStartMonth + 1)}-01`;
  }
  if (period === "yearly") {
    return `${now.getFullYear()}-01-01`;
  }
  return "";
}

function getExpenseByCategory() {
  const from = periodStartDate();
  const totals = {};
  for (const t of allTxns) {
    if (t.type !== "expense") continue;
    if (from && (t.date || "") < from) continue;
    const cat = t.category || "Other";
    totals[cat] = (totals[cat] || 0) + (Number(t.amount) || 0);
  }
  // sort categories by spend, largest first
  return Object.entries(totals).sort((a, b) => b[1] - a[1]);
}

function renderCategoryChart() {
  const entries = getExpenseByCategory();
  const labels = entries.map((e) => e[0]);
  const values = entries.map((e) => e[1]);
  const grand = values.reduce((s, v) => s + v, 0);

  document.getElementById("cat-total").textContent = grand
    ? `Total ${fmt(grand)}`
    : "";

  const emptyEl = document.getElementById("cat-empty");
  const canvas = document.getElementById("cat-chart");

  if (!entries.length) {
    emptyEl.style.display = "block";
    canvas.style.display = "none";
    if (categoryChart) {
      categoryChart.destroy();
      categoryChart = null;
    }
    return;
  }
  emptyEl.style.display = "none";
  canvas.style.display = "block";

  const palette = [
    "#a32d2d",
    "#185fa5",
    "#0f6e56",
    "#92591b",
    "#6b3fa0",
    "#c2701f",
    "#2c8c8c",
    "#b03a6e",
    "#4a7a2c",
    "#8a8a3a",
    "#3a6ea5",
    "#9a4a2c",
    "#5a5a8c",
    "#2c8c5a",
    "#a05a3a",
    "#777",
  ];
  const colors = labels.map((_, i) => palette[i % palette.length]);

  if (categoryChart) categoryChart.destroy();
  categoryChart = new Chart(canvas.getContext("2d"), {
    type: "doughnut",
    data: {
      labels,
      datasets: [
        {
          data: values,
          backgroundColor: colors,
          borderColor: "#fff",
          borderWidth: 2,
        },
      ],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      cutout: "58%",
      plugins: {
        legend: {
          position: "right",
          labels: { boxWidth: 12, font: { size: 12 }, padding: 10 },
        },
        tooltip: {
          callbacks: {
            label: (ctx) => {
              const v = ctx.parsed;
              const pct = grand ? ((v / grand) * 100).toFixed(1) : 0;
              return ` ${ctx.label}: ${fmt(v)} (${pct}%)`;
            },
          },
        },
      },
    },
  });
}

async function loadHoldings() {
  document.getElementById("port-status").textContent = "Loading holdings…";
  try {
    const res = await fetch(`${API_URL}?action=holdings&secret=${SECRET}`);
    allHoldings = (await res.json()).data || [];
    holdPage = 1;
    applyHoldView();
  } catch (err) {
    document.getElementById("port-status").textContent =
      "Could not load holdings: " + err.message;
  }
}

function onHoldControl() {
  holdPage = 1;
  applyHoldView();
}

function resetHoldControls() {
  document.getElementById("h-search").value = "";
  document.getElementById("h-filter-type").value = "";
  holdSortCol = "buyDate";
  holdSortDir = "desc";
  holdPage = 1;
  applyHoldView();
}

function setHoldSort(col) {
  if (holdSortCol === col) {
    holdSortDir = holdSortDir === "asc" ? "desc" : "asc";
  } else {
    holdSortCol = col;
    holdSortDir =
      col === "buyValue" ||
      col === "buyPrice" ||
      col === "quantity" ||
      col === "buyDate"
        ? "desc"
        : "asc";
  }
  applyHoldView();
}

function getHoldFilteredSorted() {
  const q = document.getElementById("h-search").value.trim().toLowerCase();
  const type = document.getElementById("h-filter-type").value;
  let rows = allHoldings.map((h) => ({
    ...h,
    buyValue: (h.quantity || 0) * (h.buyPrice || 0),
  }));
  rows = rows.filter((h) => {
    if (type && h.assetType !== type) return false;
    if (q) {
      const hay =
        `${h.name || ""} ${h.ticker || ""} ${h.assetType || ""}`.toLowerCase();
      if (!hay.includes(q)) return false;
    }
    return true;
  });
  const dir = holdSortDir === "asc" ? 1 : -1;
  rows.sort((a, b) => {
    let av = a[holdSortCol],
      bv = b[holdSortCol];
    if (
      holdSortCol === "buyValue" ||
      holdSortCol === "buyPrice" ||
      holdSortCol === "quantity"
    ) {
      av = +av || 0;
      bv = +bv || 0;
    } else if (holdSortCol === "label") {
      av = (a.name || a.ticker || a.assetType || "").toLowerCase();
      bv = (b.name || b.ticker || b.assetType || "").toLowerCase();
    } else {
      av = String(av || "").toLowerCase();
      bv = String(bv || "").toLowerCase();
    }
    return av < bv ? -dir : av > bv ? dir : 0;
  });
  return rows;
}

function applyHoldView() {
  const rows = getHoldFilteredSorted();
  const size = +document.getElementById("h-size").value;
  const pages = Math.max(1, Math.ceil(rows.length / size));
  if (holdPage > pages) holdPage = pages;
  const start = (holdPage - 1) * size;
  const pageRows = rows.slice(start, start + size);

  document.querySelectorAll("th[data-hcol]").forEach((th) => {
    const isSort = th.dataset.hcol === holdSortCol;
    th.classList.toggle("sorted", isSort);
    th.querySelector(".arrow").textContent = isSort
      ? holdSortDir === "asc"
        ? "▲"
        : "▼"
      : "▾";
  });

  const tbody = document.getElementById("holdings-body");
  const grandTotal = rows.reduce((s, h) => s + h.buyValue, 0);
  if (!pageRows.length) {
    tbody.innerHTML =
      '<tr class="empty-row"><td colspan="6">No holdings match your filters.</td></tr>';
  } else {
    tbody.innerHTML = pageRows
      .map((h) => {
        const unit = h.assetType === "gold" ? "gr" : "sh";
        const pill = h.assetType === "gold" ? "transfer" : "invest";
        const delBtn = h.id
          ? `<button class="del-btn" onclick="delHolding('${h.id}')" title="Delete">✕</button>`
          : '<span style="color:#ccc" title="Legacy row — delete in the sheet">–</span>';
        return `<tr>
          <td><strong>${escapeHtml(h.name || h.ticker || h.assetType)}</strong>${h.ticker ? ` <span class="pill ${pill}" style="margin-left:4px">${escapeHtml(h.ticker)}</span>` : ""}</td>
          <td style="white-space:nowrap">${h.quantity}${unit}</td>
          <td style="white-space:nowrap">${fmt(h.buyPrice)}</td>
          <td style="white-space:nowrap">${h.buyDate || "—"}</td>
          <td style="text-align:right;white-space:nowrap">${fmt(h.buyValue)}</td>
          <td>${delBtn}</td>
        </tr>`;
      })
      .join("");
  }
  renderHoldPager(rows.length, pages, start, pageRows.length);
  document.getElementById("port-status").textContent =
    `${rows.length} holding(s) shown • total buy value ${fmt(grandTotal)}`;
}

function renderHoldPager(total, pages, start, shown) {
  const el = document.getElementById("holdings-pager");
  if (!total || pages <= 1) {
    el.innerHTML = total ? `<span class="info">${total} holding(s)</span>` : "";
    return;
  }
  let btns = "";
  const win = 2;
  const lo = Math.max(1, holdPage - win),
    hi = Math.min(pages, holdPage + win);
  const mk = (p, lbl, dis, act) =>
    `<button ${dis ? "disabled" : ""} class="${act ? "active" : ""}" onclick="gotoHoldPage(${p})">${lbl || p}</button>`;
  btns += mk(holdPage - 1, "‹", holdPage === 1);
  if (lo > 1) {
    btns += mk(1);
    if (lo > 2) btns += '<span class="info">…</span>';
  }
  for (let p = lo; p <= hi; p++) btns += mk(p, null, false, p === holdPage);
  if (hi < pages) {
    if (hi < pages - 1) btns += '<span class="info">…</span>';
    btns += mk(pages);
  }
  btns += mk(holdPage + 1, "›", holdPage === pages);
  el.innerHTML = `<span class="info">Showing ${start + 1}–${start + shown} of ${total}</span>
       <span class="pages">${btns}</span>`;
}

function gotoHoldPage(p) {
  holdPage = p;
  applyHoldView();
}

// ----- category dropdown helpers -----

function fillCategoryOptions(type) {
  const sel = document.getElementById("f-cat");
  const list = CATEGORIES[type] || CATEGORIES.expense;
  const current = sel.value;
  sel.innerHTML = list
    .map((c) => `<option value="${escapeHtml(c)}">${escapeHtml(c)}</option>`)
    .join("");
  // keep selection if still valid, else default to first
  if (list.includes(current)) sel.value = current;
}

// ----- Investment fields on the main form -----

function onTxnType() {
  const type = document.getElementById("f-type").value;
  const isInvest = type === "invest";
  document.getElementById("invest-fields").style.display = isInvest
    ? "flex"
    : "none";
  document.getElementById("f-amount-wrap").style.display = isInvest
    ? "none"
    : "";
  fillCategoryOptions(type);
  if (isInvest) {
    onAssetTypeMain();
    syncInvestAmount();
  }
}

function onAssetTypeMain() {
  const isGold = document.getElementById("f-asset").value === "gold";
  document.getElementById("f-ticker-wrap").style.display = "";
  if (isGold && !document.getElementById("f-ticker").value) {
    document.getElementById("f-ticker").value = "LM";
  }
  document.getElementById("f-ticker").placeholder = isGold ? "LM" : "BBCA";
  document.getElementById("f-qty-label").textContent = isGold
    ? "Quantity (grams)"
    : "Quantity (shares)";
  document.getElementById("f-buyprice-label").textContent = isGold
    ? "Buy price / gram"
    : "Buy price / share";
  document.getElementById("f-asset-name").placeholder = isGold
    ? "Antam"
    : "Bank Central Asia";
  // align the category with the asset type for convenience
  const cat = document.getElementById("f-cat");
  if (CATEGORIES.invest.includes(isGold ? "Gold" : "Stocks")) {
    cat.value = isGold ? "Gold" : "Stocks";
  }
}

function syncInvestAmount() {
  const qty = parseFloat(document.getElementById("f-qty").value) || 0;
  const bp = parseFloat(document.getElementById("f-buyprice").value) || 0;
  const total = qty * bp;
  document.getElementById("f-amount").value = total || "";
  document.getElementById("f-invest-total").textContent = fmt(total);
}

async function delHolding(id) {
  if (!confirm("Delete this holding?")) return;
  await fetch(API_URL, {
    method: "POST",
    headers: { "Content-Type": "text/plain;charset=utf-8" },
    body: JSON.stringify({ action: "deleteHolding", secret: SECRET, id }),
  });
  loadHoldings();
}

function renderBalances(data) {
  if (!data || !data.balances) return;
  const order = (data.accounts || []).concat(
    Object.keys(data.balances).filter(
      (a) => !(data.accounts || []).includes(a),
    ),
  );
  document.getElementById("acct-balances").innerHTML = order
    .map((acc) => {
      const bal = data.balances[acc] || 0;
      const color = bal >= 0 ? "#0F6E56" : "#A32D2D";
      return `<div class="metric" style="flex:1;min-width:130px">
        <div class="label">💳 ${acc}</div>
        <div class="val" style="color:${color};font-size:18px">${fmt(bal)}</div></div>`;
    })
    .join("");
}

function renderMetrics(s) {
  document.getElementById("metrics").innerHTML = `
      <div class="metric"><div class="label">Income</div><div class="val income">${fmt(s.income)}</div></div>
      <div class="metric"><div class="label">Expenses</div><div class="val expense">${fmt(s.expense)}</div></div>
      <div class="metric"><div class="label">Investments</div><div class="val invest">${fmt(s.invest)}</div></div>
      <div class="metric"><div class="label">Net Balance</div><div class="val">${fmt(s.net)}</div><div class="label" style="margin-top:4px">${s.savingsRate}% savings rate</div></div>`;
}

// ---- table controls: search, filter, date-range, sort, paginate (all in-memory) ----

function onTableControl() {
  tablePage = 1;
  applyTableView();
}

function resetTableControls() {
  document.getElementById("tbl-search").value = "";
  document.getElementById("tbl-type").value = "";
  document.getElementById("acct-filter").value = "";
  document.getElementById("tbl-from").value = "";
  document.getElementById("tbl-to").value = "";
  sortCol = "date";
  sortDir = "desc";
  tablePage = 1;
  applyTableView();
}

function setSort(col) {
  if (sortCol === col) {
    sortDir = sortDir === "asc" ? "desc" : "asc";
  } else {
    sortCol = col;
    sortDir = col === "amount" || col === "date" ? "desc" : "asc";
  }
  applyTableView();
}

function getFilteredSorted() {
  const q = document.getElementById("tbl-search").value.trim().toLowerCase();
  const type = document.getElementById("tbl-type").value;
  const acct = document.getElementById("acct-filter").value;
  const from = document.getElementById("tbl-from").value;
  const to = document.getElementById("tbl-to").value;

  let rows = allTxns.filter((t) => {
    if (
      q &&
      !(
        (t.description || "").toLowerCase().includes(q) ||
        (t.category || "").toLowerCase().includes(q)
      )
    )
      return false;
    if (type) {
      if (type === "transfer") {
        if (!String(t.type).startsWith("transfer")) return false;
      } else if (t.type !== type) return false;
    }
    if (acct && (t.account || "Unassigned") !== acct) return false;
    if (from && t.date < from) return false;
    if (to && t.date > to) return false;
    return true;
  });

  const dir = sortDir === "asc" ? 1 : -1;
  rows.sort((a, b) => {
    let av = a[sortCol],
      bv = b[sortCol];
    if (sortCol === "amount") {
      av = +av || 0;
      bv = +bv || 0;
    } else {
      av = String(av || "").toLowerCase();
      bv = String(bv || "").toLowerCase();
    }
    return av < bv ? -dir : av > bv ? dir : 0;
  });
  return rows;
}

function applyTableView() {
  const rows = getFilteredSorted();
  const size = +document.getElementById("tbl-size").value;
  const pages = Math.max(1, Math.ceil(rows.length / size));
  if (tablePage > pages) tablePage = pages;
  const start = (tablePage - 1) * size;
  const pageRows = rows.slice(start, start + size);

  document.querySelectorAll("th.sortable").forEach((th) => {
    const isSort = th.dataset.col === sortCol;
    th.classList.toggle("sorted", isSort);
    th.querySelector(".arrow").textContent = isSort
      ? sortDir === "asc"
        ? "▲"
        : "▼"
      : "▾";
  });

  const tbody = document.getElementById("txn-body");
  if (!pageRows.length) {
    tbody.innerHTML =
      '<tr class="empty-row"><td colspan="6">No transactions match your filters.</td></tr>';
  } else {
    tbody.innerHTML = pageRows
      .map((t) => {
        const cls =
          {
            income: "income",
            expense: "expense",
            invest: "invest",
            "transfer-in": "income",
            "transfer-out": "expense",
          }[t.type] || "";
        const pfx =
          {
            income: "+",
            expense: "-",
            invest: "~",
            "transfer-in": "+",
            "transfer-out": "-",
          }[t.type] || "";
        const pillCls = String(t.type).startsWith("transfer")
          ? "transfer"
          : cls || "invest";
        const typeLabel =
          {
            "transfer-in": "transfer ⬇",
            "transfer-out": "transfer ⬆",
            income: "income",
            expense: "expense",
            invest: "investment",
          }[t.type] || t.type;
        return `<tr>
          <td style="white-space:nowrap">${t.date}</td>
          <td>${escapeHtml(t.description)}</td>
          <td>${escapeHtml(t.category)}</td>
          <td><span class="pill ${pillCls}">${typeLabel}</span></td>
          <td>${t.account || "—"}</td>
          <td class="${cls}" style="text-align:right;white-space:nowrap">${pfx}${fmt(t.amount)}</td>
        </tr>`;
      })
      .join("");
  }
  renderPager(rows.length, pages, start, pageRows.length);
}

function renderPager(total, pages, start, shown) {
  const el = document.getElementById("txn-pager");
  if (!total) {
    el.innerHTML = "";
    return;
  }
  let btns = "";
  const win = 2;
  const lo = Math.max(1, tablePage - win),
    hi = Math.min(pages, tablePage + win);
  const mk = (p, lbl, dis, act) =>
    `<button ${dis ? "disabled" : ""} class="${act ? "active" : ""}" onclick="gotoPage(${p})">${lbl || p}</button>`;
  btns += mk(tablePage - 1, "‹", tablePage === 1);
  if (lo > 1) {
    btns += mk(1);
    if (lo > 2) btns += '<span class="info">…</span>';
  }
  for (let p = lo; p <= hi; p++) btns += mk(p, null, false, p === tablePage);
  if (hi < pages) {
    if (hi < pages - 1) btns += '<span class="info">…</span>';
    btns += mk(pages);
  }
  btns += mk(tablePage + 1, "›", tablePage === pages);
  el.innerHTML = `<span class="info">Showing ${start + 1}–${start + shown} of ${total}</span>
       <span class="pages">${btns}</span>`;
}

function gotoPage(p) {
  tablePage = p;
  applyTableView();
}

function escapeHtml(s) {
  return String(s == null ? "" : s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

async function addTxn() {
  const type = document.getElementById("f-type").value;
  const date =
    document.getElementById("f-date").value ||
    new Date().toISOString().split("T")[0];
  const isInvest = type === "invest";

  if (isInvest) syncInvestAmount();

  const body = {
    action: "add",
    secret: SECRET,
    type,
    description: document.getElementById("f-desc").value,
    amount: document.getElementById("f-amount").value,
    category: document.getElementById("f-cat").value || "Other",
    account: document.getElementById("f-acct").value,
    date,
    source: "web",
  };

  let holdingBody = null;
  if (isInvest) {
    const assetType = document.getElementById("f-asset").value;
    const ticker =
      document.getElementById("f-ticker").value.trim().toUpperCase() ||
      (assetType === "gold" ? "LM" : "");
    const assetName = document.getElementById("f-asset-name").value.trim();
    const qty = document.getElementById("f-qty").value;
    const buyPrice = document.getElementById("f-buyprice").value;
    if (!qty || !buyPrice) {
      alert("Fill quantity and buy price");
      return;
    }
    if (!ticker) {
      alert(
        assetType === "stock"
          ? "Stocks need a ticker (e.g. BBCA)"
          : "Gold needs a ticker (default LM)",
      );
      return;
    }
    if (!body.description)
      body.description = assetName ? `${assetName} ${ticker}` : ticker;
    holdingBody = {
      action: "addHolding",
      secret: SECRET,
      assetType,
      ticker,
      name: assetName,
      quantity: qty,
      buyPrice,
      buyDate: date,
    };
  }

  if (!body.description || !body.amount) {
    alert("Fill description and amount");
    return;
  }
  setStatus("Saving…");
  await fetch(API_URL, {
    method: "POST",
    headers: { "Content-Type": "text/plain;charset=utf-8" },
    body: JSON.stringify(body),
  });
  if (holdingBody) {
    await fetch(API_URL, {
      method: "POST",
      headers: { "Content-Type": "text/plain;charset=utf-8" },
      body: JSON.stringify(holdingBody),
    });
  }

  document.getElementById("f-desc").value = "";
  document.getElementById("f-amount").value = "";
  if (isInvest) {
    document.getElementById("f-ticker").value = "";
    document.getElementById("f-asset-name").value = "";
    document.getElementById("f-qty").value = "";
    document.getElementById("f-buyprice").value = "";
    syncInvestAmount();
  }
  load();
}

async function addTransfer() {
  const from = document.getElementById("t-from").value;
  const to = document.getElementById("t-to").value;
  const amount = document.getElementById("t-amount").value;
  if (from === to) {
    alert("Pick two different accounts");
    return;
  }
  if (!amount || Number(amount) <= 0) {
    alert("Enter a transfer amount");
    return;
  }
  const body = {
    action: "transfer",
    secret: SECRET,
    fromAccount: from,
    toAccount: to,
    amount,
    description: document.getElementById("t-note").value.trim(),
    date:
      document.getElementById("t-date").value ||
      new Date().toISOString().split("T")[0],
    source: "web",
  };
  setStatus("Transferring\u2026");
  await fetch(API_URL, {
    method: "POST",
    headers: { "Content-Type": "text/plain;charset=utf-8" },
    body: JSON.stringify(body),
  });
  document.getElementById("t-amount").value = "";
  document.getElementById("t-note").value = "";
  load();
}

function setStatus(t) {
  document.getElementById("status").textContent = t;
}

// ---- init ----
document.getElementById("f-date").value = new Date()
  .toISOString()
  .split("T")[0];
document.getElementById("t-date").value = new Date()
  .toISOString()
  .split("T")[0];
fillCategoryOptions(document.getElementById("f-type").value);
load();
