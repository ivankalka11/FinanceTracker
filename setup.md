# FinanceTracker — Setup Guide (V1)

A self-hosted personal finance system for tracking income, expenses, investments, and balances across three savings accounts (Ivan, Mely, Bersama). Indonesian context: Rupiah formatting, QRIS-friendly, Antam gold buyback pricing.

The whole system is driven by a shared **Google Sheets** backend exposed through a **Google Apps Script** web app. Two front-ends talk to that API: a **web dashboard** and a **Telegram bot**.

---

## ⚠️ Before you do anything: rotate your credentials

The `.env` and `app.js` in this project folder contain **live secrets** (bot token, API secret, Gemini key, Emas key, deployed Apps Script URL). Treat them as compromised and rotate before sharing or deploying:

- **Telegram BOT_TOKEN** — in @BotFather, send `/revoke` then `/token` to get a fresh one.
- **GEMINI_API_KEY** — delete and regenerate in Google AI Studio.
- **EMAS_API_KEY** — regenerate in your Emas API ID dashboard.
- **API_SECRET** — change it in `Code.gs`, then update `.env` and `app.js` to match.

Never commit `.env` (add it to `.gitignore`). Keep the secret out of `app.js` if you can — it ships to the browser, so anyone who opens the dashboard can read it. For a private/personal dashboard that's an accepted tradeoff; just know the API is only as private as that URL + secret.

---

## Project structure

```
FinanceTracker/
├── Dashboard/
│   ├── dashboard.html      # UI shell + styles
│   ├── styles.css
│   └── app.js              # all dashboard logic (CONFIG block at top)
└── TelegramBot/
    ├── bot.py              # Telegram bot (commands, OCR, portfolio, transfers)
    ├── pricing.py          # market data: Antam gold buyback + IDX stock quotes
    ├── diagnose.py         # quick gold-pricing connectivity check
    ├── requirements.txt    # Python deps
    ├── runtime.txt         # python-3.12.7 (for PaaS hosting)
    ├── .python-version     # 3.12.7
    └── .env                # secrets (DO NOT COMMIT)
```

> Note: the backend lives in a separate **`Code.gs`** file inside the Google Apps Script editor — it isn't part of this folder. You need it deployed for either front-end to work.

---

## Prerequisites

- **Python 3.12.7** (matches `.python-version` / `runtime.txt`)
- A **Google account** (for Sheets + Apps Script)
- A **Telegram account** (to create the bot via @BotFather)
- API keys: **Gemini** (free OCR) and **Emas API ID** (free gold prices)

---

## Step 1 — Backend (Google Sheets + Apps Script)

1. Create a new Google Sheet. This is your database. The system expects tabs for transactions, holdings, accounts, and realized P&L (the Apps Script reads/writes these).
2. Open **Extensions → Apps Script** and paste in your `Code.gs`.
3. In `Code.gs`, set the `SECRET` constant to a value you choose (this is your `API_SECRET`).
4. **Deploy → New deployment → Web app**:
   - Execute as: **Me**
   - Who has access: **Anyone** (the secret is what protects it)
5. Copy the deployed `/exec` Web App URL — you'll paste it into both the bot's `.env` and the dashboard's `app.js`.

Whenever you change `Code.gs`, redeploy (or manage the deployment so the same URL serves the new code).

---

## Step 2 — Get your API keys

**Gemini (receipt/payslip OCR — free tier, ~1,500 req/day)**

1. Go to Google AI Studio and create an API key.
2. Put it in `.env` as `GEMINI_API_KEY`.

**Emas API ID (official Antam gold buyback price — free)**

1. Register at `https://emas.maulanar.my.id/register`.
2. Copy your key from the dashboard.
3. Put it in `.env` as `EMAS_API_KEY`.

**Telegram bot token**

1. Message @BotFather → `/newbot`, follow the prompts.
2. Copy the token into `.env` as `BOT_TOKEN`.

---

## Step 3 — Telegram bot

From `TelegramBot/`:

```bash
cd TelegramBot

# create + activate a virtual environment
python3 -m venv venv
source venv/bin/activate          # macOS/Linux
# (Windows: venv\Scripts\activate)

# install dependencies
python3 -m pip install -r requirements.txt
```

Create a `.env` file in `TelegramBot/` (use placeholders, fill with YOUR rotated values):

