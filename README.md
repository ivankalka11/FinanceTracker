# FinanceTracker

A self-hosted personal finance system built around a shared **Google Sheets** backend, with two front-ends that talk to it through a Google Apps Script web app: a **web dashboard** and a **Telegram bot**. Designed for the Indonesian context — Rupiah formatting, QRIS-friendly receipt capture, and official Antam gold buyback pricing.

Log income, expenses, and investments across multiple savings accounts; snap a photo of a receipt or payslip and let OCR extract the details; track live profit/loss on gold (Antam buyback) and IDX stocks; and move funds between accounts with transfers that stay out of your income/expense totals. Everything reads and writes to one Google Sheet, so your data stays yours.

---

## Features

- 📊 **Web dashboard** — full CRUD, expenses-by-category chart, filterable/sortable/paginated tables
- 🤖 **Telegram bot** — text commands, receipt & payslip OCR (Gemini), live portfolio P&L
- 💰 **Investments** — weighted-average positions, sell tracking, realized P&L
- 🏦 **Multi-account** — per-account balances and inter-account transfers
- 🥇 **Live pricing** — Antam gold buyback + IDX stock quotes, fetched server-side
- 📷 **OCR import** — receipts → expenses, payslips → net take-home income

---

## Architecture

```
Telegram Bot ─┐
              ├──► Apps Script Web App (/exec, guarded by a secret) ──► Google Sheet
Dashboard ────┘
```

Both front-ends POST JSON to a single Google Apps Script web app, which is the only thing that reads and writes the spreadsheet. Live price lookups (gold, stocks) happen server-side, never in the browser.

---

## Tech stack

| Part         | Tech                                           |
| ------------ | ---------------------------------------------- |
| Backend      | Google Sheets + Google Apps Script (`Code.gs`) |
| Dashboard    | HTML / CSS / vanilla JS, Chart.js              |
| Bot          | Python 3.12, pyTelegramBotAPI                  |
| OCR          | Gemini API (free tier)                         |
| Gold pricing | Emas API ID (official Antam buyback)           |
| Stock data   | Yahoo Finance (IDX `.JK`)                      |

---

## Quick start

> Full instructions, including backend deployment and credential setup, are in [`setup.md`](setup.md).

**1. Backend** — Create a Google Sheet, paste `Code.gs` into Apps Script, set a `SECRET`, and deploy as a Web App. Copy the `/exec` URL.

**2. Telegram bot**

```bash
cd TelegramBot
python3 -m venv venv && source venv/bin/activate
python3 -m pip install -r requirements.txt
# create .env (see below), then:
python3 bot.py
```

**3. Dashboard** — Set `API_URL` and `SECRET` at the top of `Dashboard/app.js`, then open `dashboard.html` (or serve the folder with `python3 -m http.server`).

### `.env` (TelegramBot/)

```env
BOT_TOKEN=your_telegram_bot_token
APPS_SCRIPT_URL=https://script.google.com/macros/s/XXXX/exec
API_SECRET=your_chosen_secret          # must match SECRET in Code.gs
ALLOWED_TELEGRAM_ID=                   # optional: lock bot to your user id
OCR_PROVIDER=gemini
GEMINI_API_KEY=your_gemini_key
GEMINI_MODEL=gemini-2.5-flash
EMAS_API_KEY=your_emas_key
```

---

## Bot commands

```
/add <type> <amount> <description> [category]   add a transaction (income/expense/invest)
/payslip                                        next photo → net take-home logged as income
(send a receipt photo)                          OCR → expense, asks which account
/history                                        next photo -> expenses from multiple history

/portfolio                                      live P&L on gold + stocks
/sell <ticker> <qty> <price> <account>          sell a holding, records realized P&L
/realized                                       realized profit/loss from past sales

/accounts                                       balance per account
/transfer <from> <to> <amount> [note]           move funds between accounts
/summary                                        this month's income / expense / balance
/recent                                         last 5 transactions
```

---

## Security note

Never commit your `.env` — add it to `.gitignore`. The dashboard's `SECRET` ships to the browser inside `app.js`, so anyone with the dashboard URL can read it; only host a dashboard you're comfortable being reachable by anyone who has the link.

---

## Known limitation

Imported / screenshot-parsed transactions currently land on **today's date** — the backend's `add` action doesn't yet accept a `date` parameter, so historical dates from imports aren't persisted. Fix path: add a `date` field to the `add` action in `Code.gs` and pass it through `api_add` in `bot.py`.
