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

// ---- Prices on a past day (used for month-end statements) ----

const DAY = 86_400_000;
const isoDay = (ms: number) => new Date(ms).toISOString().slice(0, 10);

// Antam buyback for one past day. The Emas API filters by update date
// (updated_at[eq]=YYYY-MM-DD); if that day has no row (weekend, holiday), the
// previous days are tried, up to a week back.
export async function goldBuybackOn(date: string): Promise<{ price: number; date: string } | null> {
  const key = Deno.env.get("EMAS_API_KEY");
  if (!key) return null;
  const start = Date.parse(`${date}T00:00:00Z`);
  for (let back = 0; back < 7; back++) {
    const day = isoDay(start - back * DAY);
    try {
      const url = "https://emas.maulanar.my.id/api/prices?brand=ANTAM&resource=antam&weight=1" +
        `&updated_at[eq]=${day}&sort_by=updated_at&order=desc&limit=5`;
      const res = await fetch(url, { headers: { ...UA, "X-API-Key": key } });
      const rows = (await res.json()).data ?? [];
      for (const row of rows) {
        if (String(row.brand ?? "").toLowerCase() !== "antam" || Number(row.weight) !== 1) continue;
        const price = Number(row.buyback_price);
        if (price >= 500_000 && price <= 50_000_000) return { price, date: day };
      }
    } catch (_) { /* try the previous day */ }
  }
  return null;
}

// Closing price of an IDX stock on a past day: the last trading day on or before it.
export async function stockPriceOn(ticker: string, date: string): Promise<{ price: number; date: string } | null> {
  const symbol = ticker.includes(".") ? ticker : `${ticker}.JK`;
  const end = Date.parse(`${date}T00:00:00Z`);
  try {
    const res = await fetch(
      `https://query1.finance.yahoo.com/v8/finance/chart/${encodeURIComponent(symbol)}` +
        `?interval=1d&period1=${Math.floor((end - 10 * DAY) / 1000)}&period2=${Math.floor((end + 2 * DAY) / 1000)}`,
      { headers: UA },
    );
    const r = (await res.json())?.chart?.result?.[0];
    const times: number[] = r?.timestamp ?? [];
    const closes: (number | null)[] = r?.indicators?.quote?.[0]?.close ?? [];
    let best: { price: number; date: string } | null = null;
    times.forEach((t, i) => {
      const day = isoDay((t + 7 * 3600) * 1000); // Jakarta calendar day
      const c = closes[i];
      if (typeof c === "number" && day <= date) best = { price: c, date: day };
    });
    return best;
  } catch (_) {
    return null;
  }
}
