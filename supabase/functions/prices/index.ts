// Edge Function "prices": live Antam gold buyback + IDX stock quotes for the PWA.
// Prices are fetched server-side so the Emas API key never reaches the browser.
//
// Deploy:  supabase functions deploy prices
// Secret:  supabase secrets set EMAS_API_KEY=...
//
// Request:  POST { "tickers": ["BBCA"], "gold": true, "date": "2026-10-31" }   (signed-in users only)
//           "date" is optional: with it, prices are those of that past day (last trading day on or before it).
// Response: { "gold": { "price": 1234567, "date": "..." } | null, "stocks": { "BBCA": 9500 },
//             "stockDates": { "BBCA": "2026-10-30" } }  (stockDates only with "date")
import { createClient } from "npm:@supabase/supabase-js@2";
import { corsFor } from "../_shared/cors.ts";
import { goldBuyback, goldBuybackOn, stockPrice, stockPriceOn } from "../_shared/prices.ts";

// Best-effort limit per signed-in user (kept in this instance's memory): every call can
// trigger several outbound price lookups, and the Emas API key has a usage cap.
const WINDOW_MS = 60_000, MAX_CALLS = 20;
const calls = new Map<string, { n: number; reset: number }>();
const limited = (uid: string) => {
  const now = Date.now();
  for (const [k, v] of calls) if (v.reset < now) calls.delete(k);
  const c = calls.get(uid) ?? { n: 0, reset: now + WINDOW_MS };
  c.n++;
  calls.set(uid, c);
  return c.n > MAX_CALLS;
};

Deno.serve(async (req) => {
  const cors = corsFor(req);
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  // Only signed-in users: check the caller's token against Supabase Auth.
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!);
  const { data, error } = await supabase.auth.getUser(token);
  if (error || !data.user) return json({ error: "Not signed in" }, 401);
  if (limited(data.user.id)) return json({ error: "Too many price requests. Try again in a minute." }, 429);

  let body: { tickers?: unknown; gold?: unknown; date?: unknown } = {};
  try { body = await req.json(); } catch (_) { /* empty body */ }
  const tickers = (Array.isArray(body.tickers) ? body.tickers : [])
    .map((t) => String(t).toUpperCase().trim())
    .filter((t) => /^[A-Z0-9.]{1,12}$/.test(t))
    .slice(0, 30);

  const date = typeof body.date === "string" && /^\d{4}-\d{2}-\d{2}$/.test(body.date) ? body.date : null;
  if (date) {
    const [gold, quotes] = await Promise.all([
      body.gold ? goldBuybackOn(date) : Promise.resolve(null),
      Promise.all(tickers.map((t) => stockPriceOn(t, date))),
    ]);
    const stocks: Record<string, number> = {}, stockDates: Record<string, string> = {};
    tickers.forEach((t, i) => { const q = quotes[i]; if (q) { stocks[t] = q.price; stockDates[t] = q.date; } });
    return json({ gold, stocks, stockDates });
  }

  const [gold, quotes] = await Promise.all([
    body.gold ? goldBuyback() : Promise.resolve(null),
    Promise.all(tickers.map(stockPrice)),
  ]);
  const stocks: Record<string, number> = {};
  tickers.forEach((t, i) => { if (quotes[i] !== null) stocks[t] = quotes[i] as number; });

  return json({ gold, stocks });
});
