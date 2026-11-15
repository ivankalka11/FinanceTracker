# FinanceTracker

Self-hosted personal finance system for an Indonesian household. One Google Sheet is the database; a Google Apps Script web app is the only thing that reads or writes it; a web dashboard and a Telegram bot are the two front-ends.

## Goals

- Track income, expenses, investments and balances across three savings accounts: **Ivan**, **Mely**, **Bersama** (joint).
- Make logging near-effortless: a Telegram message or a photo of a receipt/payslip should be enough.
- Show live profit/loss on gold (Antam buyback) and IDX stocks alongside cash balances.
- Keep the data self-owned (in the user's own Google Sheet) and the running cost at zero (free tiers only).
- Fit the Indonesian context: Rupiah formatting, QRIS-style receipts, official Antam pricing.
- Planned, not done yet: 24/7 bot hosting (Fly.io Singapore is the leading candidate) and the dashboard on GitHub Pages.

## Architecture and flow

```
Telegram Bot ─┐
              ├──► Apps Script Web App (/exec, guarded by API_SECRET) ──► Google Sheet
Dashboard ────┘
```

- **Requests:** both front-ends call the `/exec` URL with `?action=...`. Reads are GET; writes are POST with a JSON body sent as `text/plain` (avoids a CORS preflight that Apps Script does not answer). Every call carries the shared secret.
- **API actions (`code.gs`):**
  - GET: `read`, `summary`, `holdings`, `accounts`, `portfolio`, `realized`
  - POST: `add`, `transfer`, `delete`, `addHolding`, `deleteHolding`, `sellHolding`
- **Text entry flow:** `/add` (or the dashboard form) → pick account → `add` action → row in the Transactions sheet.
- **Receipt flow:** photo → OCR (Gemini) extracts merchant, amount, date → bot asks category and account → `add` as expense.
- **Payslip flow:** `/payslip`, then photo → OCR reads net take-home and pay date → `add` as income.
- **History flow:** `/history`, then a screenshot of a transaction list → OCR parses many rows → bot shows a review card per row (keep / rename / skip, category, account) → `add` for each kept row.
- **Investment flow:** buy via `addHolding` (weighted-average cost per position) → `/portfolio` prices holdings live → `/sell` calls `sellHolding`, which records realized P&L → `/realized` lists it.
- **Transfer flow:** `/transfer` writes two linked rows and is excluded from income/expense totals.
- **Dates:** `add` accepts an optional `date` (`YYYY-MM-DD`), defaulting to today. The bot drops malformed or future dates.
- **Pricing:** fetched server-side only (bot or Apps Script), never in the browser.
  - Gold: stored as `ticker: "LM"` with the brand (e.g. "Antam") in `name`; buyback price from Emas API ID, updated daily around 08:30 WIB.
  - Stocks: Yahoo Finance with `.JK` appended automatically, about 15 minutes delayed.
- **Config:** one root `.env` serves both front-ends. The bot loads it through `TelegramBot/env_loader.py`; `scripts/build_dashboard_config.py` writes `Dashboard/config.js` containing only `APPS_SCRIPT_URL` and `API_SECRET`.

## Features

- **Dashboard:** add/delete transactions, holdings and transfers; per-account balances; expenses-by-category chart; searchable, filterable, sortable, paginated transaction table.
- **Telegram bot commands:** `/add`, `/payslip`, `/history`, `/portfolio`, `/sell`, `/realized`, `/accounts`, `/transfer`, `/summary`, `/recent`, plus sending a receipt photo directly.
- **OCR import:** receipts → expenses, payslips → income, history screenshots → reviewed bulk import.
- **Investments:** weighted-average positions, sell tracking, realized and unrealized P&L.
- **Multi-account:** balances per account and transfers between them.
- **Access control:** `API_SECRET` on the API; optional `ALLOWED_TELEGRAM_ID` locks the bot to one user.

## Tech used

| Part | Tech |
| --- | --- |
| Database | Google Sheets |
| Backend/API | Google Apps Script web app (`code.gs`) |
| Dashboard | HTML, CSS, vanilla JS, Chart.js (`Dashboard/`) |
| Bot | Python 3.12.7, pyTelegramBotAPI, requests, beautifulsoup4 (`TelegramBot/`) |
| OCR | Gemini API (`gemini-2.5-flash`, free tier); Anthropic as an optional paid provider via `OCR_PROVIDER` |
| Gold price | Emas API ID (official Antam buyback) |
| Stock price | Yahoo Finance (IDX `.JK`) |
| CI | GitHub Actions Jekyll → GitHub Pages workflow (`.github/workflows/jekyll-gh-pages.yml`) |

## Key files

- `code.gs`: the whole backend. Changes only take effect after redeploying the Apps Script web app.
- `TelegramBot/bot.py`: commands, OCR, review cards, API wrappers (`api_add`, `api_transfer`, `api_sell`, ...).
- `TelegramBot/pricing.py`: `get_gold_buyback()`, `get_stock_price()`, `build_portfolio()`.
- `TelegramBot/diagnose.py`: gold-pricing connectivity check.
- `Dashboard/app.js`: all dashboard logic; reads `window.FINANCE_CONFIG` from the generated `config.js`.
- `scripts/build_dashboard_config.py`: generates `Dashboard/config.js` from `.env`.

## V2 upgrade (in progress)

Target: Supabase as the default database (Google Sheet kept as a second source and nightly mirror), user-defined accounts, a phone-first PWA dashboard, and receipt OCR inside the app via a Supabase function. Build order: (1) Supabase schema, security and Sheet import, (2) PWA rebuild, (3) in-app OCR, (4) bot update and webhook, (5) Sheets mode and mirror.

- Phase 1 files: `supabase/migrations/20261114000000_init.sql` (schema, row-level security, RPCs) and `scripts/import_sheet_to_supabase.py` (re-runnable import, matched on `legacy_id`).
- Every table carries `household_id`; access is decided by `private.is_member()`. New tables must enable RLS and follow the same policy shape.
- `SUPABASE_SECRET_KEY` is server-side only. The browser gets only `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY`.
- Phase 2 files: `pwa/` (no build step: `index.html`, `styles.css`, `app.js`, `sw.js`, `manifest.webmanifest`, `icons/`), `scripts/build_pwa_config.py` (writes the git-ignored `pwa/config.js` and PNG icons), `supabase/functions/prices/index.ts` (live prices; the app falls back to cost when it is not deployed).
- `pwa/app.js` is one IIFE: state in `S`, views `viewHome/viewStats/viewPortfolio/viewSettings/viewActivity`, bottom-sheet forms `sheet*`, submit handlers in `forms`, click handlers in `actions`. Bump `VERSION` in `pwa/sw.js` whenever shell files change. Motion: `transition(update, kind)` wraps screen changes in a View Transition, `openFrom(el, open)` grows a sheet out of the tapped element and `closeSheet()` shrinks it back; the matching CSS is the `motion` block at the end of `styles.css` (all inside `prefers-reduced-motion: no-preference`).
- Phase 3 (scanning): on-device by default. `pwa/ocr-worker.js` runs PaddleOCR (`ppu-paddle-ocr@6.7.1` from jsDelivr, onnxruntime-web, PP-OCRv6 tiny models self-hosted in the git-ignored `pwa/models/`, fetched by `scripts/fetch_ocr_models.py`) and returns text lines with boxes. `pwa/receipt-parser.js` (`window.ReceiptParser.parse(mode, lines, ctx)`) turns lines into rows with rules only; test with `node tests/receipt_parser_test.js`. In `pwa/app.js`: `sheetScan` -> `runScan(file, engine)` -> `readTextOnDevice` + parser, or `readSmart` (the optional `supabase/functions/ocr` Gemini function, with the `use_ocr_scan()` daily limit from `supabase/migrations/20261115000000_ocr_usage.sql`); rows are reviewed through `sheetAdd(type, pre, scan)` with `S.scan`, saved with `source: "ocr"`. Photos are not stored.
- Phase 4 (shelved, not deployed; Settings row hidden unless `TELEGRAM_BOT` is set in `pwa/config.js`): `supabase/functions/telegram/index.ts` (the bot as a Telegram webhook; deployed with `--no-verify-jwt`, guarded by `TELEGRAM_WEBHOOK_SECRET`; uses the service role, so every query must filter by the linked `household_id`), `supabase/functions/_shared/gemini.ts` and `_shared/prices.ts` (shared by `ocr`, `prices` and `telegram`; redeploy all three after changing them), `supabase/migrations/20261116000000_telegram.sql` (`telegram_link_codes`, `telegram_state`, `create_telegram_link_code()`, `use_ocr_scan_for()`), `scripts/setup_telegram_webhook.py` (secrets, deploy, setWebhook; `--off` returns to polling). Linking: app Settings creates a one-time code, the user sends `/link CODE` to the bot. Bot conversation state lives in `telegram_state.state` (pending entry, review queue, next-photo mode).
- Hosting: `python scripts/deploy_pwa.py` uploads `pwa/` to Cloudflare Pages (`CLOUDFLARE_PAGES_PROJECT` in `.env`); `pwa/_headers` carries the content security policy, so new external hosts must be added there.
- Run locally with the `pwa` launch config (port 5173).
- `TelegramBot/bot.py` and the V1 `Dashboard/` still run on the Sheet. The Python bot only receives messages while no webhook is set.

## Working rules

- Never commit `.env` or `Dashboard/config.js`; never print their values.
- `API_SECRET` ships to the browser in `config.js`, so the dashboard is only as private as its URL.
- The account list (`Ivan`, `Mely`, `Bersama`) is hard-coded in `bot.py`; keep it in sync with the dashboard and `code.gs`.
- Keep `README.md` and `setup.md` in step with behavior changes.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