```env
BOT_TOKEN=your_telegram_bot_token
APPS_SCRIPT_URL=https://script.google.com/macros/s/XXXX/exec
API_SECRET=your_chosen_secret          # must match SECRET in Code.gs

# optional: lock the bot to only your Telegram user id (leave blank = open)
ALLOWED_TELEGRAM_ID=

# OCR
OCR_PROVIDER=gemini                    # "gemini" (free) or "anthropic" (paid)
GEMINI_API_KEY=your_gemini_key
GEMINI_MODEL=gemini-2.5-flash
ANTHROPIC_API_KEY=                     # only if OCR_PROVIDER=anthropic

# gold pricing
EMAS_API_KEY=your_emas_key
```

`bot.py` reads these via `os.environ`, so load the `.env` into your shell before running. Either export the vars manually, or use a loader. Simplest cross-platform option:

```bash
pip install python-dotenv
```

…and add `from dotenv import load_dotenv; load_dotenv()` near the top of `bot.py` (above the `os.environ[...]` reads). Otherwise export each variable in your shell session first.

Run it:

```bash
python3 bot.py
```

You should see `Bot is running (long polling)...`. Message your bot `/start` to confirm.

**Sanity-check gold pricing** (optional):

```bash
python3 diagnose.py
```

This prints whether `EMAS_API_KEY` is set and what the buyback endpoint returns.

---

## Step 4 — Dashboard

Open `Dashboard/app.js` and set the CONFIG block at the top:

```js
const API_URL = "https://script.google.com/macros/s/XXXX/exec"; // your /exec URL
const SECRET = "your_chosen_secret"; // must match Code.gs
```

To run locally, just open `dashboard.html` in a browser, or serve the folder:

```bash
cd Dashboard
python3 -m http.server 8000
# then visit http://localhost:8000/dashboard.html
```

The dashboard does full CRUD on transactions, investments, account balances, and transfers, with an expenses-by-category chart (Chart.js) and a filterable/sortable/paginated table.

---

## Bot command reference

```
/add <type> <amount> <description> [category]   add a transaction (type = income/expense/invest)
/payslip                                        next photo → net take-home logged as income
(send a receipt photo)                          OCR → logged as expense, asks which account

/portfolio                                      live P&L on gold + stocks
/sell <ticker> <qty> <price> <account>          sell a holding, records realized P&L
/realized                                       realized profit/loss from past sales

/accounts                                       balance per account (Ivan/Mely/Bersama)
/transfer <from> <to> <amount> [note]           move funds between accounts
/summary                                        this month's income/expense/balance
/recent                                         last 5 transactions
```

---

## How the pieces talk

```
Telegram Bot ─┐
              ├──► Apps Script Web App (/exec, guarded by API_SECRET) ──► Google Sheet
Dashboard ────┘
```

- **Transactions** flow in from the bot or the dashboard; both POST JSON as `text/plain` (this avoids a CORS preflight that Apps Script doesn't answer).
- **Gold** is standardized as `ticker: "LM"` with the brand (e.g. "Antam") in `name`, unifying gold and stocks under one holdings model. Buyback price comes from Emas API ID (official Antam, updated daily ~08:30 WIB).
- **Stocks** are priced via Yahoo Finance (`.JK` suffix added automatically), ~15 min delayed.
- **Transfers** write two linked rows and are excluded from income/expense totals.
- Live price fetching stays **server-side** (Apps Script / bot), never in the browser.

---

## Deployment notes (planned, not yet locked in)

- **Bot:** Fly.io (Singapore region, free tier, Dockerfile-based) is the leading candidate for 24/7 hosting. `runtime.txt` and `.python-version` pin Python 3.12.7 for the build. Railway was flagged as risky (credit exhaustion); AWS Free Tier has a limited credit window.
- **Dashboard:** GitHub Pages (static hosting). Remember the secret in `app.js` becomes public — only host a dashboard you're comfortable being reachable by anyone with the URL.

---

## Known limitation (V1)

Imported/screenshot-parsed transactions all land on **today's date** — `api_add` doesn't yet accept a `date` parameter, so historical dates from `/history` imports aren't persisted. Fix path: add a `date` field to the `add` action in `Code.gs` and pass it through `api_add` in `bot.py`.
