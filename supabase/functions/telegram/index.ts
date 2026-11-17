// Edge Function "telegram": the FinanceTracker bot as a Telegram webhook.
// Telegram calls this URL for every message, so no computer has to stay on.
//
// Deploy:   supabase functions deploy telegram --no-verify-jwt
// Secrets:  TELEGRAM_BOT_TOKEN, TELEGRAM_WEBHOOK_SECRET, GEMINI_API_KEY, EMAS_API_KEY (optional)
// Needs:    migration 20261116000000_telegram.sql
// Webhook:  python scripts/setup_telegram_webhook.py
//
// Security: there is no user login here, so
//  - every request must carry the webhook secret Telegram was given;
//  - a Telegram user can do nothing until they send "/link CODE" with a code
//    created in the app, which ties them to one user and one household;
//  - the service role bypasses row-level security, so EVERY query below is
//    filtered by that household id.
import { createClient } from "npm:@supabase/supabase-js@2";
import { encodeBase64 } from "jsr:@std/encoding@1/base64";
import { jakartaToday, readImage, type ScanMode, type ScanRow } from "../_shared/gemini.ts";
import { goldBuyback, stockPrice } from "../_shared/prices.ts";

const TOKEN = Deno.env.get("TELEGRAM_BOT_TOKEN") ?? "";
const WEBHOOK_SECRET = Deno.env.get("TELEGRAM_WEBHOOK_SECRET") ?? "";
// Compare in constant time so the secret cannot be guessed from response timing.
const sameSecret = (a: string, b: string) => {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
};
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

// ------------------------------------------------------------ types
type Entry = Omit<ScanRow, "type"> & { type: "income" | "expense" | "invest" };
type Pending = Entry & { source: string };
type State = {
  mode?: "payslip" | "history"; // what the next photo is
  pending?: Pending; // one entry waiting for a category and an account
  queue?: ScanRow[]; // history rows waiting for review; queue[0] is on screen
  kept?: number;
  rename?: boolean; // the next text message renames queue[0]
};
type Link = { user_id: string; household_id: string };
type Account = { account_id: string; name: string; archived: boolean; balance: number };
type Category = { id: string; name: string };
type Ctx = { chat: number; tgUser: number; link: Link; state: State };
type Button = { text: string; callback_data: string };
// deno-lint-ignore no-explicit-any
type Json = any;

// ------------------------------------------------------------ small helpers
const esc = (v: unknown) => String(v ?? "").replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]!));
const rp = (n: number) => (n < 0 ? "-" : "") + "Rp " + Math.round(Math.abs(n)).toLocaleString("id-ID");
const money = (s: string) => Number(String(s).replace(/[^\d]/g, "")) || 0;
// quantities may be decimal: "2,5" or "2.5" grams
const qty = (s: string) => parseFloat(String(s).replace(",", ".")) || 0;
const LINE = "━━━━━━━━━━━━━";
const TYPES: Record<string, "income" | "expense" | "invest"> = {
  income: "income", in: "income", masuk: "income",
  expense: "expense", out: "expense", keluar: "expense", exp: "expense",
  invest: "invest", investment: "invest", inv: "invest",
};

function must<T>(res: { data: T; error: { message: string } | null }): T {
  if (res.error) throw new Error(res.error.message);
  return res.data;
}

