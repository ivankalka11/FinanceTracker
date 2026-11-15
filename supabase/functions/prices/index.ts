// Edge Function "prices": live Antam gold buyback + IDX stock quotes for the PWA.
// Prices are fetched server-side so the Emas API key never reaches the browser.
//
// Deploy:  supabase functions deploy prices
// Secret:  supabase secrets set EMAS_API_KEY=...
//
// Request:  POST { "tickers": ["BBCA"], "gold": true }   (signed-in users only)
// Response: { "gold": { "price": 1234567, "date": "..." } | null, "stocks": { "BBCA": 9500 } }
import { createClient } from "npm:@supabase/supabase-js@2";
import { goldBuyback, stockPrice } from "../_shared/prices.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  // Only signed-in users: check the caller's token against Supabase Auth.
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!);
  const { data, error } = await supabase.auth.getUser(token);
  if (error || !data.user) return json({ error: "Not signed in" }, 401);

  let body: { tickers?: unknown; gold?: unknown } = {};
  try { body = await req.json(); } catch (_) { /* empty body */ }
  const tickers = (Array.isArray(body.tickers) ? body.tickers : [])
    .map((t) => String(t).toUpperCase().trim())
    .filter((t) => /^[A-Z0-9.]{1,12}$/.test(t))
    .slice(0, 30);

  const [gold, quotes] = await Promise.all([
    body.gold ? goldBuyback() : Promise.resolve(null),
    Promise.all(tickers.map(stockPrice)),
  ]);
  const stocks: Record<string, number> = {};
  tickers.forEach((t, i) => { if (quotes[i] !== null) stocks[t] = quotes[i] as number; });

  return json({ gold, stocks });
});
