# FinanceTracker: roadmap and status

What is built, what is next, and what is parked. For what the app does and how to run it, see [`README.md`](README.md); for step-by-step setup, [`setup.md`](setup.md); for the formal requirements, `docs/BRD.md` and `docs/SRS.md`.

## Direction

Supabase is the default database. The phone-first PWA (`pwa/`) is the main front-end, hosted on Cloudflare Pages. The V1 Google Sheet, Dashboard and Telegram bot stay in the repo and still work, but are no longer developed.

## Status

| Version | What | Status |
| --- | --- | --- |
| V2.1 | Supabase schema, row-level security, Sheet import (`scripts/import_sheet_to_supabase.py`) | Done |
| V2.2 | Phone-first PWA with offline queue, hosted on Cloudflare Pages | Done |
| V2.3 | In-app scanning: on-device PaddleOCR by default, optional Gemini "smart read" | Done |
| V2.4 | Monthly ledger closing: draft statement, owner closes by hand, lock, reopen, history | Done |
| V2.5 | Plans, in-app notifications (bell, per-kind switches), `pg_cron` checks at 08:00, 12:00 and 16:00 WIB | Done, except Web Push |
| V2.6 | Plan ledger (add, take out, adjust), gold and stocks in plans, set aside and free to spend per account, plan section of the statement | Done; migrations run on the live Supabase project |
| V2.7 | Sale proceeds go into plan cash; plan assets on the statement valued at the month's last day | Code and tests done; run `20261120000000_plan_sale_and_month_end.sql` on Supabase and redeploy the `prices` function |
| V2.8 | Notification checks at 08:00, 12:00 and 16:00 WIB; Sync prices button on the Portfolio page | Code done; run `20261121000000_scheduled_jobs.sql` (needs pg_cron) and redeploy the app |

## Next

1. **Web Push delivery** of notifications: VAPID keys, an Edge Function that sends rows with `sent_at is null`, a `push` handler in `pwa/sw.js`, a push switch per device, and the iPhone "Add to Home Screen" note. `pwa/_headers` must allow the push service endpoints.
2. **Housekeeping on GitHub:** make sure GitHub Pages is turned off in the repository settings (the sample Jekyll workflow was removed).

## Decisions made

- Sale proceeds of an assigned holding go into the plan's cash (V2.7).
- Notification checks keep valuing assets at cost: they react to money in and out, not to price swings.
- The closing statement values plan assets at the price of the month's last day (last trading day on or before it), shown with its date. Stocks use Yahoo's daily close; gold uses the Emas API's update-date filter, which could not be confirmed to hold history, so gold falls back to today's price (clearly dated) if it is not found.
- "Add money" to a plan never creates a transfer automatically.
- Holding prices are refreshed with a Sync prices button, not a scheduled job: simpler, no extra secrets, and the data is only needed when someone looks.
- Receipt photos are not stored. The unused `receipts` table can be dropped later.

## Parked (off the roadmap)

- Telegram bot as a Supabase webhook (`supabase/functions/telegram`): built, not deployed. Scanning in the app covers the need. Settings row is hidden unless `TELEGRAM_BOT` is set in `pwa/config.js`.
- Sheets mode and the nightly Sheet mirror.
- Hosting for the V1 bot (Fly.io was the candidate) and the V1 dashboard.