// ------------------------------------------------------------ Telegram API
async function tg(method: string, body: Record<string, unknown>): Promise<Json> {
  const res = await fetch(`https://api.telegram.org/bot${TOKEN}/${method}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  return await res.json();
}

const keyboard = (rows: Button[][]) => ({ reply_markup: { inline_keyboard: rows } });
const send = (chat: number, text: string, extra: Record<string, unknown> = {}) =>
  tg("sendMessage", { chat_id: chat, text, parse_mode: "HTML", ...extra });

// two buttons per row
function grid(buttons: Button[], perRow = 2): Button[][] {
  const rows: Button[][] = [];
  for (let i = 0; i < buttons.length; i += perRow) rows.push(buttons.slice(i, i + perRow));
  return rows;
}

// ------------------------------------------------------------ data (always scoped to the household)
async function loadState(tgUser: number): Promise<State> {
  const row = must(await db.from("telegram_state").select("state").eq("telegram_user_id", tgUser).maybeSingle());
  return (row?.state as State) ?? {};
}
async function saveState(ctx: Ctx): Promise<void> {
  must(await db.from("telegram_state").upsert({
    telegram_user_id: ctx.tgUser, state: ctx.state, updated_at: new Date().toISOString(),
  }));
}

async function accounts(hid: string, withArchived = false): Promise<Account[]> {
  const rows = must(await db.from("account_balances").select("account_id, name, archived, balance")
    .eq("household_id", hid).order("sort_order").order("name")) as Account[];
  return rows.filter((a) => withArchived || !a.archived).map((a) => ({ ...a, balance: Number(a.balance) }));
}
async function categories(hid: string): Promise<Category[]> {
  return must(await db.from("categories").select("id, name").eq("household_id", hid).order("name")) as Category[];
}
async function categoryId(hid: string, name: string): Promise<string> {
  const all = await categories(hid);
  const hit = all.find((c) => c.name.toLowerCase() === name.toLowerCase());
  if (hit) return hit.id;
  const row = must(await db.from("categories").insert({ household_id: hid, name }).select("id").single()) as { id: string };
  return row.id;
}

// "ivan" -> the Ivan account; also accepts the name with spaces removed or a unique prefix
function findAccount(list: Account[], word: string): Account | null {
  const w = word.toLowerCase();
  const exact = list.find((a) => a.name.toLowerCase() === w || a.name.toLowerCase().replace(/\s+/g, "") === w);
  if (exact) return exact;
  const starts = list.filter((a) => a.name.toLowerCase().startsWith(w));
  return starts.length === 1 ? starts[0] : null;
}

// ------------------------------------------------------------ the "pending entry" pipeline
// An entry needs a category, then an account, then it is saved.
const describe = (p: Entry) =>
  `${p.type === "income" ? "🟢 Income" : p.type === "expense" ? "🔴 Expense" : "🔵 Invest"}  <b>${rp(p.amount)}</b>\n` +
  `${esc(p.description || "(no description)")}\n` +
  `${esc(p.category || "No category yet")} · ${esc(p.date || jakartaToday())}`;

async function askNext(ctx: Ctx): Promise<void> {
  const p = ctx.state.pending!;
  if (!p.category) {
    const cats = await categories(ctx.link.household_id);
    await send(ctx.chat, `${describe(p)}\n\nWhich category?`, keyboard([
      ...grid(cats.map((c) => ({ text: c.name, callback_data: `c:${c.id}` }))),
      [{ text: "✖ Cancel", callback_data: "x" }],
    ]));
    return;
  }
  const accts = await accounts(ctx.link.household_id);
  if (!accts.length) {
    ctx.state.pending = undefined;
    await send(ctx.chat, "You have no accounts yet. Add one in the app first (Settings → Accounts).");
    return;
  }
  await send(ctx.chat, `${describe(p)}\n\nWhich account?`, keyboard([
    ...grid(accts.map((a) => ({ text: a.name, callback_data: `a:${a.account_id}` }))),
    [{ text: "✖ Cancel", callback_data: "x" }],
  ]));
}

async function savePending(ctx: Ctx, account: Account): Promise<void> {
  const p = ctx.state.pending!;
  const hid = ctx.link.household_id;
  must(await db.from("transactions").insert({
    household_id: hid,
    date: p.date || jakartaToday(),
    type: p.type,
    category_id: await categoryId(hid, p.category || "Other"),
    description: p.description,
    amount: p.amount,
    source: p.source,
    account_id: account.account_id,
    created_by: ctx.link.user_id,
  }));
  ctx.state.pending = undefined;
  await send(ctx.chat, `✅ Saved to <b>${esc(account.name)}</b>\n${describe(p)}`);
  if (ctx.state.queue?.length) { // this entry came from a history review
    ctx.state.kept = (ctx.state.kept ?? 0) + 1;
    ctx.state.queue.shift();
    await showReview(ctx);
  }
}

// ------------------------------------------------------------ history review (one card per row)
async function showReview(ctx: Ctx): Promise<void> {
  const queue = ctx.state.queue ?? [];
  if (!queue.length) {
    const kept = ctx.state.kept ?? 0;
    ctx.state.queue = undefined;
    ctx.state.kept = undefined;
    await send(ctx.chat, `Review finished. ${kept} saved.`);
    return;
  }
  await send(ctx.chat, `<b>${queue.length} left to review</b>\n\n${describe(queue[0])}`, keyboard([
    [{ text: "✅ Keep", callback_data: "rk" }, { text: "✏️ Rename", callback_data: "rr" }],
    [{ text: "⏭ Skip", callback_data: "rs" }, { text: "✖ Stop review", callback_data: "rx" }],
  ]));
}

// ------------------------------------------------------------ photos
async function downloadPhoto(fileId: string): Promise<{ image: string; mime: string }> {
  const info = await tg("getFile", { file_id: fileId });
  const path = info?.result?.file_path;
  if (!path) throw new Error("Could not fetch that photo from Telegram.");
  const res = await fetch(`https://api.telegram.org/file/bot${TOKEN}/${path}`);
  if (!res.ok) throw new Error("Could not download that photo from Telegram.");
  const bytes = new Uint8Array(await res.arrayBuffer());
  if (bytes.length > 4_500_000) throw new Error("That image is too large. Send it as a photo, not a file.");
  const mime = /\.png$/i.test(path) ? "image/png" : /\.webp$/i.test(path) ? "image/webp" : "image/jpeg";
  return { image: encodeBase64(bytes), mime };
}

async function onPhoto(ctx: Ctx, fileId: string): Promise<void> {
  const mode: ScanMode = ctx.state.mode ?? "receipt";
  ctx.state.mode = undefined;
  await tg("sendChatAction", { chat_id: ctx.chat, action: "typing" });

  const limit = await db.rpc("use_ocr_scan_for", { p_user: ctx.link.user_id });
  if (limit.error) { await send(ctx.chat, `⚠️ ${esc(limit.error.message)}`); return; }

  const cats = (await categories(ctx.link.household_id)).map((c) => c.name);
  const { image, mime } = await downloadPhoto(fileId);
  const rows = await readImage(mode, image, mime, cats.length ? cats : ["Other"]);
  if (!rows.length) {
    await send(ctx.chat, "I could not read anything from that photo. Try a sharper, well-lit one, or use /add.");
    return;
  }
  if (mode === "history") {
    ctx.state.pending = undefined;
    ctx.state.queue = rows;
    ctx.state.kept = 0;
    await send(ctx.chat, `📋 I read <b>${rows.length}</b> rows. Check them one by one.`);
    await showReview(ctx);
    return;
  }
  ctx.state.queue = undefined;
  ctx.state.pending = { ...rows[0], source: "telegram-ocr" };
  await askNext(ctx);
}

// ------------------------------------------------------------ commands
const HELP =
  "💰 <b>Finance Tracker Bot</b>\n\n" +
  "<b>Add by text</b>\n" +
  "<code>/add &lt;type&gt; &lt;amount&gt; &lt;description&gt;</code>\n" +
  "Example: <code>/add expense 85000 lunch at warung</code>\n" +
  "Type = income / expense / invest. I then ask for the category and account.\n\n" +
  "<b>Add by photo</b>\n" +
  "• Send a <b>receipt</b> → expense\n" +
  "• /payslip then send your <b>slip gaji</b> → net pay as income\n" +
  "• /history then send a <b>mutasi screenshot</b> → review each row\n\n" +
  "<b>Investments</b>\n" +
  "/portfolio — live P&amp;L on gold and stocks\n" +
  "<code>/sell &lt;ticker&gt; &lt;qty&gt; &lt;price&gt; &lt;account&gt;</code>\n" +
  "/realized — profit and loss from past sales\n\n" +
  "<b>Transfer</b>\n" +
  "<code>/transfer &lt;from&gt; &lt;to&gt; &lt;amount&gt; [note]</code>\n\n" +
  "<b>Reports</b>\n" +
  "/accounts — balance per account\n" +
  "/summary — this month\n" +
  "/recent — last 5 transactions\n\n" +
  "/cancel — drop whatever is in progress\n" +
  "/unlink — disconnect this Telegram account";

async function cmdAdd(ctx: Ctx, args: string): Promise<void> {
  const m = args.match(/^(\S+)\s+(\S+)\s*(.*)$/s);
  const type = m ? TYPES[m[1].toLowerCase()] : undefined;
  const amount = m ? money(m[2]) : 0;
  if (!m || !type || amount <= 0) {
    await send(ctx.chat, "Format: <code>/add &lt;type&gt; &lt;amount&gt; &lt;description&gt;</code>\n" +
      "Example: <code>/add expense 85000 lunch at warung</code>\nType must be income, expense or invest.");
    return;
  }
  // "…  Food & Drink" at the end of the text picks that category straight away
  let description = m[3].trim(), category = "";
  const cats = (await categories(ctx.link.household_id)).sort((a, b) => b.name.length - a.name.length);
  for (const c of cats) {
    if (description.toLowerCase().endsWith(c.name.toLowerCase())) {
      const rest = description.slice(0, description.length - c.name.length);
      if (rest === "" || /\s$/.test(rest)) { category = c.name; description = rest.trim(); break; }
    }
  }
  ctx.state.queue = undefined;
  ctx.state.pending = { type, amount, description, category, date: "", source: "telegram" };
  await askNext(ctx);
}

async function cmdTransfer(ctx: Ctx, args: string): Promise<void> {
  const parts = args.split(/\s+/).filter(Boolean);
  const list = await accounts(ctx.link.household_id);
  const names = list.map((a) => a.name).join(", ");
  if (parts.length < 3) {
    await send(ctx.chat, "Format: <code>/transfer &lt;from&gt; &lt;to&gt; &lt;amount&gt; [note]</code>\n" +
      `Example: <code>/transfer Ivan Bersama 20000 shared bills</code>\nAccounts: ${esc(names)}`);
    return;
  }
  const from = findAccount(list, parts[0]), to = findAccount(list, parts[1]);
  const amount = money(parts[2]), note = parts.slice(3).join(" ");
  if (!from || !to) { await send(ctx.chat, `Unknown account. Use one of: ${esc(names)}`); return; }
  if (from.account_id === to.account_id) { await send(ctx.chat, "From and To must be different accounts."); return; }
  if (amount <= 0) { await send(ctx.chat, `I could not read the amount: ${esc(parts[2])}`); return; }
  must(await db.rpc("add_transfer", {
    p_household: ctx.link.household_id, p_from: from.account_id, p_to: to.account_id,
    p_amount: amount, p_date: jakartaToday(), p_note: note, p_source: "telegram",
  }));
  await send(ctx.chat, `🔁 <b>Transfer saved</b>\n${esc(from.name)} → ${esc(to.name)}\n${rp(amount)}` +
    (note ? `\n<i>${esc(note)}</i>` : ""));
}

async function cmdSell(ctx: Ctx, args: string): Promise<void> {
  const parts = args.split(/\s+/).filter(Boolean);
  const list = await accounts(ctx.link.household_id);
  const names = list.map((a) => a.name).join(", ");
  if (parts.length < 4) {
    await send(ctx.chat, "Format: <code>/sell &lt;ticker&gt; &lt;quantity&gt; &lt;sellprice&gt; &lt;account&gt;</code>\n" +
      "Stocks: <code>/sell BBCA 50 11000 Ivan</code>\nGold: <code>/sell LM 5 2475000 Mely</code>\n" +
      `More than one gold brand? Use <code>LM:Antam</code>\nAccounts: ${esc(names)}`);
    return;
  }
  const [rawTicker, brand = ""] = parts[0].split(":");
  const quantity = qty(parts[1]), price = money(parts[2]);
  const account = findAccount(list, parts[parts.length - 1]);
  if (!account) { await send(ctx.chat, `Unknown account. Use one of: ${esc(names)}`); return; }
  if (quantity <= 0 || price <= 0) { await send(ctx.chat, "I could not read the quantity or sell price."); return; }
  const res = await db.rpc("sell_holding", {
    p_household: ctx.link.household_id, p_quantity: quantity, p_sell_price: price,
    p_account: account.account_id, p_ticker: rawTicker.toUpperCase(), p_name: brand || null,
    p_date: jakartaToday(), p_source: "telegram",
  });
  if (res.error) { await send(ctx.chat, `⚠️ ${esc(res.error.message)}`); return; }
  const sale = res.data as Json;
  const pl = Number(sale.realized_pl);
  await send(ctx.chat, `${pl >= 0 ? "🟢" : "🔴"} <b>Sold ${quantity} ${esc(sale.name || sale.ticker)}</b>\n` +
    `Proceeds: ${rp(Number(sale.proceeds))} → ${esc(account.name)}\n` +
    `Cost: ${rp(Number(sale.cost_basis))}\nRealized: <b>${rp(pl)}</b>`);
}

async function cmdPortfolio(ctx: Ctx): Promise<void> {
  await tg("sendChatAction", { chat_id: ctx.chat, action: "typing" });
  const lots = must(await db.from("holdings").select("asset_type, ticker, name, quantity, buy_price")
    .eq("household_id", ctx.link.household_id)) as Json[];
  if (!lots.length) { await send(ctx.chat, "No holdings yet. Add one in the app (Portfolio → Add holding)."); return; }

  const map = new Map<string, { type: string; ticker: string; name: string; qty: number; cost: number }>();
  for (const h of lots) {
    const key = `${h.asset_type}|${h.ticker}|${String(h.name).toLowerCase()}`;
    const p = map.get(key) ?? { type: h.asset_type, ticker: h.ticker, name: h.name, qty: 0, cost: 0 };
    p.qty += Number(h.quantity);
    p.cost += Number(h.quantity) * Number(h.buy_price);
    map.set(key, p);
  }
  const positions = [...map.values()];
  const tickers = [...new Set(positions.filter((p) => p.type === "stock").map((p) => p.ticker))];
  const [gold, quotes] = await Promise.all([
    positions.some((p) => p.type === "gold") ? goldBuyback() : Promise.resolve(null),
    Promise.all(tickers.map(stockPrice)),
  ]);
  const price = (p: { type: string; ticker: string }) =>
    p.type === "gold" ? gold?.price ?? null : quotes[tickers.indexOf(p.ticker)] ?? null;

  const lines = ["📈 <b>Portfolio</b>\n"];
  let cost = 0, value = 0, unpriced = 0;
  for (const p of positions) {
    const now = price(p);
    cost += p.cost;
    const unit = p.type === "gold" ? "g" : "sh";
    if (now === null) {
      unpriced += 1;
      value += p.cost;
      lines.push(`• <b>${esc(p.name || p.ticker)}</b> ${p.qty} ${unit}\n   cost ${rp(p.cost)} · no live price`);
      continue;
    }
    const worth = p.qty * now, pl = worth - p.cost;
    value += worth;
    lines.push(`${pl >= 0 ? "🟢" : "🔴"} <b>${esc(p.name || p.ticker)}</b> ${p.qty} ${unit}\n` +
      `   ${rp(worth)} · ${pl >= 0 ? "+" : ""}${rp(pl)} (${p.cost ? ((pl / p.cost) * 100).toFixed(1) : "0"}%)`);
  }
  lines.push(LINE, `Cost: ${rp(cost)}`, `Value: <b>${rp(value)}</b>`, `P&amp;L: <b>${rp(value - cost)}</b>`);
  if (unpriced) lines.push(`<i>${unpriced} position(s) shown at cost because no live price was available.</i>`);
  await send(ctx.chat, lines.join("\n"));
}

async function cmdRealized(ctx: Ctx): Promise<void> {
  const rows = must(await db.from("sales").select("date, ticker, name, quantity, realized_pl")
    .eq("household_id", ctx.link.household_id).order("date", { ascending: false })) as Json[];
  if (!rows.length) { await send(ctx.chat, "No sales recorded yet. Use /sell to record one."); return; }
  const lines = ["💰 <b>Realized P&amp;L</b>\n"];
  for (const r of rows.slice(0, 10)) {
    const pl = Number(r.realized_pl);
    lines.push(`${pl >= 0 ? "🟢" : "🔴"} ${r.date}  ${esc(r.name || r.ticker)}  (${Number(r.quantity)})  ${rp(pl)}`);
  }
  const total = rows.reduce((s, r) => s + Number(r.realized_pl), 0);
  lines.push(LINE, `${total >= 0 ? "🟢" : "🔴"} <b>Total realized: ${rp(total)}</b>`);
  if (rows.length > 10) lines.push(`<i>Showing the latest 10 of ${rows.length}.</i>`);
  await send(ctx.chat, lines.join("\n"));
}

async function cmdAccounts(ctx: Ctx): Promise<void> {
  const list = await accounts(ctx.link.household_id);
  if (!list.length) { await send(ctx.chat, "No accounts yet. Add one in the app (Settings → Accounts)."); return; }
  const lines = ["💳 <b>Account balances</b>\n", ...list.map((a) => `• <b>${esc(a.name)}</b>: ${rp(a.balance)}`)];
  lines.push(LINE, `<b>Total</b>: ${rp(list.reduce((s, a) => s + a.balance, 0))}`);
  await send(ctx.chat, lines.join("\n"));
}

async function cmdSummary(ctx: Ctx): Promise<void> {
  const today = jakartaToday();
  const rows = must(await db.from("transactions").select("type, amount")
    .eq("household_id", ctx.link.household_id)
    .gte("date", `${today.slice(0, 7)}-01`).lte("date", today)
    .in("type", ["income", "expense", "invest"])) as Json[];
  const sum = (t: string) => rows.filter((r) => r.type === t).reduce((s, r) => s + Number(r.amount), 0);
  const income = sum("income"), expense = sum("expense"), invest = sum("invest");
  const net = income - expense - invest;
  await send(ctx.chat, "📊 <b>This month</b>\n\n" +
    `Income: ${rp(income)}\nExpenses: ${rp(expense)}\nInvestments: ${rp(invest)}\n${LINE}\n` +
    `Net balance: <b>${rp(net)}</b>\nSavings rate: ${income > 0 ? Math.round((net / income) * 100) : 0}%`);
}

async function cmdRecent(ctx: Ctx): Promise<void> {
  const rows = must(await db.from("transactions").select("date, type, amount, description, account_id")
    .eq("household_id", ctx.link.household_id)
    .order("date", { ascending: false }).order("created_at", { ascending: false }).limit(5)) as Json[];
  if (!rows.length) { await send(ctx.chat, "No transactions yet."); return; }
  const names = new Map((await accounts(ctx.link.household_id, true)).map((a) => [a.account_id, a.name]));
  const icon: Record<string, string> = { income: "🟢", expense: "🔴", invest: "🔵", "transfer-in": "🔁", "transfer-out": "🔁" };
  const lines = ["🧾 <b>Last 5</b>\n"];
  for (const t of rows) {
    const acc = names.get(t.account_id);
    lines.push(`${icon[t.type] ?? "•"} ${t.date}  ${rp(Number(t.amount))}  ${esc(t.description)}${acc ? `  ·  ${esc(acc)}` : ""}`);
  }
  await send(ctx.chat, lines.join("\n"));
}

async function onText(ctx: Ctx, text: string): Promise<void> {
  if (!text.startsWith("/")) {
    if (ctx.state.rename && ctx.state.queue?.length) {
      ctx.state.queue[0].description = text.trim().slice(0, 120);
      ctx.state.rename = false;
      await showReview(ctx);
      return;
    }
    await send(ctx.chat, "Send a receipt photo, or use /add. /help lists everything.");
    return;
  }
  const head = text.split(/\s+/)[0];
  const command = head.slice(1).split("@")[0].toLowerCase();
  const args = text.slice(head.length).trim();
  ctx.state.rename = false;

  switch (command) {
    case "start": case "help": await send(ctx.chat, HELP); break;
    case "add": await cmdAdd(ctx, args); break;
    case "transfer": await cmdTransfer(ctx, args); break;
    case "sell": await cmdSell(ctx, args); break;
    case "portfolio": case "pnl": await cmdPortfolio(ctx); break;
    case "realized": await cmdRealized(ctx); break;
    case "accounts": case "saldo": await cmdAccounts(ctx); break;
    case "summary": await cmdSummary(ctx); break;
    case "recent": await cmdRecent(ctx); break;
    case "payslip":
      ctx.state.mode = "payslip";
      await send(ctx.chat, "Send your payslip photo now. I will log the net take-home pay as income.");
      break;
    case "history":
      ctx.state.mode = "history";
      await send(ctx.chat, "Send the transaction-history screenshot now. You will review each row before it is saved.");
      break;
    case "cancel":
      ctx.state = {};
      await send(ctx.chat, "Cancelled. Nothing in progress.");
      break;
    case "unlink":
      must(await db.from("telegram_links").delete().eq("telegram_user_id", ctx.tgUser));
      ctx.state = {};
      await send(ctx.chat, "This Telegram account is disconnected. Link again from the app whenever you like.");
      break;
    case "link": await send(ctx.chat, "You are already linked. Use /unlink first to connect a different account."); break;
    default: await send(ctx.chat, "I don't know that command. /help lists everything.");
  }
}

// ------------------------------------------------------------ button presses
async function onCallback(ctx: Ctx, data: string): Promise<void> {
  const hid = ctx.link.household_id;
  if (data === "x") {
    ctx.state.pending = undefined;
    await send(ctx.chat, "Cancelled.");
    if (ctx.state.queue?.length) await showReview(ctx);
    return;
  }
  if (data.startsWith("c:") || data.startsWith("a:")) {
    if (!ctx.state.pending) { await send(ctx.chat, "That entry is no longer waiting. Start again with /add or a photo."); return; }
    const id = data.slice(2);
    if (data.startsWith("c:")) {
      const cat = (await categories(hid)).find((c) => c.id === id);
      if (!cat) { await send(ctx.chat, "That category no longer exists."); return; }
      ctx.state.pending.category = cat.name;
      await askNext(ctx);
    } else {
      const account = (await accounts(hid)).find((a) => a.account_id === id);
      if (!account) { await send(ctx.chat, "That account no longer exists."); return; }
      await savePending(ctx, account);
    }
    return;
  }
  // history review buttons
  const queue = ctx.state.queue ?? [];
  if (!queue.length) { await send(ctx.chat, "There is no review in progress."); return; }
  if (data === "rk") {
    ctx.state.pending = { ...queue[0], source: "telegram-ocr" };
    await askNext(ctx);
  } else if (data === "rr") {
    ctx.state.rename = true;
    await send(ctx.chat, "Type the new description.");
  } else if (data === "rs") {
    queue.shift();
    await showReview(ctx);
  } else if (data === "rx") {
    const kept = ctx.state.kept ?? 0;
    ctx.state.queue = undefined;
    ctx.state.kept = undefined;
    ctx.state.pending = undefined;
    await send(ctx.chat, `Review stopped. ${kept} saved, the rest dropped.`);
  }
}

// ------------------------------------------------------------ linking
async function tryLink(chat: number, tgUser: number, text: string): Promise<void> {
  const code = text.match(/^\/(?:link|start)(?:@\w+)?\s+([A-Za-z0-9]{6,12})\s*$/)?.[1]?.toUpperCase();
  if (!code) {
    await send(chat, "🔒 This bot is private.\n\nTo connect it, open the Finance Tracker app → Settings → " +
      "<b>Link Telegram</b>, then send me the code like this:\n<code>/link ABCD1234</code>");
    return;
  }
  const row = must(await db.from("telegram_link_codes").select("user_id, household_id, expires_at")
    .eq("code", code).maybeSingle()) as { user_id: string; household_id: string; expires_at: string } | null;
  if (!row || new Date(row.expires_at) < new Date()) {
    await send(chat, "That code is wrong or has expired. Create a new one in the app (Settings → Link Telegram).");
    return;
  }
  must(await db.from("telegram_link_codes").delete().eq("code", code));
  // one Telegram account per app user: replace any earlier link of that user
  must(await db.from("telegram_links").delete().eq("user_id", row.user_id));
  must(await db.from("telegram_links").insert({
    user_id: row.user_id, household_id: row.household_id, telegram_user_id: tgUser,
  }));
  await send(chat, "✅ Linked. Send a receipt photo or try /help.");
}

// ------------------------------------------------------------ entry point
Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("ok");
  if (!TOKEN || !WEBHOOK_SECRET || !sameSecret(req.headers.get("X-Telegram-Bot-Api-Secret-Token") ?? "", WEBHOOK_SECRET)) {
    return new Response("forbidden", { status: 403 });
  }

  let chat = 0;
  try {
    const update = await req.json();
    const message = update.message;
    const callback = update.callback_query;
    const from = message?.from ?? callback?.from;
    chat = message?.chat?.id ?? callback?.message?.chat?.id ?? 0;
    const chatType = message?.chat?.type ?? callback?.message?.chat?.type;
    if (!from || !chat || from.is_bot || chatType !== "private") return new Response("ok");
    if (callback) await tg("answerCallbackQuery", { callback_query_id: callback.id });

    const link = must(await db.from("telegram_links").select("user_id, household_id")
      .eq("telegram_user_id", from.id).maybeSingle()) as Link | null;
    if (!link) {
      await tryLink(chat, from.id, String(message?.text ?? ""));
      return new Response("ok");
    }

    const ctx: Ctx = { chat, tgUser: from.id, link, state: await loadState(from.id) };
    if (callback) {
      await onCallback(ctx, String(callback.data ?? ""));
    } else if (message.photo?.length) {
      await onPhoto(ctx, message.photo[message.photo.length - 1].file_id);
    } else if (message.document && String(message.document.mime_type ?? "").startsWith("image/")) {
      await onPhoto(ctx, message.document.file_id);
    } else if (typeof message.text === "string") {
      await onText(ctx, message.text.trim());
    } else {
      await send(chat, "Send a receipt photo, or use /add. /help lists everything.");
    }
    await saveState(ctx);
  } catch (e) {
    console.error(e);
    if (chat) await send(chat, `⚠️ ${esc((e as Error).message || "Something went wrong.")}`).catch(() => {});
  }
  // Always 200, otherwise Telegram keeps re-sending the same update.
  return new Response("ok");
});
