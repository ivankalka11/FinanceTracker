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
| V2.5 | Plans, in-app notifications (bell, per-kind switches), `pg_cron` checks at 08:00, 12:00 and 16:00 WIB | Done (in-app bell only; Web Push dropped) |
| V2.6 | Plan ledger (add, take out, adjust), gold and stocks in plans, set aside and free to spend per account, plan section of the statement | Done; migrations run on the live Supabase project |
| V2.7 | Sale proceeds go into plan cash; plan assets on the statement valued at the month's last day | Code and tests done; run `20261120000000_plan_sale_and_month_end.sql` on Supabase and redeploy the `prices` function |
| V2.8 | Notification checks at 08:00, 12:00 and 16:00 WIB; Sync prices button on the Portfolio page | Code done; run `20261121000000_scheduled_jobs.sql` (needs pg_cron) and redeploy the app |
| V2.9 | Loans: lend from an account to a member, repayments, unpaid loans on each statement | Done; `20261122000000_loans.sql` is run on the live project (the Loans screens load) |
| V2.10 | Gold price fallback (public price-cards page when the Emas API fails); visual refresh: burgundy dark-glass theme, glass dropdown menus, calendar and category list, animation fixes | Done; redeploy the `prices` function and the app |
| V2.11 | Security hardening: integrity hashes on CDN scripts, tighter headers pinned to your Supabase host, Edge Function limits and optional origin lock, household and member limits, V1 formula and bot fixes | Done; rolled out (sign-ups off, hardening migration run, functions and app redeployed) |
| V2.12 | Query performance for larger data: membership checked once per query instead of per row (11 to 47 times faster reads at 100,000 rows), parallel history download, one write of the offline cache, one-pass totals | Code and tests done; run `20261124000000_query_performance.sql` and redeploy the app |
| V2.13 | Plan spending: pay a vendor from a plan as a real expense on an account you choose, in partial payments, while the plan keeps its progress; two charts on the monthly statement (expenses by account, expenses by category) | Code and tests done (`plan_spend_test.sql`, all 7 SQL suites pass; UI checked against a fake database); run `20261125000000_plan_spend.sql` on Supabase, then deploy the app |
| V2.14 | Smart read loading state: photo preview with a scan line, step text with seconds waited, Cancel, 45 second timeout, double-tap protection | Code done (FR-OCR-12); checked in the preview, not yet tried against a live Gemini scan; redeploy the app |

## Next

1. **V2.12 rollout:** run `supabase/migrations/20261124000000_query_performance.sql` in the SQL Editor, then `python scripts/deploy_pwa.py`. The V2.11 rollout and the GitHub Pages cleanup are done.
2. **V2.13 rollout:** run `supabase/migrations/20261125000000_plan_spend.sql` in the SQL Editor, then `python scripts/deploy_pwa.py`. Built in: migration `20261125000000_plan_spend.sql`, a Pay from plan sheet on the plan screen, the plan section of the statement, statement charts. Details: BR-51 to BR-56 in `docs/BRD.md`, FR-PLN-21 to FR-PLN-28, FR-CLS-18 and FR-CLS-19 in `docs/SRS.md`.
3. **V2.14 rollout:** try a smart read on a real photo (also Cancel and a slow case), then `python scripts/deploy_pwa.py`. Built in: `sheetScan` / `runScan` in `pwa/app.js` and the `.scan-busy` styles in `pwa/styles.css`; bump `VERSION` in `pwa/sw.js`. Details: FR-OCR-12 in `docs/SRS.md`.
2. Candidates when data grows: the scale fixes listed under Decisions made.

## Decisions made

- Sale proceeds of an assigned holding go into the plan's cash (V2.7).
- Paying from a plan (V2.13, proposed): a new ledger entry type `spend` is both a real expense on an account and cash leaving the plan. Progress = cash + gold and stocks + money spent, so paying a vendor 5 juta from a 30 juta plan leaves progress at 30 juta (25 juta cash + 5 juta spent). "Take out" stays for money that is released without counting as progress. Gold and stocks are sold first; the proceeds land in plan cash and can then be spent.
- Statement charts (V2.13, proposed) need no database change: the statement already carries expense per account and per category, for drafts and for stored snapshots.
- Closing a plan (V2.13, proposed): marking a plan achieved or cancelling it never moves money by itself. A confirmation sheet shows the cash and the gold and stocks still tied to it and lets the user release each; a cancelled plan shows "Cancelled at N%". Selling a holding keeps its current behaviour (proceeds go into the plan's cash unless the plan is cancelled).
- Notification checks keep valuing assets at cost: they react to money in and out, not to price swings.
- The closing statement values plan assets at the price of the month's last day (last trading day on or before it), shown with its date. Stocks use Yahoo's daily close; gold uses the Emas API's update-date filter, which could not be confirmed to hold history, so gold falls back to today's price (clearly dated) if it is not found.
- "Add money" to a plan never creates a transfer automatically.
- Holding prices are refreshed with a Sync prices button, not a scheduled job: simpler, no extra secrets, and the data is only needed when someone looks.
- Receipt photos are not stored. The unused `receipts` table can be dropped later.
- The look is dark burgundy glass on pages and modals; blur is kept off pages and moving tiles for scrolling speed. Pickers (dropdown, calendar, category list) are custom so they match; iPhone Safari keeps its native select picker.
- Public sign-ups stay off: the app cannot enforce it, so it is a Supabase setting to verify. The household and member limits and the generic add-member message reduce abuse but do not hide whether an email has an account.
- Query performance (V2.12, measured on 100,000 transactions as a signed-in user): reading the whole history fell from 1,178 ms to 104 ms, the deepest page from 1,736 ms to 97 ms, account balances from 928 ms to 36 ms and a row count from 842 ms to 18 ms, by checking membership once per query. The cause was the per-row `private.is_member()` call in the row-level security policies.
- Remaining scale limits, not worth the work at today's size (a few hundred rows): the app still downloads the whole history on start and after every write (about 30 MB of JSON at 100,000 rows), and its offline copy is trimmed to two years when it does not fit in localStorage. Fixes when needed: load recent months plus server totals, an IndexedDB cache, load Chart.js on demand, self-host fonts and libraries, and serve the app shell from cache first.

## Parked (off the roadmap)

- Telegram bot as a Supabase webhook (`supabase/functions/telegram`): built, not deployed. Scanning in the app covers the need. Settings row is hidden unless `TELEGRAM_BOT` is set in `pwa/config.js`.
- Web Push delivery of notifications: decided against; notifications stay in the in-app bell. The `push_subscriptions` table and `save_push_subscription()` stay unused (the table can be dropped later).
- Sheets mode and the nightly Sheet mirror.
- Hosting for the V1 bot (Fly.io was the candidate) and the V1 dashboard.
