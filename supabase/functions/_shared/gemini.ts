// Shared by the "ocr" (app) and "telegram" (bot) functions: reads a receipt,
// payslip or transaction-history image with Gemini and returns clean rows.
// Needs the GEMINI_API_KEY secret (optional: GEMINI_MODEL).

export type ScanMode = "receipt" | "payslip" | "history";
export type ScanRow = {
  type: "income" | "expense";
  amount: number;
  description: string;
  category: string; // one of the given categories, or "" when unsure
  date: string; // YYYY-MM-DD or ""
};

export const SCAN_MODES: ScanMode[] = ["receipt", "payslip", "history"];
const MAX_ROWS = 60;
export const DEFAULT_CATEGORIES = [
  "Food & Drink", "Groceries", "Transport", "Shopping", "Bills & Utilities", "Health",
  "Entertainment", "Education", "Subscriptions", "Travel", "Gifts & Donations", "Family",
  "Fees & Charges", "Salary", "Other",
];

// Keep category names safe to place inside the prompt.
export function cleanCategories(input: unknown): string[] {
  const sent = (Array.isArray(input) ? input : [])
    .map((c) => String(c).replace(/[^\p{L}\p{N} &/.,'()-]/gu, "").trim().slice(0, 40))
    .filter(Boolean)
    .slice(0, 60);
  return sent.length ? sent : DEFAULT_CATEGORIES;
}

function prompt(mode: ScanMode, categories: string[]): string {
  const list = categories.join(", ");
  if (mode === "payslip") {
    return "This is a payslip / salary slip (slip gaji). Extract ONLY the final take-home net pay, " +
      "the amount actually received after all deductions (often labeled 'Take Home Pay', 'Gaji Bersih', " +
      "'Net Pay', 'Penerimaan Bersih', or 'THP'). Ignore gross salary, allowances, and deductions. " +
      "Respond with ONLY a JSON object with keys: " +
      '"amount" (number, the net take-home, no separators), ' +
      '"description" (employer name if visible, else "Salary"), ' +
      '"category" (always "Salary"), ' +
      '"date" (the pay date as YYYY-MM-DD if visible; if only the pay period month is shown, use the ' +
      'last day of that month; else empty string ""). ' +
      "If you cannot read the net pay, set amount to 0.";
  }
  if (mode === "history") {
    return "This is a screenshot of a bank/e-wallet transaction history (mutasi), a LIST of multiple " +
      "transactions. Extract EVERY transaction row you can read. Respond with ONLY a JSON array. " +
      "Each element is an object with keys: " +
      '"type" (either "income" for money received/credit/masuk, or "expense" for money spent/debit/keluar), ' +
      '"amount" (number, positive, no separators or currency symbols), ' +
      '"description" (merchant/counterparty or short label), ' +
      `"category" (one of: ${list}; empty string "" if unsure), ` +
      '"date" (the transaction date as YYYY-MM-DD if visible, else empty string). ' +
      "Infer type from sign, colour, +/- prefix, or labels like debit/kredit, masuk/keluar. " +
      "Skip running-balance figures and headers. If you can read no rows, return an empty array [].";
  }
  return "This is a receipt photo. Extract the transaction details. " +
    "Respond with ONLY a JSON object with keys: " +
    '"amount" (number, the grand total in the receipt currency, no separators), ' +
    '"description" (merchant name), ' +
    `"category" (one of: ${list}). If you cannot confidently determine the category from the receipt, ` +
    'set "category" to an empty string "" instead of guessing. ' +
    '"date" (the transaction date printed on the receipt as YYYY-MM-DD, else empty string ""). ' +
    "If you cannot read the total, set amount to 0.";
}

export const jakartaToday = () => new Date().toLocaleDateString("en-CA", { timeZone: "Asia/Jakarta" });

// YYYY-MM-DD if it is a real date that is not in the future (Jakarta time), else "".
export function cleanDate(value: unknown): string {
  const s = String(value ?? "").trim().slice(0, 10);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(s)) return "";
  const d = new Date(`${s}T00:00:00Z`);
  if (Number.isNaN(d.getTime()) || d.toISOString().slice(0, 10) !== s) return "";
  return s <= jakartaToday() ? s : "";
}

function cleanRow(raw: Record<string, unknown>, mode: ScanMode, categories: string[]): ScanRow {
  const amount = Math.round(Math.abs(Number(raw?.amount)) || 0);
  const wanted = String(raw?.category ?? "").trim().toLowerCase();
  const category = categories.find((c) => c.toLowerCase() === wanted) ?? "";
  const type = mode === "payslip" ? "income"
    : mode === "history" && raw?.type === "income" ? "income" : "expense";
  return {
    type,
    amount,
    description: String(raw?.description ?? "").trim().slice(0, 120),
    category: mode === "payslip" ? "Salary" : category,
    date: cleanDate(raw?.date),
  };
}

async function askGemini(image: string, mime: string, text: string): Promise<unknown> {
  const model = Deno.env.get("GEMINI_MODEL") || "gemini-2.5-flash";
  const res = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-goog-api-key": Deno.env.get("GEMINI_API_KEY") ?? "" },
      body: JSON.stringify({
        contents: [{ parts: [{ inline_data: { mime_type: mime, data: image } }, { text }] }],
        generationConfig: { response_mime_type: "application/json" },
      }),
    },
  );
  if (res.status === 429) throw new Error("The reader is busy (Gemini free limit). Try again in a minute.");
  if (!res.ok) throw new Error(`The reader failed (Gemini ${res.status}).`);
  const data = await res.json();
  const out = (data?.candidates?.[0]?.content?.parts ?? [])
    .map((p: { text?: string }) => p.text ?? "").join("")
    .replace(/```json|```/g, "").trim();
  try {
    return JSON.parse(out);
  } catch (_) {
    throw new Error("Could not read that image. Try a clearer photo.");
  }
}

// Reads one base64 image. Returns only rows with an amount above zero.
export async function readImage(
  mode: ScanMode, image: string, mime: string, categories: string[],
): Promise<ScanRow[]> {
  if (!Deno.env.get("GEMINI_API_KEY")) throw new Error("GEMINI_API_KEY is not set in Supabase secrets.");
  const parsed = await askGemini(image, mime, prompt(mode, categories));
  const list = Array.isArray(parsed) ? parsed : [parsed];
  return list.slice(0, MAX_ROWS)
    .map((r) => cleanRow((r ?? {}) as Record<string, unknown>, mode, categories))
    .filter((r) => r.amount > 0);
}
