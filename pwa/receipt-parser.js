/* Turns the text lines read from a photo into transaction fields, using
   rules only (no AI). Input: [{ text, x, y, w, h }] from ocr-worker.js.
   Output rows have the same shape the "ocr" function returns:
   { type, amount, description, category, date }.

   Rules are tuned for Indonesian receipts, payslips and bank/e-wallet
   history screenshots. They are best-effort: the review sheet lets the user
   fix anything before saving. Also loadable in Node for tests. */
(function (root) {
  "use strict";

  const MONTHS = {
    jan: 1, januari: 1, january: 1, feb: 2, februari: 2, february: 2, mar: 3, maret: 3, march: 3,
    apr: 4, april: 4, mei: 5, may: 5, jun: 6, juni: 6, june: 6, jul: 7, juli: 7, july: 7,
    agu: 8, agt: 8, ags: 8, agustus: 8, aug: 8, august: 8, sep: 9, sept: 9, september: 9,
    okt: 10, oktober: 10, oct: 10, october: 10, nov: 11, november: 11, nop: 11,
    des: 12, desember: 12, dec: 12, december: 12,
  };
  const MONTH_RE = Object.keys(MONTHS).sort((a, b) => b.length - a.length).join("|");

  const pad = (n) => String(n).padStart(2, "0");
  const todayIso = () => new Date().toLocaleDateString("en-CA");

  // ---------------------------------------------------------------- rows
  // Group text boxes that sit on the same visual line, left to right.
  function toRows(lines) {
    const boxes = (lines || []).filter((l) => l && String(l.text || "").trim())
      .map((l) => ({ ...l, text: String(l.text).trim(), cy: l.y + l.h / 2 }))
      .sort((a, b) => a.cy - b.cy);
    const rows = [];
    for (const b of boxes) {
      const last = rows[rows.length - 1];
      if (last && Math.abs(b.cy - last.cy) <= Math.max(b.h, last.h) * 0.6) {
        last.h = Math.max(b.h, last.h);
        last.parts.push(b);
        last.cy = last.parts.reduce((s, p) => s + p.cy, 0) / last.parts.length;
      } else {
        rows.push({ cy: b.cy, h: b.h, parts: [b] });
      }
    }
    return rows.map((r) => {
      const parts = r.parts.sort((a, b) => a.x - b.x);
      return { parts, text: parts.map((p) => p.text).join("  "), y: r.cy, h: Math.max(...parts.map((p) => p.h)) };
    });
  }

  // ---------------------------------------------------------------- money
  // "44,900" "36.500" "1.250.000,00" "Rp50.000" "85000" -> numbers; ignores tiny counts.
  function amountsIn(text) {
    const out = [];
    const re = /(?<![\d.,/:]|\d-)(\d{1,3}(?:[.,]\d{3})+|\d{4,9})(?:[.,]\d{2})?(?![\d/:-])/g;
    let m;
    while ((m = re.exec(text))) {
      const value = Number(m[1].replace(/[.,]/g, ""));
      if (value >= 100 && value <= 5e9) out.push({ value, index: m.index, raw: m[0] });
    }
    return out;
  }

  // Rows whose numbers are not money: tax ids, phones, addresses, receipt numbers.
  const NOT_MONEY = /npwp|n\.p\.w\.p|telp|tlp|phone|hp\b|wa\b|sms|fax|\bjl\b|jln|jalan|ruko|komp\b|blok|kode\s*pos|no\.?\s*(bon|struk|nota|ref|trx|rek|kartu)|\bbon\b|struk|invoice|kasir|cashier|member|kritik|saran|www\.|\.com|\.co\.id|@|\bid\b\s*:|\bv\.\d/i;

  // ---------------------------------------------------------------- dates
  function validDate(y, m, d) {
    if (y < 100) y += 2000;
    if (y < 2015 || m < 1 || m > 12 || d < 1 || d > 31) return "";
    const dt = new Date(Date.UTC(y, m - 1, d));
    if (dt.getUTCMonth() !== m - 1) return "";
    const iso = `${y}-${pad(m)}-${pad(d)}`;
    return iso <= todayIso() ? iso : "";
  }

  // First believable date in the text. Indonesian order is day-month-year.
  function findDate(text) {
    let m;
    const iso = /(20\d{2})[-/.](\d{1,2})[-/.](\d{1,2})/g;
    while ((m = iso.exec(text))) { const d = validDate(+m[1], +m[2], +m[3]); if (d) return d; }
    const dmy = /(?<!\d)(\d{1,2})[-/.](\d{1,2})[-/.](\d{4}|\d{2})(?!\d)/g;
    while ((m = dmy.exec(text))) { const d = validDate(+m[3], +m[2], +m[1]); if (d) return d; }
    const named = new RegExp(`(?<!\\d)(\\d{1,2})[\\s.-]*(${MONTH_RE})\\b\\.?[\\s,.-]*(\\d{4}|\\d{2})(?!\\d)`, "gi");
    while ((m = named.exec(text))) { const d = validDate(+m[3], MONTHS[m[2].toLowerCase()], +m[1]); if (d) return d; }
    return "";
  }

  // "Oktober 2026" (a pay period) -> the last day of that month, or today if that is later.
  function findMonthEnd(text) {
    const m = new RegExp(`\\b(${MONTH_RE})\\b\\.?[\\s,.-]*(20\\d{2})`, "i").exec(text);
    if (!m) return "";
    const month = MONTHS[m[1].toLowerCase()], year = +m[2];
    const last = new Date(Date.UTC(year, month, 0)).getUTCDate();
    const iso = `${year}-${pad(month)}-${pad(last)}`;
    if (iso <= todayIso()) return iso;
    return `${year}-${pad(month)}-01` <= todayIso() ? todayIso() : "";
  }

  // ---------------------------------------------------------------- merchant + category
  function findMerchant(rows) {
    for (const r of rows.slice(0, 6)) {
      let t = r.text.split(/\s+\/\s+|\s{2,}/)[0];
      t = t.replace(/[\d\s/+()-]{8,}$/, "").replace(/\s+/g, " ").trim();
      const letters = (t.match(/[A-Za-z]/g) || []).length;
      if (letters < 3 || NOT_MONEY.test(t) || findDate(t)) continue;
      if (/^(selamat|welcome|terima kasih|thank|struk|receipt|nota|invoice|bukti)/i.test(t)) continue;
      return t.slice(0, 60);
    }
    return "";
  }

  // Keyword hints, used only when the user's own history has no answer.
  const HINTS = [
    [/indomaret|alfamart|alfamidi|alfa\s|superindo|hypermart|giant|lotte|transmart|hero\b|ranch|farmers|foodhall|supermarket|minimarket|swalayan|pasar/i, ["Groceries", "Food & Drink"]],
    [/pertamina|spbu|shell|vivo\b|bp\b|parkir|parking|tol\b|grab|gojek|gocar|goride|maxim|bluebird|kai\b|kereta|transjakarta|mrt/i, ["Transport"]],
    [/kfc|mcd|mcdonald|burger|pizza|starbucks|kopi|coffee|cafe|kafe|resto|restaurant|rumah makan|warung|warteg|bakso|mie\b|ayam|sate|nasi|bakery|roti|janji jiwa|kenangan|chatime|mixue|hokben|solaria/i, ["Food & Drink"]],
    [/apotek|apotik|kimia farma|k-?24|century|guardian|watson|klinik|rumah sakit|rs\b|dokter|lab\b/i, ["Health"]],
    [/pln|token listrik|pdam|telkom|indihome|telkomsel|xl\b|indosat|pulsa|internet|bpjs/i, ["Bills & Utilities"]],
    [/shopee|tokopedia|lazada|bukalapak|blibli|uniqlo|h&m|zara|miniso|ace hardware|informa|ikea/i, ["Shopping"]],
    [/netflix|spotify|youtube|disney|vidio/i, ["Subscriptions", "Entertainment"]],
    [/bioskop|cinema|xxi|cgv|cinepolis/i, ["Entertainment"]],
  ];

  // `history` = past transactions [{ description, category }] ; `categories` = names the user has.
  function guessCategory(description, categories, history) {
    const want = String(description || "").toLowerCase().replace(/[^a-z0-9 ]/g, " ").split(/\s+/).filter(Boolean);
    if (!want.length) return "";
    const key = want[0];
    if (key.length >= 3) {
      const counts = {};
      for (const t of history || []) {
        if (!t.category || !String(t.description || "").toLowerCase().includes(key)) continue;
        counts[t.category] = (counts[t.category] || 0) + 1;
      }
      const best = Object.entries(counts).sort((a, b) => b[1] - a[1])[0];
      if (best) return best[0];
    }
    const have = (categories || []).reduce((m, c) => (m[c.toLowerCase()] = c, m), {});
    for (const [re, names] of HINTS) {
      if (!re.test(description)) continue;
      for (const n of names) if (have[n.toLowerCase()]) return have[n.toLowerCase()];
    }
    return "";
  }

  // ---------------------------------------------------------------- receipt
  const TOTAL_KEYS = [
    [/grand\s*total|total\s*(akhir|bayar|pembayaran|belanja|tagihan|harga|due)|amount\s*due|jumlah\s*(bayar|tagihan)|harus\s*dibayar/i, 4],
    [/^\s*(total|t0tal|tota1)\b(?!\s*(disc|disk|hemat|poin|point|qty))/i, 3],
    [/\btotal\b(?!\s*(disc|disk|hemat|poin|point|qty))/i, 2],
    [/\b(jumlah|netto|net\b|tagihan)/i, 1],
  ];
  const PAID = /tunai|cash|bayar|dibayar|debit|kredit|credit|qris|e-?money|gopay|ovo|dana\b|shopeepay|kartu|card|payment/i;
  const CHANGE = /kembali|kembalian|change|susuk/i;
  const SUBTOTAL = /sub\s*-?\s*total|subtotal/i;
  const REDUCTION = /disc|disk|hemat|potongan|voucher|promo|poin|point/i;

  function parseReceipt(lines, ctx = {}) {
    const rows = toRows(lines);
    const all = rows.map((r) => r.text).join("\n");
    const money = rows.map((r) => ({ row: r, amounts: NOT_MONEY.test(r.text) ? [] : amountsIn(r.text) }))
      .filter((r) => r.amounts.length);
    const last = (r) => r.amounts[r.amounts.length - 1].value;

    let amount = 0, how = "";
    // 1. a row that says "total"
    let best = null;
    for (const r of money) {
      if (CHANGE.test(r.row.text) || REDUCTION.test(r.row.text)) continue;
      for (const [re, weight] of TOTAL_KEYS) {
        if (!re.test(r.row.text)) continue;
        const w = weight - (SUBTOTAL.test(r.row.text) ? 2.5 : 0);
        // on a tie the lower row wins: the final total comes after the subtotal
        if (!best || w >= best.w) best = { w, value: last(r) };
        break;
      }
    }
    if (best) { amount = best.value; how = "total line"; }
    // 2. what was paid minus the change
    if (!amount) {
      const paid = money.find((r) => PAID.test(r.row.text) && !CHANGE.test(r.row.text));
      const change = money.find((r) => CHANGE.test(r.row.text));
      if (paid) { amount = last(paid) - (change ? last(change) : 0); how = "paid minus change"; }
      if (amount <= 0) amount = 0;
    }
    // 3. the largest number that is not the cash handed over or the change
    if (!amount) {
      const pool = money.filter((r) => !PAID.test(r.row.text) && !CHANGE.test(r.row.text));
      amount = Math.max(0, ...pool.flatMap((r) => r.amounts.map((a) => a.value)));
      how = amount ? "largest amount" : "";
    }

    const description = findMerchant(rows);
    return {
      type: "expense", amount, description,
      category: guessCategory(description, ctx.categories, ctx.history),
      date: findDate(all), how,
    };
  }

  // ---------------------------------------------------------------- payslip
  const NET_PAY = /take\s*home|\bthp\b|gaji\s*bersih|net\s*pay|net\s*salary|penerimaan\s*bersih|penghasilan\s*bersih|total\s*(di)?terima|jumlah\s*(di)?terima|upah\s*bersih|dibayarkan|transfer(red)?\s*amount/i;

  function parsePayslip(lines) {
    const rows = toRows(lines);
    const all = rows.map((r) => r.text).join("\n");
    let amount = 0;
    for (let i = 0; i < rows.length && !amount; i++) {
      if (!NET_PAY.test(rows[i].text)) continue;
      // the figure is on the same row, or on the row just below the label
      for (const r of [rows[i], rows[i + 1]]) {
        const found = r ? amountsIn(r.text) : [];
        if (found.length) { amount = found[found.length - 1].value; break; }
      }
    }
    const employer = rows.slice(0, 4).map((r) => r.text)
      .find((t) => /\b(pt|cv|tbk|yayasan|persero|ltd|inc)\b/i.test(t)) || "";
    return {
      type: "income", amount,
      description: employer.replace(/\s*[-–|].*$/, "").replace(/\s+/g, " ").trim().slice(0, 60) || "Salary",
      category: "Salary",
      date: findDate(all) || findMonthEnd(all),
    };
  }

  // ---------------------------------------------------------------- history (mutasi) screenshot
  const SHORT_DATE = new RegExp(`(?<![\\d.,])(\\d{1,2})(?:[-/](\\d{1,2})(?![\\d.,])|[\\s.-]*(${MONTH_RE})\\b)`, "i");
  const IN_WORDS = /\bcr\b|kredit|credit|masuk|terima|diterima|received|refund|cashback|\+\s*(rp\.?)?\s*\d/i;
  const OUT_WORDS = /\bdb\b|debit|debet|keluar|bayar|pembayaran|purchase|belanja|tarik|withdraw|-\s*(rp\.?)?\s*\d/i;
  const BALANCE = /saldo|balance|sisa/i;
  const MONEY_TEXT = /[+-]?\s*(?:rp\.?|idr)?\s*\d{1,3}(?:[.,]\d{3})+(?:[.,]\d{2})?/gi;

  // Remove anything that reads as a date, so its digits are not taken for money or a name.
  const stripDates = (t) => t
    .replace(/20\d{2}[-/.]\d{1,2}[-/.]\d{1,2}/g, " ")
    .replace(/(?<![\d.,])\d{1,2}[-/]\d{1,2}(?:[-/]\d{2,4})?(?![\d.,])/g, " ")
    .replace(/(?<![\d.,])\d{1,2}\.\d{1,2}\.\d{2,4}(?![\d.,])/g, " ")
    .replace(new RegExp(`(?<!\\d)\\d{1,2}[\\s.-]*(?:${MONTH_RE})\\b\\.?(?:[\\s,.-]*\\d{4})?`, "gi"), " ");

  function rowDate(text) {
    const full = findDate(text);
    if (full) return full;
    const m = SHORT_DATE.exec(text);
    if (!m) return "";
    const month = m[2] ? +m[2] : MONTHS[m[3].toLowerCase()];
    const now = new Date();
    // a day-month with no year is this year, or last year if that would be in the future
    return validDate(now.getFullYear(), month, +m[1]) || validDate(now.getFullYear() - 1, month, +m[1]);
  }

  function parseHistory(lines, ctx = {}) {
    const rows = toRows(lines);
    const out = [];
    let carriedDate = "";
    for (const row of rows) {
      const text = row.text;
      const date = rowDate(text);
      const noDates = stripDates(text);
      const amounts = BALANCE.test(text) ? [] : amountsIn(noDates);
      if (date && !amounts.length) { carriedDate = date; continue; } // a date heading above its rows
      if (!amounts.length) continue;
      if (!date && !carriedDate) continue; // not a transaction row
      const first = amounts[0];
      const near = noDates.slice(Math.max(0, first.index - 6), first.index);
      const type = /-\s*(rp\.?)?\s*$/i.test(near) ? "expense" : /\+\s*(rp\.?)?\s*$/i.test(near) ? "income"
        : OUT_WORDS.test(text) ? "expense" : IN_WORDS.test(text) ? "income" : "expense";
      const description = noDates
        .replace(MONEY_TEXT, " ").replace(/\b\d{4,}\b/g, " ")
        .replace(/\b(db|cr|debit|debet|kredit|idr|rp)\b\.?/gi, " ")
        .replace(/\d{1,2}[:.]\d{2}(:\d{2})?/g, " ").replace(/\s+/g, " ").replace(/^[\s|:.+-]+|[\s|:.+-]+$/g, "");
      out.push({
        type, amount: first.value, description: description.slice(0, 80),
        category: type === "expense" ? guessCategory(description, ctx.categories, ctx.history) : "",
        date: date || carriedDate,
      });
    }
    return out;
  }

  // ---------------------------------------------------------------- entry point
  // Returns rows with an amount above zero, like the "ocr" function does.
  function parse(mode, lines, ctx) {
    const rows = mode === "history" ? parseHistory(lines, ctx)
      : [mode === "payslip" ? parsePayslip(lines) : parseReceipt(lines, ctx)];
    return rows.filter((r) => r.amount > 0);
  }

  const api = { parse, toRows, amountsIn, findDate, guessCategory };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.ReceiptParser = api;
})(typeof self !== "undefined" ? self : this);
