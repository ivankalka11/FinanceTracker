# FinanceTracker

A self-hosted personal finance system for an Indonesian household: Rupiah formatting, receipt capture and official Antam gold buyback pricing. You own the data and the running cost is zero (free tiers only).

**V2 (current)** is a phone-first web app (a PWA) on a **Supabase** database. **V1** is the original Google Sheet + Apps Script backend with a web dashboard and a Telegram bot; it is kept in the repo and still works.

---

## Features (V2 app)

- **Accounts you define**: any number of accounts per household, with opening balances, and transfers between them that stay out of income and expense totals.
- **Transactions**: income, expense and invest entries, categories, edit and delete, offline queue.
- **Scan**: photograph a receipt, payslip or a transaction-history screenshot. Text is read on the device (PaddleOCR); an optional Gemini function ("smart read") helps with hard photos. Nothing is saved until you check and tap Save.
- **Portfolio**: gold (Antam buyback) and IDX stocks, weighted-average cost, live profit and loss, sell tracking and realized P&L.
- **Monthly closing**: close a month to save its statement and lock its entries; owners can reopen the latest month.
- **Plans**: savings goals with a target amount and date. A plan is a set-aside on a real account, with its own ledger (add, take out, adjust), and can include gold and stocks you already hold. Each account shows balance, set aside and free to spend.
- **Notifications**: plan milestones, falling behind, deadlines and month-close reminders, in an in-app bell with per-kind switches. Phone push delivery is not built yet.
- **Households**: invite members by email; owners and members have different rights.

The V1 dashboard and Telegram bot (Google Sheet backend) are described in [`setup.md`](setup.md). What is built, what is next and what is parked is in [`plan.md`](plan.md).

---

## Architecture

```
V2:  Phone / browser (PWA)  ──►  Supabase  (Postgres + row-level security, Auth, Edge Functions)
                                   ├─ prices function  (Antam gold, Yahoo Finance)
                                   └─ ocr function     (optional Gemini "smart read")

V1:  Telegram Bot ─┐
                   ├──► Apps Script Web App (guarded by API_SECRET) ──► Google Sheet
     Dashboard ────┘
```

The PWA talks straight to Supabase with the signed-in user's session. Every table carries a `household_id` and row-level security lets only household members read or write it. Live prices are fetched server-side by an Edge Function, never in the browser.

---

## Tech stack

| Part | Tech |
| --- | --- |
| Database and auth | Supabase (Postgres, magic-link or password sign-in) |
| App | HTML, CSS, vanilla JS, Chart.js, no build step (`pwa/`) |
| Scanning | PaddleOCR on the device (ONNX runtime); optional Gemini function |
| Prices | Emas API ID (Antam buyback), Yahoo Finance (IDX `.JK`), via a Supabase function |
| Hosting | Cloudflare Pages (`scripts/deploy_pwa.py`) |
| V1 (kept) | Google Sheets + Apps Script, Dashboard, Python Telegram bot |

---

## Quick start (V2)

> Full steps, including the database, functions, hosting and every migration, are in [`setup.md`](setup.md).

1. Create a free Supabase project and paste `supabase/setup_all.sql` into the SQL Editor once (it is every migration in one file).
2. Copy `.env.example` to `.env` and fill in `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY`.
3. Run locally:

```bash
python scripts/build_pwa_config.py
python -m http.server 5173 --directory pwa
```

4. Open `http://localhost:5173` and sign in. To host it: `python scripts/deploy_pwa.py` (Cloudflare Pages).

To bring over V1 data, run `scripts/import_sheet_to_supabase.py` (safe to re-run).

Run the checks:

```bash
node tests/receipt_parser_test.js
sh tests/sql/run.sh        # database rules, needs Docker
```

---

## Repository layout

```
pwa/                 V2 app (index.html, app.js, styles.css, sw.js, receipt-parser.js, ocr-worker.js, _headers)
supabase/migrations/ database schema, security rules and functions, in order
supabase/functions/  Edge Functions: prices, ocr, and the shelved telegram webhook
scripts/             config build, Cloudflare deploy, OCR model fetch, Sheet import
tests/               parser tests and SQL tests
docs/                BRD.md (business requirements) and SRS.md (software requirements)
Dashboard/, TelegramBot/, code.gs   V1 (Google Sheet backend)
```

---

## Security and what is on GitHub

This repository is public. It must never hold a real secret.

- **Git-ignored, never committed:** `.env`, `Dashboard/config.js`, `pwa/config.js`, `pwa/models/`, `supabase/.temp/`, and `.claude/settings*.json`. Only `.env.example` (empty values) is tracked.
- **Safe in the browser:** `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY`. Row-level security protects the data, and sign-ups are turned off so people join by invite only.
- **Server-side only:** `SUPABASE_SECRET_KEY` (bypasses security), `BOT_TOKEN`, `GEMINI_API_KEY`, `EMAS_API_KEY`, `ANTHROPIC_API_KEY`, `TELEGRAM_WEBHOOK_SECRET`. Edge Function keys are stored with `supabase secrets set`, not in files.
- **V1 only:** `API_SECRET` ships to the browser inside `Dashboard/config.js`, so a V1 dashboard is only as private as its URL.
- If a secret is ever committed, rotate it first (removing it from history does not undo the exposure); see the checklist in [`setup.md`](setup.md).

---

## V1 reference: Telegram bot commands

```
/add <type> <amount> <description> [category]   add a transaction (income/expense/invest)
/payslip                                        next photo -> net take-home logged as income
(send a receipt photo)                          OCR -> expense, asks which account
/history                                        next photo -> expenses from a history screenshot
/portfolio                                      live P&L on gold + stocks
/sell <ticker> <qty> <price> <account>          sell a holding, records realized P&L
/realized                                       realized profit/loss from past sales
/accounts                                       balance per account
/transfer <from> <to> <amount> [note]           move funds between accounts
/summary                                        this month's income / expense / balance
/recent                                         last 5 transactions
```

The V1 `add` action accepts an optional `date` (`YYYY-MM-DD`) and falls back to today; the bot drops malformed or future dates. Redeploy the current `code.gs` after changing it, or an older deployment ignores `date`.
