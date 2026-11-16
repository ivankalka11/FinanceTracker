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
| V2.5 | Plans, in-app notifications (bell, per-kind switches), `pg_cron` checks at 07:00 and 19:00 WIB | Done, except Web Push |
| V2.6 | Plan ledger (add, take out, adjust), gold and stocks in plans, set aside and free to spend per account, plan section of the statement | Done; run `20261119000000_plan_ledger.sql` on the Supabase project |

## Next

1. **Web Push delivery** of notifications: VAPID keys, an Edge Function that sends rows with `sent_at is null`, a `push` handler in `pwa/sw.js`, a push switch per device, and the iPhone "Add to Home Screen" note. `pwa/_headers` must allow the push service endpoints.
2. **Run the pending migrations** on the Supabase project: `20261118000000_plans.sql` and `20261119000000_plan_ledger.sql`. Until then the app hides plans or falls back to deposit-only plans.
3. **Housekeeping on GitHub:** turn off GitHub Pages or delete `.github/workflows/jekyll-gh-pages.yml` (it publishes every tracked file and does not host the PWA).

## Open decisions

- Should the proceeds of selling an assigned holding go into the plan's cash? Today they do not.
- Should notification checks use live prices? Today the database uses cost.
- Should the closing statement value plan assets at the last day of the month instead of the price at closing?
- Should a plan contribution create a transfer automatically when a linked account is set?
- Receipt photo storage (`receipts` table): reserved, not used. Photos are not stored today.

## Parked (off the roadmap)

- Telegram bot as a Supabase webhook (`supabase/functions/telegram`): built, not deployed. Scanning in the app covers the need. Settings row is hidden unless `TELEGRAM_BOT` is set in `pwa/config.js`.
- Sheets mode and the nightly Sheet mirror.
- Hosting for the V1 bot (Fly.io was the candidate) and the V1 dashboard.
