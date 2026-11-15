/* FinanceTracker PWA (V2): talks straight to Supabase; row-level security
   decides what each signed-in user can read or write. No secrets live here. */
(() => {
  "use strict";

  // ------------------------------------------------------------ basics
  const cfg = window.FINANCE_CONFIG || {};
  const $ = (sel, root = document) => root.querySelector(sel);
  const app = $("#app");
  const sheetRoot = $("#sheet-root");
  const TABS = ["home", "stats", "portfolio", "settings", "activity"];
  let sb = null;
  let charts = [];
  let pricesDown = false;

  const S = {
    session: null, households: [], household: null,
    accounts: [], categories: [], txns: [], holdings: [], sales: [], members: [],
    prices: null, offline: false, period: "month",
    filter: { q: "", type: "", account: "" },
    telegram: null, // this user's Telegram link, if any
    scan: null, // rows read from a photo, reviewed one at a time: { rows, index, saved }
  };

  const esc = (v) => String(v ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const num = (n) => Math.round(Number(n) || 0).toLocaleString("id-ID");
  const rp = (n) => (n < 0 ? "−" : "") + "Rp " + num(Math.abs(n));
  const compact = (n) => {
    const a = Math.abs(n), s = n < 0 ? "−" : "";
    const f = (v, unit) => s + v.toLocaleString("id-ID", { maximumFractionDigits: 1 }) + " " + unit;
    if (a >= 1e9) return f(a / 1e9, "M");
    if (a >= 1e6) return f(a / 1e6, "jt");
    if (a >= 1e3) return f(a / 1e3, "rb");
    return s + num(a);
  };
  const qtyFmt = (n) => Number(n).toLocaleString("id-ID", { maximumFractionDigits: 4 });
  const today = () => new Date().toLocaleDateString("en-CA"); // YYYY-MM-DD, device time zone
  const dateLabel = (d) => {
    if (d === today()) return "Hari ini";
    const dt = new Date(d + "T00:00:00");
    return dt.toLocaleDateString("id-ID", { day: "numeric", month: "short", year: dt.getFullYear() === new Date().getFullYear() ? undefined : "numeric" });
  };
  const initials = (name) => String(name || "?").trim().slice(0, 2).toUpperCase();
  const parseAmount = (v) => Number(String(v).replace(/[^\d]/g, "")) || 0;
  const parseQty = (v) => parseFloat(String(v).replace(/\s/g, "").replace(",", ".")) || 0;
  const isNetworkError = (e) => !navigator.onLine || /failed to fetch|networkerror|load failed/i.test(String(e?.message || e));

  const ICON = {
    home: '<path d="M4 11l8-7 8 7v9H4z"/>',
    stats: '<path d="M5 20V10M12 20V4M19 20v-7"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    coins: '<circle cx="9" cy="9" r="5"/><path d="M14.5 10.2a5 5 0 11-4.3 4.3"/>',
    user: '<circle cx="12" cy="8" r="4"/><path d="M4 21c1-5 15-5 16 0"/>',
    back: '<path d="M15 5l-7 7 7 7"/>',
    close: '<path d="M6 6l12 12M18 6L6 18"/>',
    swap: '<path d="M7 7h12l-3-3M17 17H5l3 3"/>',
    refresh: '<path d="M20 11a8 8 0 10-2.3 6.3M20 5v6h-6"/>',
    camera: '<path d="M4 8h3l2-3h6l2 3h3v11H4z"/><circle cx="12" cy="13" r="3.5"/>',
    image: '<rect x="4" y="5" width="16" height="14" rx="2"/><path d="M4 16l5-5 4 4 3-3 4 4"/><circle cx="15" cy="9" r="1.2"/>',
  };
  const icon = (name) => `<svg class="i" viewBox="0 0 24 24" aria-hidden="true">${ICON[name]}</svg>`;

  let toastTimer;
  function toast(msg) {
    const el = $("#toast");
    el.textContent = msg;
    el.classList.add("show");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.remove("show"), 2600);
  }

  // ------------------------------------------------------------ local storage (cache + offline queue)
  const store = {
    get(key, fallback) { try { return JSON.parse(localStorage.getItem(key)) ?? fallback; } catch { return fallback; } },
    set(key, value) { try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* storage full or blocked */ } },
  };
  const queue = () => store.get("ft.queue", []);

  function saveCache() {
    store.set("ft.cache", {
      household: S.household, households: S.households, accounts: S.accounts, categories: S.categories,
      txns: S.txns, holdings: S.holdings, sales: S.sales, members: S.members, prices: S.prices,
    });
  }
  function loadCache() {
    const c = store.get("ft.cache", null);
    if (!c || !c.household) return false;
    Object.assign(S, c);
    return true;
  }

  // ------------------------------------------------------------ data
  const check = (res) => { if (res.error) throw res.error; return res.data; };

  async function fetchAll(build) {
    const size = 1000; // PostgREST returns at most 1000 rows per request
    let from = 0, out = [];
    for (;;) {
      const rows = check(await build().range(from, from + size - 1));
      out = out.concat(rows);
      if (rows.length < size) return out;
      from += size;
    }
  }

  async function refresh() {
    const hid = S.household.id;
    const [acc, opening, cat, tx, hold, sales, mem, tele] = await Promise.all([
      sb.from("account_balances").select("*").eq("household_id", hid).order("sort_order").order("name"),
      sb.from("accounts").select("id, opening_balance").eq("household_id", hid),
      sb.from("categories").select("*").eq("household_id", hid).order("name"),
      fetchAll(() => sb.from("transactions").select("*").eq("household_id", hid)
        .order("date", { ascending: false }).order("created_at", { ascending: false })),
      sb.from("holdings").select("*").eq("household_id", hid).order("created_at"),
      sb.from("sales").select("*").eq("household_id", hid).order("date", { ascending: false }),
      sb.from("members").select("user_id, role").eq("household_id", hid),
      sb.from("telegram_links").select("linked_at").eq("user_id", S.session.user.id).maybeSingle(),
    ]);
    const open = Object.fromEntries(check(opening).map((a) => [a.id, Number(a.opening_balance)]));
    S.accounts = check(acc).map((a) => ({ ...a, id: a.account_id, balance: Number(a.balance), opening_balance: open[a.account_id] || 0 }));
    S.categories = check(cat);
    S.txns = tx.map((t) => ({ ...t, amount: Number(t.amount) }));
    S.holdings = check(hold).map((h) => ({ ...h, quantity: Number(h.quantity), buy_price: Number(h.buy_price) }));
    S.sales = check(sales);
    S.members = check(mem);
    S.telegram = tele.error ? null : tele.data;
    S.offline = false;
    saveCache();
  }

  async function loadPrices() {
    const tickers = [...new Set(S.holdings.filter((h) => h.asset_type === "stock").map((h) => h.ticker))];
    const gold = S.holdings.some((h) => h.asset_type === "gold");
    if ((!tickers.length && !gold) || pricesDown) return;
    try {
      const { data, error } = await sb.functions.invoke("prices", { body: { tickers, gold } });
      // function not deployed yet: holdings show at cost; stop asking until the next app start
      if (error || !data) { pricesDown = true; return; }
      S.prices = data;
      saveCache();
      if (["home", "portfolio"].includes(currentTab())) route();
    } catch { /* offline */ }
  }

  async function flushQueue() {
    const pending = queue();
    if (!pending.length || !navigator.onLine) return;
    const left = [];
    for (const row of pending) {
      const { _qid, ...payload } = row;
      const { error } = await sb.from("transactions").insert(payload);
      if (error) left.push(row);
    }
    store.set("ft.queue", left);
    if (left.length < pending.length) toast(`${pending.length - left.length} offline entr${pending.length - left.length === 1 ? "y" : "ies"} synced`);
  }

  async function reload(message) {
    try {
      await flushQueue();
      await refresh();
      loadPrices();
    } catch (e) {
      if (isNetworkError(e)) S.offline = true; else toast(e.message || "Could not load data");
    }
    route();
    if (message) toast(message);
  }

  const accountName = (id) => S.accounts.find((a) => a.id === id)?.name || "Unassigned";
  const categoryName = (id) => S.categories.find((c) => c.id === id)?.name || "Other";
  const activeAccounts = () => S.accounts.filter((a) => !a.archived);

  async function categoryId(name) {
    const hit = S.categories.find((c) => c.name.toLowerCase() === name.toLowerCase());
    if (hit) return hit.id;
    const row = check(await sb.from("categories").insert({ household_id: S.household.id, name }).select().single());
    S.categories.push(row);
    return row.id;
  }

  // ------------------------------------------------------------ derived numbers
  const signed = (t) => (t.type === "income" || t.type === "transfer-in" ? t.amount : -t.amount);

  function periodRange(p) {
    const now = new Date(), y = now.getFullYear(), m = now.getMonth();
    const iso = (d) => d.toLocaleDateString("en-CA");
    if (p === "month") return [iso(new Date(y, m, 1)), iso(new Date(y, m + 1, 0))];
    if (p === "last") return [iso(new Date(y, m - 1, 1)), iso(new Date(y, m, 0))];
    if (p === "year") return [`${y}-01-01`, `${y}-12-31`];
    return ["0000-01-01", "9999-12-31"];
  }

  function summary(p) {
    const [from, to] = periodRange(p);
    const rows = S.txns.filter((t) => t.date >= from && t.date <= to);
    const sum = (type) => rows.filter((t) => t.type === type).reduce((s, t) => s + t.amount, 0);
    const income = sum("income"), expense = sum("expense"), invest = sum("invest");
    const byCat = {};
    rows.filter((t) => t.type === "expense").forEach((t) => {
      const k = categoryName(t.category_id);
      byCat[k] = (byCat[k] || 0) + t.amount;
    });
    const net = income - expense - invest;
    return {
      income, expense, invest, net,
      savingsRate: income > 0 ? Math.round((net / income) * 100) : 0,
      byCat: Object.entries(byCat).sort((a, b) => b[1] - a[1]),
    };
  }

  function positions() {
    const map = new Map();
    for (const h of S.holdings) {
      const key = `${h.asset_type}|${h.ticker}|${h.name.toLowerCase()}`;
      const p = map.get(key) || { asset_type: h.asset_type, ticker: h.ticker, name: h.name, qty: 0, cost: 0 };
      p.qty += h.quantity;
      p.cost += h.quantity * h.buy_price;
      map.set(key, p);
    }
    return [...map.values()].map((p) => {
      const price = p.asset_type === "gold" ? S.prices?.gold?.price : S.prices?.stocks?.[p.ticker];
      const value = price ? p.qty * price : null;
      return { ...p, avg: p.cost / p.qty, price: price || null, value, pl: value === null ? null : value - p.cost };
    });
  }

  // ------------------------------------------------------------ shell + routing
  const currentTab = () => {
    const t = location.hash.slice(1);
    return TABS.includes(t) ? t : "home";
  };

  function nav(tab) {
    const item = (id, ic, label) =>
      `<button class="${tab === id ? "on" : ""}" data-go="${id}" aria-label="${label}">${icon(ic)}</button>`;
    return `<nav class="nav">
      ${item("home", "home", "Home")}${item("stats", "stats", "Overview")}
      <button class="add" data-act="scan" aria-label="Scan a receipt">${icon("camera")}</button>
      ${item("portfolio", "coins", "Portfolio")}${item("settings", "user", "Settings")}
    </nav>`;
  }

  function paint(tab, html) {
    charts.forEach((c) => c.destroy());
    charts = [];
    const banner = S.offline ? `<div class="banner">Offline. Showing the last saved data.</div>` : "";
    app.innerHTML = banner + html + nav(tab);
  }

  function route() {
    if (!S.session) return viewLogin();
    if (!S.household) return viewOnboard();
    const tab = currentTab();
    ({ home: viewHome, stats: viewStats, portfolio: viewPortfolio, settings: viewSettings, activity: viewActivity })[tab]();
  }

  // ------------------------------------------------------------ views: auth + onboarding
  function viewLogin(note = "") {
    app.innerHTML = `<div class="auth">
      <div class="hero"><h1>Finance<br>Tracker</h1><p>Sign in to your household's money.</p></div>
      <div class="sheet">
        <form data-form="login">
          <label class="f">Email<input id="login-email" name="email" type="email" autocomplete="email" required></label>
          <label class="f">Password<input id="login-password" name="password" type="password" autocomplete="current-password"></label>
          <div class="error" id="login-error">${esc(note)}</div>
          <button class="pill" type="submit">Sign in</button>
          <button class="pill dark" type="button" data-act="magic">Email me a sign-in link</button>
          <p class="hint">Leave the password empty and use the link button if you prefer. Accounts are by invitation only.</p>
        </form>
      </div>
    </div>`;
  }

  function viewOnboard() {
    app.innerHTML = `<div class="auth">
      <div class="hero"><h1>Set up your household</h1><p>Name it and add the accounts you want to track. You can change these later.</p></div>
      <div class="sheet">
        <form data-form="onboard">
          <label class="f">Household name<input id="ob-name" name="name" required placeholder="Keluarga"></label>
          <label class="f">Accounts, one per line
            <textarea id="ob-accounts" name="accounts" rows="4" required placeholder="Tabungan&#10;Bersama" style="border:1px solid var(--rule);border-radius:13px;padding:12px;font:inherit;font-size:16px;color:var(--ink)"></textarea></label>
          <div class="error" id="onboard-error"></div>
          <button class="pill" type="submit">Create household</button>
          <button class="link" type="button" data-act="signout">Sign out</button>
        </form>
      </div>
    </div>`;
  }

  // ------------------------------------------------------------ views: main tabs
  function txRow(t) {
    const sign = signed(t);
    const cat = t.type.startsWith("transfer") ? "Transfer" : categoryName(t.category_id);
    const title = t.description || cat;
    return `<button class="tx ${t._qid ? "pending" : ""}" ${t._qid ? "" : `data-act="tx" data-id="${t.id}"`}>
      <span class="logo">${esc(initials(title))}</span>
      <span class="body"><b>${esc(title)}</b>
        <small>${esc(dateLabel(t.date))} · ${esc(cat)} · ${esc(accountName(t.account_id))}${t._qid ? " · waiting to sync" : ""}</small></span>
      <em class="num ${sign < 0 ? "neg" : "pos"}">${sign < 0 ? "−" : "+"}${num(t.amount)}</em>
    </button>`;
  }

  const allRows = () => queue().concat(S.txns);

  // Wallet-style stack: each card shows its header strip; the open card shows in full.
  // Used on Home (active accounts) and in Settings (all accounts, archived ones tagged).
  function accountStack(list) {
    const openId = list.some((a) => a.id === S.openAccount) ? S.openAccount : list[list.length - 1]?.id;
    const [mFrom, mTo] = periodRange("month");
    const flow = (id, sign) => S.txns
      .filter((t) => t.account_id === id && t.date >= mFrom && t.date <= mTo && Math.sign(signed(t)) === sign)
      .reduce((s, t) => s + t.amount, 0);
    return list.map((a, i) => `
      <div class="wcard c${i % 5} ${a.id === openId ? "open" : ""} ${a.archived ? "archived" : ""}">
        <button class="wc-head" data-act="card" data-id="${a.id}" aria-label="Show ${esc(a.name)}">
          <span class="wc-name"><i>${esc(initials(a.name))}</i>${esc(a.name)}${a.archived ? `<em>Archived</em>` : ""}</span>
          <b class="num">${rp(a.balance)}</b>
        </button>
        <div class="wc-body">
          <span>In this month<b class="num">${compact(flow(a.id, 1))}</b></span>
          <span>Out this month<b class="num">${compact(flow(a.id, -1))}</b></span>
          <button class="wc-edit" data-act="account" data-id="${a.id}">Edit</button>
        </div>
      </div>`).join("");
  }

  function viewHome() {
    const total = S.accounts.reduce((s, a) => s + a.balance, 0);
    const m = summary("month");
    const email = S.session.user.email || "";
    const accts = accountStack(activeAccounts());
    const recent = allRows().slice(0, 6).map(txRow).join("") ||
      `<div class="empty">No transactions yet. Tap + to add your first one.</div>`;
    paint("home", `
      <div class="top">
        <div class="row between">
          <div class="row"><div class="avatar">${esc(initials(email))}</div>
            <div><div class="muted" style="font-size:12px">${esc(S.household.name)}</div><b>${esc(email.split("@")[0])}</b></div></div>
          <button class="icon-btn" data-act="reload" aria-label="Refresh">${icon("refresh")}</button>
        </div>
        <div><div class="balance-label">Total balance</div>
          <div class="balance num"><small>Rp</small>${num(total)}</div></div>
        <div class="row">
          <button class="pill" data-act="add">${icon("plus")} Add</button>
          <button class="pill ghost" data-act="transfer">${icon("swap")} Transfer</button>
        </div>
        <div class="card">
          <div class="row between"><h3>Accounts</h3><button class="link" data-go="settings">Manage</button></div>
          <div class="stack">${accts}</div>
          <button class="wc-new" data-act="account">+ New account</button>
        </div>
        <div class="stats">
          <div class="stat"><span>Income (month)</span><b class="num up">${compact(m.income)}</b></div>
          <div class="stat"><span>Expense</span><b class="num down">${compact(m.expense)}</b></div>
          <div class="stat"><span>Invested</span><b class="num">${compact(m.invest)}</b></div>
        </div>
      </div>
      <div class="sheet">
        <div class="row between"><h2>Recent transactions</h2><button class="link" data-go="activity">View all</button></div>
        ${recent}
      </div>`);
  }

  function viewActivity() {
    const f = S.filter;
    paint("home", `
      <div class="top">
        <div class="row between">
          <button class="icon-btn" data-go="home" aria-label="Back">${icon("back")}</button>
          <h1 class="title">Transactions</h1><span style="width:40px"></span>
        </div>
      </div>
      <div class="sheet">
        <div class="filters">
          <input id="f-q" type="search" placeholder="Search" value="${esc(f.q)}" data-filter="q">
          <select id="f-type" data-filter="type">
            ${[["", "All types"], ["income", "Income"], ["expense", "Expense"], ["invest", "Invest"], ["transfer", "Transfers"]]
              .map(([v, l]) => `<option value="${v}" ${f.type === v ? "selected" : ""}>${l}</option>`).join("")}
          </select>
          <select id="f-account" data-filter="account">
            <option value="">All accounts</option>
            ${S.accounts.map((a) => `<option value="${a.id}" ${f.account === a.id ? "selected" : ""}>${esc(a.name)}</option>`).join("")}
          </select>
        </div>
        <div id="tx-list"></div>
      </div>`);
    renderTxList();
  }

  function renderTxList() {
    const f = S.filter, q = f.q.trim().toLowerCase();
    const rows = allRows().filter((t) =>
      (!f.type || (f.type === "transfer" ? t.type.startsWith("transfer") : t.type === f.type)) &&
      (!f.account || t.account_id === f.account) &&
      (!q || `${t.description} ${categoryName(t.category_id)} ${accountName(t.account_id)}`.toLowerCase().includes(q)));
    const shown = rows.slice(0, 300);
    $("#tx-list").innerHTML = `<p class="muted" style="margin:4px 0 10px;font-size:12.5px">${rows.length} transaction${rows.length === 1 ? "" : "s"}${rows.length > shown.length ? `, showing the latest ${shown.length}` : ""}</p>
      <div style="display:flex;flex-direction:column;gap:8px">${shown.map(txRow).join("") || `<div class="empty">Nothing matches.</div>`}</div>`;
  }

  function viewStats() {
    const s = summary(S.period);
    const periods = [["month", "This month"], ["last", "Last month"], ["year", "This year"], ["all", "All"]];
    const cats = s.byCat.map(([name, amount]) =>
      `<div class="list-row"><span class="grow">${esc(name)}</span><b class="num">${rp(amount)}</b></div>`).join("") ||
      `<div class="empty">No expenses in this period.</div>`;
    paint("stats", `
      <div class="top">
        <h1 class="title">Overview</h1>
        <div class="seg">${periods.map(([v, l]) => `<button class="${S.period === v ? "on" : ""}" data-act="period" data-id="${v}">${l}</button>`).join("")}</div>
        <div class="stats">
          <div class="stat"><span>Income</span><b class="num up">${compact(s.income)}</b></div>
          <div class="stat"><span>Expense</span><b class="num down">${compact(s.expense)}</b></div>
          <div class="stat"><span>Net</span><b class="num ${s.net < 0 ? "down" : ""}">${compact(s.net)}</b></div>
        </div>
        <div class="card">
          <div class="row between"><h3>Income and expense, last 6 months</h3></div>
          <div class="chart-box"><canvas id="bars" aria-label="Income and expense by month"></canvas></div>
        </div>
      </div>
      <div class="sheet">
        <div class="row between"><h2>Expenses by category</h2><span class="tag">Savings rate ${s.savingsRate}%</span></div>
        ${s.byCat.length ? `<div class="chart-box" style="height:220px"><canvas id="donut" aria-label="Expenses by category"></canvas></div>` : ""}
        <div>${cats}</div>
      </div>`);
    drawCharts(s);
  }

  function drawCharts(s) {
    if (!window.Chart) return;
    const months = [];
    const now = new Date();
    for (let i = 5; i >= 0; i--) {
      const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
      months.push({ key: d.toLocaleDateString("en-CA").slice(0, 7), label: d.toLocaleDateString("id-ID", { month: "short" }) });
    }
    const total = (key, type) => S.txns.filter((t) => t.type === type && t.date.startsWith(key)).reduce((a, t) => a + t.amount, 0);
    charts.push(new Chart($("#bars"), {
      type: "bar",
      data: {
        labels: months.map((m) => m.label),
        datasets: [
          { label: "Income", data: months.map((m) => total(m.key, "income")), backgroundColor: "#5a5a63", borderRadius: 5 },
          { label: "Expense", data: months.map((m) => total(m.key, "expense")), backgroundColor: "#f26a2e", borderRadius: 5 },
        ],
      },
      options: {
        maintainAspectRatio: false,
        plugins: { legend: { labels: { color: "#9a99a1", boxWidth: 10, boxHeight: 10 } },
                   tooltip: { callbacks: { label: (c) => `${c.dataset.label}: ${rp(c.parsed.y)}` } } },
        scales: { x: { ticks: { color: "#9a99a1" }, grid: { display: false } },
                  y: { ticks: { color: "#9a99a1", callback: (v) => compact(v) }, grid: { color: "#2c2c32" } } },
      },
    }));
    if (s.byCat.length && $("#donut")) {
      const palette = ["#f26a2e", "#17161a", "#f7a57e", "#77737c", "#b9431a", "#c9c5c0", "#3a3a42", "#fbd2bd"];
      charts.push(new Chart($("#donut"), {
        type: "doughnut",
        data: { labels: s.byCat.map((c) => c[0]), datasets: [{ data: s.byCat.map((c) => c[1]), backgroundColor: palette, borderWidth: 2, borderColor: "#fff" }] },
        options: { maintainAspectRatio: false, cutout: "62%",
          plugins: { legend: { position: "right", labels: { color: "#17161a", boxWidth: 10, boxHeight: 10, font: { size: 11 } } },
                     tooltip: { callbacks: { label: (c) => `${c.label}: ${rp(c.parsed)}` } } } },
      }));
    }
  }

  function viewPortfolio() {
    const pos = positions();
    const cost = pos.reduce((s, p) => s + p.cost, 0);
    const priced = pos.filter((p) => p.value !== null);
    const value = priced.reduce((s, p) => s + p.value, 0);
    const pl = priced.reduce((s, p) => s + p.pl, 0);
    const realized = S.sales.reduce((s, x) => s + Number(x.realized_pl), 0);
    const rows = pos.map((p, i) => {
      const unit = p.asset_type === "gold" ? "g" : "lembar";
      const label = p.name || p.ticker;
      return `<button class="tx" data-act="position" data-id="${i}">
        <span class="logo">${esc(initials(p.ticker || label))}</span>
        <span class="body"><b>${esc(label)}</b><small>${qtyFmt(p.qty)} ${unit} · avg ${rp(p.avg)}</small></span>
        <em class="num">${rp(p.value ?? p.cost)}
          ${p.pl === null ? `<small class="muted">at cost</small>` : `<small class="${p.pl < 0 ? "neg" : "pos"}">${p.pl < 0 ? "−" : "+"}${num(Math.abs(p.pl))}</small>`}</em>
      </button>`;
    }).join("") || `<div class="empty">No holdings yet.</div>`;
    const sales = S.sales.slice(0, 20).map((x) => {
      const r = Number(x.realized_pl);
      return `<div class="list-row"><span class="grow">${esc(x.name || x.ticker)}<small>${esc(dateLabel(x.date))} · ${qtyFmt(x.quantity)} @ ${rp(Number(x.sell_price))}</small></span>
        <b class="num ${r < 0 ? "neg" : "pos"}">${r < 0 ? "−" : "+"}${num(Math.abs(r))}</b></div>`;
    }).join("");
    paint("portfolio", `
      <div class="top">
        <h1 class="title">Portfolio</h1>
        <div><div class="balance-label">${priced.length ? "Market value" : "Total cost"}</div>
          <div class="balance num"><small>Rp</small>${num(priced.length ? value : cost)}</div></div>
        <div class="stats">
          <div class="stat"><span>Cost</span><b class="num">${compact(cost)}</b></div>
          <div class="stat"><span>Unrealized</span><b class="num ${pl < 0 ? "down" : "up"}">${priced.length ? compact(pl) : "n/a"}</b></div>
          <div class="stat"><span>Realized</span><b class="num ${realized < 0 ? "down" : "up"}">${compact(realized)}</b></div>
        </div>
        ${S.prices ? "" : `<p class="muted" style="font-size:12.5px;margin:0">Live prices are not connected yet, so holdings show at cost.</p>`}
        <div class="row"><button class="pill" data-act="holding">${icon("plus")} Add holding</button></div>
      </div>
      <div class="sheet">
        <h2>Holdings</h2>${rows}
        ${sales ? `<div class="section-label">Realized sales</div><div>${sales}</div>` : ""}
      </div>`);
  }

  function viewSettings() {
    const accts = accountStack(S.accounts);
    const cats = S.categories.map((c) => `<button class="chip" data-act="category" data-id="${c.id}">${esc(c.name)}</button>`).join("");
    const isOwner = S.members.some((m) => m.user_id === S.session.user.id && m.role === "owner");
    paint("settings", `
      <div class="top">
        <h1 class="title">Settings</h1>
        <div class="card">
          <div class="row"><div class="avatar">${esc(initials(S.session.user.email))}</div>
            <div class="grow"><b>${esc(S.session.user.email)}</b><div class="muted" style="font-size:12.5px">${esc(S.household.name)} · ${S.members.length} member${S.members.length === 1 ? "" : "s"}</div></div></div>
          <div class="row">
            ${isOwner ? `<button class="pill ghost" data-act="member">Add member</button>` : ""}
            <button class="pill ghost" data-act="signout">Sign out</button>
          </div>
        </div>
      </div>
      <div class="sheet">
        <div class="row between"><h2>Accounts</h2><button class="link" data-act="account">Add account</button></div>
        ${accts ? `<div class="stack">${accts}</div>` : `<div class="empty">No accounts yet.</div>`}
        <div class="row between" style="margin-top:14px"><h2>Categories</h2><button class="link" data-act="category">Add category</button></div>
        <div class="chips">${cats}</div>
        ${cfg.TELEGRAM_BOT ? `        <div class="section-label">Telegram bot</div>
        <div class="list-row"><span class="grow">\${S.telegram ? "Linked" : "Not linked"}<small>\${S.telegram
          ? "Send the bot a receipt photo or /help"
          : "Log entries by chat or by sending a receipt photo"}</small></span>
          <button class="link" data-act="\${S.telegram ? "telegram-unlink" : "telegram-link"}">\${S.telegram ? "Unlink" : "Link Telegram"}</button></div>` : ""}
        <div class="section-label">Data</div>
        <div class="list-row"><span class="grow">Data source<small>Google Sheets mode arrives in a later phase</small></span><span class="tag">Supabase</span></div>
        <div class="list-row"><span class="grow">Waiting to sync<small>Entries saved while offline</small></span><b class="num">${queue().length}</b></div>
      </div>`);
  }

  // ------------------------------------------------------------ bottom-sheet forms
  function openSheet(title, body) {
    sheetRoot.innerHTML = `<div class="overlay" data-act="dismiss"><div class="modal" role="dialog" aria-label="${esc(title)}">
      <header><h2>${esc(title)}</h2><button class="close" data-act="close" aria-label="Close">${icon("close")}</button></header>
      ${body}</div></div>`;
    $("input:not([type=hidden]), select", sheetRoot)?.focus({ preventScroll: true });
  }
  function closeSheet() {
    const scan = S.scan;
    S.scan = null;
    sheetRoot.innerHTML = "";
    if (scan?.saved) reload(); // a scan review was closed part-way: show what was saved
  }

  const accountOptions = (selected, allowNone = false) =>
    (allowNone ? `<option value="">None</option>` : "") +
    activeAccounts().map((a) => `<option value="${a.id}" ${a.id === selected ? "selected" : ""}>${esc(a.name)}</option>`).join("");

  // `pre` prefills the form from a scan; `scan` adds the review header and Skip button.
  function sheetAdd(type = "expense", pre = {}, scan = null) {
    if (!activeAccounts().length) return sheetAccount();
    const types = [["expense", "Expense"], ["income", "Income"], ["invest", "Invest"]];
    const category = pre.category ?? (type === "income" ? "Salary" : type === "invest" ? "Stocks" : "");
    const date = pre.date && pre.date <= today() ? pre.date : today();
    const many = scan && scan.rows.length > 1;
    openSheet(scan ? "Check the details" : "Add transaction", `<form data-form="txn">
      <input type="hidden" name="type" id="txn-type" value="${type}">
      <input type="hidden" name="source" value="${scan ? "ocr" : "web"}">
      ${scan ? `<p class="hint">${many ? `Row ${scan.index + 1} of ${scan.rows.length}. ` : ""}${scan.engine === "smart" ? "Read by smart read." : "Read on this device."} Fix anything that is wrong; nothing is saved until you tap Save.</p>` : ""}
      <div class="chips">${types.map(([v, l]) => `<button type="button" class="chip ${v === type ? "on" : ""}" data-act="txn-type" data-id="${v}">${l}</button>`).join("")}</div>
      <label class="f">Amount (Rp)<input id="txn-amount" name="amount" inputmode="numeric" required placeholder="0" data-money value="${pre.amount ? num(pre.amount) : ""}"></label>
      <label class="f">Description<input id="txn-desc" name="description" placeholder="e.g. Indomaret" value="${esc(pre.description || "")}"></label>
      <div class="two">
        <label class="f">Category<input id="txn-category" name="category" list="cat-list" required value="${esc(category)}" placeholder="Pick or type"></label>
        <label class="f">Account<select id="txn-account" name="account">${accountOptions(store.get("ft.lastAccount", ""))}</select></label>
      </div>
      <datalist id="cat-list">${S.categories.map((c) => `<option value="${esc(c.name)}">`).join("")}</datalist>
      <label class="f">Date<input id="txn-date" name="date" type="date" value="${date}" max="${today()}" required></label>
      <div class="error"></div>
      <button class="pill" type="submit">Save</button>
      ${many ? `<button class="pill ghost" type="button" data-act="scan-skip">Skip this row</button>` : ""}
      ${scan && scan.engine === "device" && !scan.saved ? `<button class="link" type="button" data-act="scan-smart">Not right? Try smart read (sends the photo to Google Gemini)</button>` : ""}
    </form>`);
  }

  // ------------------------------------------------------------ scan (photo -> ocr function -> review)
  const SCAN_MODES = [
    ["receipt", "Receipt", "One expense from a shop receipt."],
    ["payslip", "Payslip", "Your net take-home pay, saved as income."],
    ["history", "History", "A screenshot of a transaction list. You review each row."],
  ];

  function sheetScan(mode = "receipt") {
    if (!activeAccounts().length) return sheetAccount();
    openSheet("Scan", `<div class="scan" id="scan" data-mode="${mode}">
      <div class="chips">${SCAN_MODES.map(([v, l]) => `<button type="button" class="chip ${v === mode ? "on" : ""}" data-act="scan-mode" data-id="${v}">${l}</button>`).join("")}</div>
      <p class="hint" id="scan-hint">${SCAN_MODES.find((m) => m[0] === mode)[2]}</p>
      <label class="pill scan-pick">${icon("camera")} Take a photo<input type="file" accept="image/*" capture="environment" data-scan hidden></label>
      <label class="pill ghost scan-pick">${icon("image")} Choose from gallery<input type="file" accept="image/*" data-scan hidden></label>
      <p class="hint">Read on this device. Your photo is not uploaded.</p>
      <div class="scan-busy" id="scan-busy" hidden><span class="spinner"></span> <span id="scan-busy-text">Reading your photo…</span></div>
      <div class="error"></div>
      <button class="pill dark" type="button" id="scan-smart" data-act="scan-smart" hidden>Try smart read</button>
      <p class="hint" id="scan-smart-hint" hidden>Smart read sends this photo to Google Gemini.</p>
      <button class="link" type="button" data-act="add">Type it in instead</button>
    </div>`);
  }

  // Shrink the photo so reading is quick; returns a JPEG Blob.
  async function shrinkImage(file, maxSide = 2000) {
    const url = URL.createObjectURL(file);
    try {
      const img = await new Promise((resolve, reject) => {
        const el = new Image();
        el.onload = () => resolve(el);
        el.onerror = () => reject(new Error("That file could not be opened as a photo."));
        el.src = url;
      });
      const scale = Math.min(1, maxSide / Math.max(img.naturalWidth, img.naturalHeight));
      const canvas = document.createElement("canvas");
      canvas.width = Math.round(img.naturalWidth * scale);
      canvas.height = Math.round(img.naturalHeight * scale);
      const ctx = canvas.getContext("2d");
      ctx.fillStyle = "#fff"; // transparent PNG screenshots would turn black in JPEG
      ctx.fillRect(0, 0, canvas.width, canvas.height);
      ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
      return await new Promise((resolve, reject) =>
        canvas.toBlob((blob) => (blob ? resolve(blob) : reject(new Error("Could not prepare that photo."))), "image/jpeg", 0.85));
    } finally {
      URL.revokeObjectURL(url);
    }
  }

  // On-device reader: PaddleOCR in a background worker (ocr-worker.js). No upload, no key.
  let ocrWorker = null;
  const ocrJobs = new Map();
  function readTextOnDevice(buffer) {
    if (!ocrWorker) {
      ocrWorker = new Worker("ocr-worker.js", { type: "module" });
      ocrWorker.onmessage = (ev) => {
        const job = ocrJobs.get(ev.data.id);
        if (!job) return;
        ocrJobs.delete(ev.data.id);
        clearTimeout(job.timer);
        if (ev.data.error) job.reject(new Error(ev.data.error)); else job.resolve(ev.data.lines);
      };
      ocrWorker.onerror = () => { // the worker could not start (offline on first use, or an old browser)
        ocrJobs.forEach((job) => { clearTimeout(job.timer); job.reject(new Error("The on-device reader could not start.")); });
        ocrJobs.clear();
        ocrWorker.terminate();
        ocrWorker = null;
      };
    }
    return new Promise((resolve, reject) => {
      const id = Date.now() + Math.random();
      const timer = setTimeout(() => { ocrJobs.delete(id); reject(new Error("Reading took too long.")); }, 90000);
      ocrJobs.set(id, { resolve, reject, timer });
      ocrWorker.postMessage({ id, image: buffer }, [buffer]);
    });
  }

  // Past entries teach the category: "Indomaret" was Groceries last time, so it is again.
  const scanContext = () => ({
    categories: S.categories.map((c) => c.name),
    history: S.txns.filter((t) => !t.type.startsWith("transfer") && t.category_id).slice(0, 3000)
      .map((t) => ({ description: t.description, category: categoryName(t.category_id) })),
  });

  // Smart read: the photo goes to the "ocr" function, which asks Google Gemini.
  async function readSmart(blob, mode) {
    const image = await new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(String(reader.result).split(",")[1]);
      reader.onerror = () => reject(new Error("Could not prepare that photo."));
      reader.readAsDataURL(blob);
    });
    const { data, error } = await sb.functions.invoke("ocr", {
      body: { mode, image, mime: "image/jpeg", categories: S.categories.map((c) => c.name) },
    });
    if (error) {
      let message = "";
      try { message = (await error.context.json()).error; } catch { /* no JSON body */ }
      throw new Error(message || "Smart read is not set up (the ocr function is not deployed).");
    }
    return data?.rows || [];
  }

  let scanPhoto = null; // { blob, mode } of the last photo, kept for a smart-read retry

  // engine: "device" (default) or "smart". `file` is a new photo; without it the last photo is re-read.
  async function runScan(file, engine = "device") {
    const box = $("#scan");
    const errEl = $(".error", sheetRoot);
    const busy = (on, text) => {
      if (box) { box.classList.toggle("busy", on); $("#scan-busy", box).hidden = !on; if (text) $("#scan-busy-text", box).textContent = text; }
      else if (on) toast(text);
    };
    const offerSmart = (show) => {
      if (!box) return;
      $("#scan-smart", box).hidden = !show;
      $("#scan-smart-hint", box).hidden = !show;
    };
    if (errEl) errEl.textContent = "";
    offerSmart(false);
    try {
      if (file) scanPhoto = { blob: null, mode: box.dataset.mode, file };
      if (!scanPhoto) return;
      busy(true, engine === "smart" ? "Smart read in progress…" : "Reading on this device… the first scan takes longer.");
      if (!scanPhoto.blob) scanPhoto.blob = await shrinkImage(scanPhoto.file);
      const { blob, mode } = scanPhoto;
      let rows;
      if (engine === "smart") {
        if (!navigator.onLine) throw new Error("Smart read needs a connection.");
        rows = await readSmart(blob, mode);
      } else {
        const lines = await readTextOnDevice(await blob.arrayBuffer());
        rows = window.ReceiptParser.parse(mode, lines, scanContext());
      }
      if (box && $("#scan") !== box) return; // the sheet was closed while reading
      if (!rows.length) {
        throw new Error(engine === "smart" ? "Nothing readable was found. Try a sharper, well-lit photo."
          : mode === "payslip" ? "I could not find the take-home pay on this photo."
          : mode === "history" ? "I could not find any transaction rows on this photo."
          : "I could not find the total on this photo.");
      }
      S.scan = { rows, index: 0, saved: 0, engine };
      scanReview();
    } catch (e) {
      if (box && $("#scan") !== box) return;
      const message = e.message || "Could not read that photo.";
      if ($("#scan")) { $(".error", sheetRoot).textContent = message; offerSmart(engine === "device" && !!scanPhoto?.blob); }
      else toast(message);
    } finally {
      busy(false);
    }
  }

  function scanReview() {
    const scan = S.scan, row = scan.rows[scan.index];
    sheetAdd(row.type, row, scan);
  }

  // Move to the next scanned row, or finish and refresh when there are none left.
  async function scanNext(saved) {
    const scan = S.scan;
    if (saved) scan.saved += 1;
    scan.index += 1;
    if (scan.index < scan.rows.length) {
      scanReview();
      return toast(saved ? "Saved" : "Skipped");
    }
    S.scan = null;
    closeSheet();
    if (scan.saved) await reload(`${scan.saved} saved from your photo`);
    else toast("Nothing saved");
  }

  function sheetTransfer() {
    if (activeAccounts().length < 2) return toast("Add a second account first");
    const a = activeAccounts();
    openSheet("Transfer", `<form data-form="transfer">
      <div class="two">
        <label class="f">From<select id="tr-from" name="from">${accountOptions(a[0].id)}</select></label>
        <label class="f">To<select id="tr-to" name="to">${accountOptions(a[1].id)}</select></label>
      </div>
      <label class="f">Amount (Rp)<input id="tr-amount" name="amount" inputmode="numeric" required placeholder="0" data-money></label>
      <label class="f">Note<input id="tr-note" name="note" placeholder="Optional"></label>
      <label class="f">Date<input id="tr-date" name="date" type="date" value="${today()}" max="${today()}" required></label>
      <div class="error"></div>
      <button class="pill" type="submit">Transfer</button>
    </form>`);
  }

  function sheetTx(id) {
    const t = S.txns.find((x) => x.id === id);
    if (!t) return;
    const transfer = t.type.startsWith("transfer");
    openSheet(t.description || categoryName(t.category_id), `
      <div>
        <div class="list-row"><span class="grow">Amount</span><b class="num ${signed(t) < 0 ? "neg" : "pos"}">${rp(signed(t))}</b></div>
        <div class="list-row"><span class="grow">Type</span><span>${esc(t.type)}</span></div>
        <div class="list-row"><span class="grow">Category</span><span>${esc(transfer ? "Transfer" : categoryName(t.category_id))}</span></div>
        <div class="list-row"><span class="grow">Account</span><span>${esc(accountName(t.account_id))}</span></div>
        <div class="list-row"><span class="grow">Date</span><span>${esc(dateLabel(t.date))}</span></div>
        <div class="list-row"><span class="grow">Added from</span><span>${esc(t.source)}</span></div>
      </div>
      <div class="error"></div>
      <button class="pill danger" data-act="tx-delete" data-id="${t.id}">${transfer ? "Delete both sides of this transfer" : "Delete transaction"}</button>`);
  }

  function sheetAccount(id) {
    const a = S.accounts.find((x) => x.id === id);
    openSheet(a ? "Edit account" : "New account", `<form data-form="account">
      <input type="hidden" name="id" value="${a ? a.id : ""}">
      <label class="f">Name<input id="acc-name" name="name" required value="${esc(a?.name || "")}" placeholder="e.g. Tabungan"></label>
      <label class="f">Opening balance (Rp)<input id="acc-open" name="opening" inputmode="numeric" data-money value="${a ? num(a.opening_balance ?? 0) : ""}" placeholder="0"></label>
      <p class="hint">The opening balance is what the account held before you started tracking.</p>
      <div class="error"></div>
      <button class="pill" type="submit">Save</button>
      ${a ? `<button class="pill dark" type="button" data-act="account-archive" data-id="${a.id}">${a.archived ? "Restore account" : "Archive account"}</button>
        <p class="hint">Archiving hides the account from forms. Its history stays.</p>` : ""}
    </form>`);
  }

  function sheetCategory(id) {
    const c = S.categories.find((x) => x.id === id);
    openSheet(c ? "Edit category" : "New category", `<form data-form="category">
      <input type="hidden" name="id" value="${c ? c.id : ""}">
      <label class="f">Name<input id="cat-name" name="name" required value="${esc(c?.name || "")}"></label>
      <div class="error"></div>
      <button class="pill" type="submit">Save</button>
      ${c ? `<button class="pill danger" type="button" data-act="category-delete" data-id="${c.id}">Delete category</button>
        <p class="hint">Transactions using it will show as "Other".</p>` : ""}
    </form>`);
  }

  function sheetMember() {
    openSheet("Add member", `<form data-form="member">
      <label class="f">Their email<input id="mem-email" name="email" type="email" required></label>
      <p class="hint">Invite them in the Supabase dashboard first (Authentication → Users), then add them here.</p>
      <div class="error"></div>
      <button class="pill" type="submit">Add to household</button>
    </form>`);
  }

  function sheetTelegram(code) {
    openSheet("Link Telegram", `
      <p class="hint">Open your Finance Tracker bot in Telegram and send it this message. The code works once and expires in 10 minutes.</p>
      <div class="code-box" id="tg-code">/link ${esc(code)}</div>
      <div class="error"></div>
      <button class="pill" type="button" data-act="telegram-copy">Copy message</button>
      <button class="pill ghost" type="button" data-act="telegram-done">I sent it</button>`);
  }

  function sheetHolding() {
    openSheet("Add holding", `<form data-form="holding">
      <input type="hidden" name="asset" id="hold-asset" value="stock">
      <div class="chips">
        <button type="button" class="chip on" data-act="asset" data-id="stock">Stock</button>
        <button type="button" class="chip" data-act="asset" data-id="gold">Gold</button>
      </div>
      <div class="two">
        <label class="f"><span id="hold-ticker-label">Ticker</span><input id="hold-ticker" name="ticker" required placeholder="BBCA" autocapitalize="characters"></label>
        <label class="f"><span id="hold-name-label">Name</span><input id="hold-name" name="name" placeholder="Bank Central Asia"></label>
      </div>
      <div class="two">
        <label class="f"><span id="hold-qty-label">Shares</span><input id="hold-qty" name="qty" inputmode="decimal" required placeholder="0"></label>
        <label class="f"><span id="hold-price-label">Price per share (Rp)</span><input id="hold-price" name="price" inputmode="numeric" data-money required placeholder="0"></label>
      </div>
      <div class="two">
        <label class="f">Buy date<input id="hold-date" name="date" type="date" value="${today()}" max="${today()}" required></label>
        <label class="f">Paid from<select id="hold-account" name="account">${accountOptions("", true)}</select></label>
      </div>
      <p class="hint">Choosing an account also records the purchase as an invest transaction.</p>
      <div class="error"></div>
      <button class="pill" type="submit">Save holding</button>
    </form>`);
  }

  function sheetPosition(index) {
    const p = positions()[index];
    if (!p) return;
    const unit = p.asset_type === "gold" ? "grams" : "shares";
    openSheet(`Sell ${p.name || p.ticker}`, `<form data-form="sell">
      <input type="hidden" name="ticker" value="${esc(p.ticker)}"><input type="hidden" name="name" value="${esc(p.name)}">
      <p class="hint">You hold ${qtyFmt(p.qty)} ${unit} at an average of ${rp(p.avg)}. Oldest lots are sold first.</p>
      <div class="two">
        <label class="f">Quantity (${unit})<input id="sell-qty" name="qty" inputmode="decimal" required placeholder="0"></label>
        <label class="f">Sell price (Rp)<input id="sell-price" name="price" inputmode="numeric" data-money required value="${p.price ? num(p.price) : ""}" placeholder="0"></label>
      </div>
      <div class="two">
        <label class="f">Proceeds go to<select id="sell-account" name="account">${accountOptions("", true)}</select></label>
        <label class="f">Date<input id="sell-date" name="date" type="date" value="${today()}" max="${today()}" required></label>
      </div>
      <div class="error"></div>
      <button class="pill" type="submit">Sell</button>
    </form>`);
  }

  // ------------------------------------------------------------ form handlers
  const forms = {
    async login(fd) {
      const email = fd.get("email").trim(), password = fd.get("password");
      if (!password) throw new Error("Enter your password, or use the sign-in link button.");
      const { error } = await sb.auth.signInWithPassword({ email, password });
      if (error) throw error;
    },

    async onboard(fd) {
      const accounts = fd.get("accounts").split("\n").map((s) => s.trim()).filter(Boolean);
      if (!accounts.length) throw new Error("Add at least one account.");
      check(await sb.rpc("create_household", { p_name: fd.get("name").trim(), p_accounts: accounts }));
      await start();
    },

    async txn(fd) {
      const amount = parseAmount(fd.get("amount"));
      if (amount <= 0) throw new Error("Enter an amount above zero.");
      const type = fd.get("type");
      const category = fd.get("category").trim() || "Other";
      const row = {
        household_id: S.household.id, date: fd.get("date"), type, description: fd.get("description").trim(),
        amount, source: fd.get("source") === "ocr" ? "ocr" : "web", account_id: fd.get("account") || null,
      };
      store.set("ft.lastAccount", row.account_id);
      const known = S.categories.find((c) => c.name.toLowerCase() === category.toLowerCase());
      try {
        row.category_id = known ? known.id : await categoryId(category);
        check(await sb.from("transactions").insert(row));
      } catch (e) {
        if (!isNetworkError(e)) throw e;
        row.category_id = known ? known.id : null;
        store.set("ft.queue", [{ ...row, _qid: Date.now() }, ...queue()]);
        closeSheet(); route();
        return toast("Saved offline. It will sync when you are back online.");
      }
      if (S.scan) return scanNext(true);
      closeSheet();
      await reload("Saved");
    },

    async transfer(fd) {
      const amount = parseAmount(fd.get("amount"));
      if (amount <= 0) throw new Error("Enter an amount above zero.");
      if (fd.get("from") === fd.get("to")) throw new Error("Choose two different accounts.");
      check(await sb.rpc("add_transfer", {
        p_household: S.household.id, p_from: fd.get("from"), p_to: fd.get("to"),
        p_amount: amount, p_date: fd.get("date"), p_note: fd.get("note").trim(), p_source: "web",
      }));
      closeSheet();
      await reload("Transfer saved");
    },

    async account(fd) {
      const name = fd.get("name").trim(), opening = parseAmount(fd.get("opening"));
      const id = fd.get("id");
      if (id) check(await sb.from("accounts").update({ name, opening_balance: opening }).eq("id", id));
      else check(await sb.from("accounts").insert({ household_id: S.household.id, name, opening_balance: opening, sort_order: S.accounts.length }));
      closeSheet();
      await reload(id ? "Account updated" : "Account added");
    },

    async category(fd) {
      const name = fd.get("name").trim(), id = fd.get("id");
      if (id) check(await sb.from("categories").update({ name }).eq("id", id));
      else check(await sb.from("categories").insert({ household_id: S.household.id, name }));
      closeSheet();
      await reload(id ? "Category updated" : "Category added");
    },

    async member(fd) {
      check(await sb.rpc("add_member_by_email", { p_household: S.household.id, p_email: fd.get("email").trim() }));
      closeSheet();
      await reload("Member added");
    },

    async holding(fd) {
      const asset = fd.get("asset");
      const qty = parseQty(fd.get("qty")), price = parseAmount(fd.get("price"));
      if (qty <= 0 || price <= 0) throw new Error("Quantity and price must be above zero.");
      const ticker = asset === "gold" ? "LM" : fd.get("ticker").trim().toUpperCase();
      const name = fd.get("name").trim() || (asset === "gold" ? "Antam" : ticker);
      check(await sb.from("holdings").insert({
        household_id: S.household.id, asset_type: asset, ticker, name, quantity: qty, buy_price: price, buy_date: fd.get("date"),
      }));
      if (fd.get("account")) {
        check(await sb.from("transactions").insert({
          household_id: S.household.id, date: fd.get("date"), type: "invest",
          category_id: await categoryId(asset === "gold" ? "Gold" : "Stocks"),
          description: `Buy ${qtyFmt(qty)} ${name}`, amount: Math.round(qty * price), source: "web", account_id: fd.get("account"),
        }));
      }
      closeSheet();
      await reload("Holding added");
    },

    async sell(fd) {
      const qty = parseQty(fd.get("qty")), price = parseAmount(fd.get("price"));
      if (qty <= 0 || price <= 0) throw new Error("Quantity and price must be above zero.");
      check(await sb.rpc("sell_holding", {
        p_household: S.household.id, p_quantity: qty, p_sell_price: price,
        p_account: fd.get("account") || null, p_ticker: fd.get("ticker") || null, p_name: fd.get("name") || null,
        p_date: fd.get("date"), p_source: "web",
      }));
      closeSheet();
      await reload("Sale recorded");
    },
  };

  document.addEventListener("submit", async (ev) => {
    const form = ev.target.closest("form[data-form]");
    if (!form) return;
    ev.preventDefault();
    const btn = $("button[type=submit]", form), errEl = $(".error", form);
    if (errEl) errEl.textContent = "";
    btn.disabled = true;
    try {
      await forms[form.dataset.form](new FormData(form), form);
    } catch (e) {
      const msg = isNetworkError(e) ? "You are offline. Try again when connected." : (e.message || "Something went wrong.");
      if (errEl) errEl.textContent = msg; else toast(msg);
    } finally {
      btn.disabled = false;
    }
  });

  // ------------------------------------------------------------ click actions
  let armed = null; // id of a destructive button waiting for its second tap

  const actions = {
    add: () => { S.scan = null; sheetAdd(); },
    scan: () => sheetScan(),
    "scan-skip": () => scanNext(false),
    "scan-smart": () => { S.scan = null; return runScan(null, "smart"); },
    "scan-mode": (el) => {
      $("#scan").dataset.mode = el.dataset.id;
      el.parentElement.querySelectorAll(".chip").forEach((c) => c.classList.toggle("on", c === el));
      $("#scan-hint").textContent = SCAN_MODES.find((m) => m[0] === el.dataset.id)[2];
    },
    transfer: sheetTransfer,
    holding: sheetHolding,
    member: sheetMember,
    close: closeSheet,
    reload: () => reload("Up to date"),
    tx: (el) => sheetTx(el.dataset.id),
    account: (el) => sheetAccount(el.dataset.id),
    category: (el) => sheetCategory(el.dataset.id),
    position: (el) => sheetPosition(Number(el.dataset.id)),
    period: (el) => { S.period = el.dataset.id; route(); },
    card: (el) => { // bring one account card to the front without re-rendering, so it animates
      S.openAccount = el.dataset.id;
      const card = el.closest(".wcard");
      card.parentElement.querySelectorAll(".wcard").forEach((c) => c.classList.toggle("open", c === card));
    },
    dismiss: (el, ev) => { if (ev.target === el) closeSheet(); },

    "txn-type": (el) => {
      $("#txn-type").value = el.dataset.id;
      el.parentElement.querySelectorAll(".chip").forEach((c) => c.classList.toggle("on", c === el));
      const cat = $("#txn-category");
      if (["", "Salary", "Stocks"].includes(cat.value)) cat.value = { income: "Salary", invest: "Stocks", expense: "" }[el.dataset.id];
    },

    asset: (el) => {
      const gold = el.dataset.id === "gold";
      $("#hold-asset").value = el.dataset.id;
      el.parentElement.querySelectorAll(".chip").forEach((c) => c.classList.toggle("on", c === el));
      const ticker = $("#hold-ticker");
      ticker.value = gold ? "LM" : "";
      ticker.readOnly = gold;
      $("#hold-name-label").textContent = gold ? "Brand" : "Name";
      $("#hold-name").placeholder = gold ? "Antam" : "Bank Central Asia";
      $("#hold-qty-label").textContent = gold ? "Grams" : "Shares";
      $("#hold-price-label").textContent = gold ? "Price per gram (Rp)" : "Price per share (Rp)";
    },

    async "telegram-link"() {
      const { data, error } = await sb.rpc("create_telegram_link_code", { p_household: S.household.id });
      if (error) {
        throw new Error(/create_telegram_link_code/.test(error.message)
          ? "The Telegram bot is not set up yet (see setup.md, phase 4)." : error.message);
      }
      sheetTelegram(data);
    },

    async "telegram-copy"(el) {
      await navigator.clipboard.writeText($("#tg-code").textContent);
      el.textContent = "Copied";
    },

    async "telegram-done"() {
      closeSheet();
      await reload();
      toast(S.telegram ? "Telegram linked" : "Not linked yet. Send the code to the bot, then refresh.");
    },

    async "telegram-unlink"(el) {
      if (armed !== "tg") { armed = "tg"; el.textContent = "Tap again to unlink"; return; }
      armed = null;
      check(await sb.from("telegram_links").delete().eq("user_id", S.session.user.id));
      await reload("Telegram unlinked");
    },

    async magic() {
      const email = $("#login-email").value.trim(), errEl = $("#login-error");
      if (!email) { errEl.textContent = "Enter your email first."; return; }
      const { error } = await sb.auth.signInWithOtp({
        email, options: { shouldCreateUser: false, emailRedirectTo: location.origin + location.pathname },
      });
      errEl.textContent = error ? error.message : "Check your inbox for the sign-in link.";
    },

    async signout() {
      await sb.auth.signOut();
      localStorage.removeItem("ft.cache");
    },

    async "tx-delete"(el) {
      if (armed !== el.dataset.id) { armed = el.dataset.id; el.textContent = "Tap again to delete"; return; }
      armed = null;
      const t = S.txns.find((x) => x.id === el.dataset.id);
      const q = sb.from("transactions").delete();
      check(await (t.transfer_group ? q.eq("transfer_group", t.transfer_group) : q.eq("id", t.id)));
      closeSheet();
      await reload("Deleted");
    },

    async "account-archive"(el) {
      const a = S.accounts.find((x) => x.id === el.dataset.id);
      check(await sb.from("accounts").update({ archived: !a.archived }).eq("id", a.id));
      closeSheet();
      await reload(a.archived ? "Account restored" : "Account archived");
    },

    async "category-delete"(el) {
      if (armed !== el.dataset.id) { armed = el.dataset.id; el.textContent = "Tap again to delete"; return; }
      armed = null;
      check(await sb.from("categories").delete().eq("id", el.dataset.id));
      closeSheet();
      await reload("Category deleted");
    },
  };

  document.addEventListener("click", async (ev) => {
    const go = ev.target.closest("[data-go]");
    if (go) { location.hash = go.dataset.go; return; }
    const el = ev.target.closest("[data-act]");
    if (!el) return;
    try {
      await actions[el.dataset.act]?.(el, ev);
    } catch (e) {
      const msg = isNetworkError(e) ? "You are offline. Try again when connected." : (e.message || "Something went wrong.");
      const errEl = $(".error", sheetRoot);
      if (errEl) errEl.textContent = msg; else toast(msg);
    }
  });

  document.addEventListener("input", (ev) => {
    const el = ev.target;
    if (el.matches("[data-money]")) { const n = parseAmount(el.value); el.value = n ? num(n) : ""; }
    if (el.dataset.filter) { S.filter[el.dataset.filter] = el.value; renderTxList(); }
  });

  document.addEventListener("change", (ev) => {
    const el = ev.target;
    if (!el.matches("input[data-scan]")) return;
    const file = el.files[0];
    el.value = ""; // picking the same photo again must fire change
    runScan(file);
  });

  window.addEventListener("hashchange", () => { closeSheet(); route(); window.scrollTo(0, 0); });
  window.addEventListener("online", () => { if (S.household) reload(); });
  window.addEventListener("offline", () => { S.offline = true; if (S.household) route(); });

  // ------------------------------------------------------------ startup
  async function start() {
    closeSheet();
    if (!S.session) { S.household = null; return viewLogin(); }
    const res = await sb.from("households").select("*").order("created_at");
    if (res.error) {
      if (isNetworkError(res.error) && loadCache()) { S.offline = true; return route(); }
      return viewLogin(res.error.message);
    }
    S.households = res.data;
    S.household = res.data[0] || null;
    if (!S.household) return viewOnboard();
    await reload();
  }

  async function boot() {
    if (!cfg.SUPABASE_URL || !cfg.SUPABASE_PUBLISHABLE_KEY || !window.supabase) {
      app.innerHTML = `<div class="center"><div><h2>Not configured</h2>
        <p class="muted">Run <code>python scripts/build_pwa_config.py</code> to create <code>pwa/config.js</code>, then reload.</p></div></div>`;
      return;
    }
    sb = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_PUBLISHABLE_KEY);
    S.session = (await sb.auth.getSession()).data.session;
    sb.auth.onAuthStateChange((_event, session) => {
      const changed = (session?.user?.id || null) !== (S.session?.user?.id || null);
      S.session = session;
      if (changed) setTimeout(start, 0); // never call Supabase from inside this callback
    });
    await start();
    if ("serviceWorker" in navigator) navigator.serviceWorker.register("sw.js").catch(() => {});
  }

  boot();
})();
