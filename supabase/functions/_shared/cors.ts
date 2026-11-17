// CORS for the browser-facing functions (ocr, prices).
//
// Optional secret:  supabase secrets set ALLOWED_ORIGINS=https://your-app.pages.dev
// (comma-separated for several). Unset, any origin is allowed, as before. The functions
// also require a signed-in user's token, so this is a second lock, not the only one.
export function corsFor(req: Request): Record<string, string> {
  const allowed = (Deno.env.get("ALLOWED_ORIGINS") ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  const origin = req.headers.get("Origin") ?? "";
  const allow = allowed.length === 0 ? "*" : allowed.includes(origin) ? origin : allowed[0];
  return {
    "Access-Control-Allow-Origin": allow,
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}
