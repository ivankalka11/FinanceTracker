// Shared by the "prices" (app) and "telegram" (bot) functions: live Antam gold
// buyback and IDX stock quotes. Gold needs the EMAS_API_KEY secret.

const UA = { "User-Agent": "Mozilla/5.0 (compatible; FinanceTracker/2.0)" };

export async function goldBuyback(): Promise<{ price: number; date: string } | null> {
  const key = Deno.env.get("EMAS_API_KEY");
  if (!key) return null;
  try {
    const url = "https://emas.maulanar.my.id/api/prices?brand=ANTAM&resource=antam&weight=1";
    const res = await fetch(url, { headers: { ...UA, "X-API-Key": key } });
    const rows = (await res.json()).data ?? [];
    for (const row of rows) {
      if (String(row.brand ?? "").toLowerCase() !== "antam") continue;
      if (Number(row.weight) !== 1) continue;
      const price = Number(row.buyback_price);
      if (price >= 500_000 && price <= 50_000_000) {
        return { price, date: String(row.updated_at ?? row.date ?? "") };
      }
    }
  } catch (_) { /* fall through */ }
  return null;
}

export async function stockPrice(ticker: string): Promise<number | null> {
  const symbol = ticker.includes(".") ? ticker : `${ticker}.JK`;
  try {
    const res = await fetch(
      `https://query1.finance.yahoo.com/v8/finance/chart/${encodeURIComponent(symbol)}?interval=1d&range=1d`,
      { headers: UA },
    );
    const price = (await res.json())?.chart?.result?.[0]?.meta?.regularMarketPrice;
    return typeof price === "number" ? price : null;
  } catch (_) {
    return null;
  }
}
