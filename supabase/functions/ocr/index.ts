// Edge Function "ocr": reads a receipt, payslip or transaction-history photo
// with Gemini and returns rows for the PWA to review. Nothing is saved here.
// The Gemini key stays in Supabase secrets and never reaches the browser.
//
// Deploy:  supabase functions deploy ocr
// Secret:  supabase secrets set GEMINI_API_KEY=...   (optional: GEMINI_MODEL)
// Needs:   migration 20261115000000_ocr_usage.sql (daily limit per user)
//
// Request:  POST { "mode": "receipt" | "payslip" | "history",
//                  "image": "<base64>", "mime": "image/jpeg",
//                  "categories": ["Food & Drink", ...] }      (signed-in users only)
// Response: { "rows": [{ "type", "amount", "description", "category", "date" }], "left": 29 }
import { createClient } from "npm:@supabase/supabase-js@2";
import { cleanCategories, readImage, SCAN_MODES, type ScanMode } from "../_shared/gemini.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const MIMES = ["image/jpeg", "image/png", "image/webp"];
const MAX_BASE64 = 6_000_000; // about 4.5 MB of image

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Use POST" }, 405);
  if (!Deno.env.get("GEMINI_API_KEY")) return json({ error: "GEMINI_API_KEY is not set in Supabase secrets." }, 500);

  // Only signed-in users: check the caller's token against Supabase Auth.
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: `Bearer ${token}` } },
  });
  const { data: auth, error: authError } = await supabase.auth.getUser(token);
  if (authError || !auth.user) return json({ error: "Not signed in" }, 401);

  let body: { mode?: unknown; image?: unknown; mime?: unknown; categories?: unknown } = {};
  try { body = await req.json(); } catch (_) { return json({ error: "Send a JSON body" }, 400); }

  const mode = (SCAN_MODES as string[]).includes(String(body.mode)) ? String(body.mode) as ScanMode : "receipt";
  const mime = String(body.mime ?? "image/jpeg");
  const image = typeof body.image === "string" ? body.image : "";
  if (!MIMES.includes(mime)) return json({ error: "Send a JPEG, PNG or WebP image." }, 400);
  if (!image || image.length > MAX_BASE64 || !/^[A-Za-z0-9+/=]+$/.test(image)) {
    return json({ error: "The image is missing or too large." }, 400);
  }

  // Daily limit, counted in the database as the caller (see use_ocr_scan()).
  const { data: left, error: limitError } = await supabase.rpc("use_ocr_scan");
  if (limitError) return json({ error: limitError.message }, 429);

  try {
    const rows = await readImage(mode, image, mime, cleanCategories(body.categories));
    return json({ rows, left });
  } catch (e) {
    return json({ error: (e as Error).message }, 502);
  }
});
