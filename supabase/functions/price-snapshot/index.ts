// Edge Function "price-snapshot": saves today's Antam gold buyback and the price of
// every stock any household holds into the price_snapshots table.
// Called by pg_cron every day at 10:00 WIB (see 20261121000000_scheduled_jobs.sql);
// it is not for browsers, so it is guarded by a shared secret instead of a user login.
//
// Deploy:  supabase functions deploy price-snapshot --no-verify-jwt
// Secrets: CRON_SECRET (same value as the Vault secret "ft_cron_secret"), EMAS_API_KEY
import { createClient } from "npm:@supabase/supabase-js@2";
import { goldBuyback, stockPrice } from "../_shared/prices.ts";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

// constant-time comparison
function same(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

Deno.serve(async (req) => {
  const secret = Deno.env.get("CRON_SECRET") ?? "";
  if (!secret || !same(req.headers.get("x-cron-secret") ?? "", secret)) return json({ error: "Not allowed" }, 401);

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });
  const { data: held, error } = await db.from("holdings").select("asset_type, ticker");
  if (error) return json({ error: error.message }, 500);

  const goldHeld = (held ?? []).some((h) => h.asset_type === "gold");
  const tickers = [...new Set((held ?? []).filter((h) => h.asset_type === "stock")
    .map((h) => String(h.ticker).toUpperCase().trim()).filter((t) => /^[A-Z0-9.]{1,12}$/.test(t)))];

  const day = new Date(Date.now() + 7 * 3600 * 1000).toISOString().slice(0, 10); // Jakarta calendar day
  const rows: { asset_type: string; ticker: string; price: number; price_date: string }[] = [];

  if (goldHeld) {
    const g = await goldBuyback();
    if (g) rows.push({ asset_type: "gold", ticker: "LM", price: g.price, price_date: day });
  }
  const quotes = await Promise.all(tickers.map(stockPrice));
  tickers.forEach((t, i) => {
    const p = quotes[i];
    if (p !== null && p > 0) rows.push({ asset_type: "stock", ticker: t, price: p, price_date: day });
  });

  if (rows.length) {
    const { error: e } = await db.from("price_snapshots")
      .upsert(rows.map((r) => ({ ...r, fetched_at: new Date().toISOString() })), { onConflict: "asset_type,ticker,price_date" });
    if (e) return json({ error: e.message }, 500);
  }
  const wanted = tickers.length + (goldHeld ? 1 : 0);
  return json({ saved: rows.length, wanted, day });
});
