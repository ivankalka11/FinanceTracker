# FinanceTracker — Setup Guide (V1)

A self-hosted personal finance system for tracking income, expenses, investments, and balances across three savings accounts (Ivan, Mely, Bersama). Indonesian context: Rupiah formatting, QRIS-friendly, Antam gold buyback pricing.

The whole system is driven by a shared **Google Sheets** backend exposed through a **Google Apps Script** web app. Two front-ends talk to that API: a **web dashboard** and a **Telegram bot**.

---

## ⚠️ Before you do anything: rotate your credentials

The root `.env` (and the generated `Dashboard/config.js`) contain **live secrets** (bot token, API secret, Gemini key, Emas key, deployed Apps Script URL). Treat them as compromised and rotate before sharing or deploying:

- **Telegram BOT_TOKEN** — in @BotFather, send `/revoke` then `/token` to get a fresh one.
- **GEMINI_API_KEY** — delete and regenerate in Google AI Studio.
- **EMAS_API_KEY** — regenerate in your Emas API ID dashboard.
- **API_SECRET** — change it in `Code.gs`, then update `API_SECRET` in the root `.env` and re-run `python scripts/build_dashboard_config.py`.

Never commit `.env` or `Dashboard/config.js` (both are git-ignored). Note that `API_SECRET` ships to the browser, so anyone who opens the dashboard can read it. For a private/personal dashboard that's an accepted tradeoff; just know the API is only as private as that URL + secret.

---

## Project structure

```
FinanceTracker/
├── Dashboard/
│   ├── dashboard.html      # UI shell + styles
│   ├── styles.css
│   ├── app.js              # all dashboard logic (reads window.FINANCE_CONFIG)
│   └── config.js           # GENERATED from .env (git-ignored)
└── TelegramBot/
    ├── bot.py              # Telegram bot (commands, OCR, portfolio, transfers)
    ├── pricing.py          # market data: Antam gold buyback + IDX stock quotes
    ├── diagnose.py         # quick gold-pricing connectivity check
    ├── requirements.txt    # Python deps
    ├── runtime.txt         # python-3.12.7 (for PaaS hosting)
    ├── .python-version     # 3.12.7
    └── (secrets live in the root .env — DO NOT COMMIT)
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
5. Copy the deployed `/exec` Web App URL — you'll paste it into the root `.env` as `APPS_SCRIPT_URL` (shared by the bot and the dashboard).

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

Copy `.env.example` to `.env` in the **project root** (one file for both the bot and the dashboard) and fill it with YOUR rotated values:

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

`bot.py` loads the root `.env` automatically via `TelegramBot/env_loader.py` (no extra package). Variables already set in the real environment (e.g. on a host) take precedence.

For the dashboard, generate its config from the same file:

```bash
python scripts/build_dashboard_config.py
```

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

The dashboard reads `APPS_SCRIPT_URL` and `API_SECRET` from the root `.env`. Generate its config (re-run whenever `.env` changes):

```bash
python scripts/build_dashboard_config.py
```

This writes `Dashboard/config.js` with only those two values; bot-only keys never reach the browser.

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

## V2 phase 1 — Supabase database (in progress)

V2 moves the default database to Supabase and keeps the Google Sheet as a second source. Phase 1 adds the database only; the bot and dashboard still use the Sheet until phase 2.

1. **Create the project.** At supabase.com create a free project (region: Singapore). Save the database password in a password manager.
2. **Create the tables and security rules.** Open **SQL Editor**, paste all of `supabase/migrations/20261114000000_init.sql`, and run it once. (With the Supabase CLI: `supabase link`, then `supabase db push`.)
3. **Lock down sign-in.** In **Authentication → Sign In / Providers**, turn off "Allow new users to sign up" and keep Email enabled (magic link). New people join by invite only.
4. **Add yourself.** In **Authentication → Users → Add user**, create your own user with your email.
5. **Fill in `.env`.** From **Project Settings → API keys**, copy the project URL, the publishable key and the secret key into `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` and `SUPABASE_SECRET_KEY`. The secret key bypasses all security rules: it is for server-side scripts only and must never reach the dashboard.
6. **Import the Sheet.** Activate the bot's virtual environment first (the script needs `requests`). Preview, then run for real:

```bash
python scripts/import_sheet_to_supabase.py --owner-email you@example.com --household "Keluarga" --dry-run
python scripts/import_sheet_to_supabase.py --owner-email you@example.com --household "Keluarga"
```

The import creates the household, one account per account name found in the Sheet, the categories, and all transactions, holdings and realized P&L. It ends with a per-account balance comparison between the Sheet and Supabase. It is safe to re-run: rows are matched on their V1 id.

What the migration sets up: tables `households`, `members`, `accounts`, `categories`, `transactions`, `holdings`, `sales`, `receipts`, `telegram_links`; a rule on every table that only household members can read or write its rows; the `account_balances` view; and the functions `create_household`, `add_member_by_email`, `add_transfer` and `sell_holding`.

---

## V2 phase 2 — the PWA (in progress)

The new phone-first app lives in `pwa/` and talks straight to Supabase. It is plain HTML, CSS and JavaScript with no build step. The V1 `Dashboard/` is untouched and still uses the Sheet.

**Run it locally**

```bash
python scripts/build_pwa_config.py
python -m http.server 5173 --directory pwa
```

Then open `http://localhost:5173`. The first command writes `pwa/config.js` (Supabase URL and publishable key only) and the PNG app icons. Re-run it when those values change. Sign in with the user you created in Supabase.

**What it does**

- Home: total balance, your accounts, this month's income/expense/invested, recent transactions.
- Add income, expense or invest entries; transfer between accounts; delete entries.
- Overview: period totals, a 6-month income and expense chart, expenses by category.
- Portfolio: positions with average cost, add a holding, sell (oldest lots first), realized P&L.
- Settings: add, rename, archive accounts and set opening balances; manage categories; add a household member; sign out.
- Installable (Add to Home Screen), opens offline with the last loaded data, and queues new entries made offline until the connection returns.

**Live prices (optional for now)**

Until the `prices` function is deployed, holdings show at cost. To turn on live gold and stock prices, deploy `supabase/functions/prices/index.ts`:

```bash
npx supabase login
npx supabase link --project-ref YOUR_PROJECT_ID
npx supabase secrets set EMAS_API_KEY=your_emas_key
npx supabase functions deploy prices
```

**Sign-in by email link**

Password sign-in works out of the box. For the "Email me a sign-in link" button, add the app's address under **Authentication → URL Configuration** (Site URL and Redirect URLs), for example `http://localhost:5173` and later your hosted address.

**Hosting (Cloudflare Pages)**

The simplest route uploads the `pwa` folder straight from your computer. No GitHub push is needed, and you need a free Cloudflare account.

1. Make sure `pwa/config.js` is current: `python scripts/build_pwa_config.py`.
2. Log in once (a browser window opens):

```bash
npx wrangler login
```

3. Pick your own project name and put it in `.env` as `CLOUDFLARE_PAGES_PROJECT=` (lowercase letters, numbers and dashes). It becomes the address `https://<name>.pages.dev`.
4. Upload. The first run asks to create the project; answer yes, and when it asks for the production branch, type `main`. If the name is already taken on pages.dev, Cloudflare adds a suffix to the address (for example `<name>-4ud.pages.dev`); the upload prints the real one.

```bash
python scripts/deploy_pwa.py
```

The script rebuilds `pwa/config.js` and then runs `npx wrangler pages deploy pwa --project-name <name> --branch main --commit-dirty=true` for you.

5. In Supabase, open **Authentication → URL Configuration** and set **Site URL** to the new address (also add it under Redirect URLs). Password sign-in works without this; the email sign-in link needs it.
6. On your phone, open the address, sign in, then use **Add to Home Screen**.

If the main address shows "404" after an upload, the upload went to a preview because the project's production branch is not the branch the script used. Wrangler-created projects use the git branch you were on when the project was first created. Either set `CLOUDFLARE_PAGES_BRANCH=` in `.env` to that branch name, or change **Production branch** to `main` in the Cloudflare dashboard (**Workers & Pages -> your project -> Settings**), then upload again.

For every later release, bump `VERSION` in `pwa/sw.js` and run the step 4 command again.

`pwa/_headers` tells Cloudflare to send security headers: a content security policy that only allows the app's own files, the two pinned libraries, Google Fonts and Supabase; no framing by other sites; no search-engine indexing. The address is public, so anyone can open the sign-in page, but data is only returned to signed-in household members.

Alternative (auto-deploy on push): connect the GitHub repo in Cloudflare Pages, set the build command to `python scripts/build_pwa_config.py`, the output directory to `pwa`, and add `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` as environment variables.

---

## V2 phase 3 - scanning in the app (in progress)

The centre button in the bottom bar opens **Scan**. Pick Receipt, Payslip or History, take a photo or choose one, and the app shows a "Check the details" sheet filled in from the photo. Nothing is saved until you tap Save. A History screenshot is reviewed one row at a time (Save or Skip). Manual entry stays on the Home **Add** button.

**How a photo is read**

1. **On the device (default).** The text is read by PaddleOCR (open source, PP-OCRv6 "tiny" models) running inside the app. No key, no server, no daily limit, and the photo is not uploaded. After the first scan it also works offline.
2. **Rules turn the text into fields** (`pwa/receipt-parser.js`): the total line, the date, the shop name. The category comes from your own history first (the same shop last time), then from a small keyword list.
3. **Smart read (optional).** If the result is wrong, "Try smart read" sends that photo to the `ocr` Supabase function, which asks Google Gemini. This is the only path that uploads the photo.

**Set up on-device reading (once per computer)**

```bash
python scripts/fetch_ocr_models.py
```

This downloads three model files (about 6.4 MB) into `pwa/models/`. The folder is git-ignored; `scripts/deploy_pwa.py` runs this step for you before each upload.

**Set up smart read (optional)**

1. In the Supabase dashboard, open **SQL Editor**, paste the contents of `supabase/migrations/20261115000000_ocr_usage.sql`, and run it. This adds the daily limit (30 smart reads per user per day; change `v_limit` in that file to adjust).
2. Deploy the function from the project folder:

```bash
npx supabase login
npx supabase link --project-ref YOUR_PROJECT_ID
npx supabase secrets set GEMINI_API_KEY=your_gemini_key
npx supabase functions deploy ocr
```

Without these, on-device scanning still works and "Try smart read" reports that it is not set up.

**Good to know**

- On-device rules are best-effort. Clear printed receipts work well; crumpled or faded receipts, unusual layouts, and long history screenshots are where smart read helps.
- The first scan downloads the reading engine (a few MB from jsDelivr) and is slower; later scans take a couple of seconds.
- A phone camera only opens on an HTTPS address, so host the app (see Cloudflare Pages above) before testing on a phone. On the computer, "Choose from gallery" works with image files.
- Gemini's free tier may use submitted images to improve Google's products. That applies to smart read only.
- Check the rules after changing them: `node tests/receipt_parser_test.js`.

---

## V2.4 - monthly ledger closing

Closing a month saves its statement and locks every entry dated in it or earlier. Only an owner closes or reopens a month, and only by hand.

1. In the Supabase dashboard, open **SQL Editor**, paste the contents of `supabase/migrations/20261117000000_ledger_closing.sql`, and run it once. Until then, Settings → Monthly statements says "Not set up yet" and nothing is locked.
2. Reload the app. When a month has ended, owners see a **Close <month>** card on Home.
3. To close: open the month, check the figures and the checklist, enter each account's bank balance on the last day (explain any difference, or fix the entries first), then tap **Close** twice.
4. The first close can be any finished month; everything before it is locked with it. After that, months close in order.
5. To fix a closed month: open it, give a reason and tap **Reopen**. Only the latest closed month can be reopened. Closing it again saves a new version; the old one stays in the history.
6. A closed statement can be printed (or saved as PDF from the print dialog) and exported as CSV.

## V2.5 - plans and notifications

Plans are savings goals (target amount and date) that you put money into over time. The database, the Plans screen and the notification bell are done; phone push comes next.

**Notifications:** the bell on Home shows how many are unread. Tap it for the list; tapping one marks it read and opens its plan or monthly statement. **Mark all read** and **Clear read** tidy the list. New notifications pop up while the app is open (through Supabase Realtime, which the plans migration turns on for the `notifications` table); otherwise they appear the next time the app opens. **Settings → Configuration → Notifications** has a switch per kind: plan milestones, falling behind, deadlines, the monthly reminder, and (owners only) the month-close reminder.

**Using plans:** Home shows a **Plans** card with the three nearest active plans; **See all** (or **+ Start a plan**) opens the Plans screen. Tap a plan to see its progress, a chart of saved money against the plan line, and the money added. **Add money** records money set aside; it can point at an existing income or transfer-in entry so the two are linked. From the same sheet you can edit, pause, resume, mark achieved or cancel a plan; **Delete plan** appears only while the plan has no money in it. Closed monthly statements list each plan's money for that month.

1. Run `20261117000000_ledger_closing.sql` first if you have not. Then, in **SQL Editor**, paste the contents of `supabase/migrations/20261118000000_plans.sql` and run it once.
2. What it sets up: tables `plans`, `plan_contributions`, `notifications`, `notification_prefs` and `push_subscriptions`; a `plans` section in every new closing statement; and the functions `check_notifications` (the app calls it when it opens) and `save_push_subscription`.
3. Notifications are created by the database: milestones (25/50/75/100%) as soon as money is added; "behind", 30 and 7 days to go, overdue, the monthly reminder from the 25th, and the month-close reminders when the daily check runs.
4. The daily check runs at 07:00 and 19:00 WIB through `pg_cron`. If the run prints "pg_cron is not set up", turn on **Database → Extensions → pg_cron** and run the file's last block again; until then the checks still run whenever the app opens.
5. Owners get every kind of notification unless they turn it off; other members get only the kinds they turn on. Month-close reminders go to owners only.
6. A plan that has money in it cannot be deleted, only cancelled. Money added to a plan follows the month lock, like transactions.

## V2 phase 4 - the Telegram bot on Supabase (shelved)

> Not in use. Scanning in the app covers the same need, so this is parked: the code is in the repo but nothing is deployed, and the "Telegram bot" row in Settings is hidden unless `TELEGRAM_BOT: true` is added to `pwa/config.js`. The steps below are kept in case it is wanted later.

The bot now exists as a Supabase function, `telegram`. Telegram calls it for every message (a "webhook"), so no computer has to stay on and no bot hosting is needed. It reads and writes Supabase, uses your own accounts and categories, and shares the same photo reader and daily scan limit as the app.

**Turn it on (once)**

1. In the Supabase dashboard, open **SQL Editor**, paste the contents of `supabase/migrations/20261116000000_telegram.sql`, and run it.
2. From the project folder (after `npx supabase login` and `npx supabase link`), run:

```bash
python scripts/setup_telegram_webhook.py
```

The script creates `TELEGRAM_WEBHOOK_SECRET` in `.env` if it is missing, stores the bot token, that secret, and the Gemini and Emas keys as Supabase secrets, deploys the function, and points Telegram at it. It prints no secret values.

3. The `ocr` and `prices` functions now share code with the bot. Redeploy them so all three run the same version:

```bash
npx supabase functions deploy ocr
```

```bash
npx supabase functions deploy prices
```

4. In the app, open **Settings -> Link Telegram**. It shows a message such as `/link ABCD1234`. Send that to your bot within 10 minutes. Each household member links their own Telegram account this way.

**Using it**

- Send a receipt photo, or `/add expense 85000 lunch at warung`. The bot asks for the category and the account with buttons, then saves.
- `/payslip` or `/history`, then a photo. History rows are reviewed one card at a time (Keep, Rename, Skip).
- `/transfer`, `/sell`, `/portfolio`, `/realized`, `/accounts`, `/summary`, `/recent` work as before. `/cancel` drops whatever is in progress; `/unlink` disconnects your Telegram account.

**Good to know**

- Once the webhook is on, the old Python bot (`TelegramBot/bot.py`) stops receiving messages; a bot can use only one of the two. To go back: `python scripts/setup_telegram_webhook.py --off`. To see the current state: `--status`.
- The bot answers only people who have linked from the app, and only in private chats. Everyone else gets a "this bot is private" reply.
- Entries are saved with source `telegram` (typed) or `telegram-ocr` (from a photo).

---

## Deployment notes (planned, not yet locked in)

- **Bot:** Fly.io (Singapore region, free tier, Dockerfile-based) is the leading candidate for 24/7 hosting. `runtime.txt` and `.python-version` pin Python 3.12.7 for the build. Railway was flagged as risky (credit exhaustion); AWS Free Tier has a limited credit window.
- **Dashboard:** GitHub Pages (static hosting). Since `config.js` is git-ignored, the Pages build won't include it; you'd need to generate it in the workflow from a GitHub secret. Remember the secret then becomes public — only host a dashboard you're comfortable being reachable by anyone with the URL.

---

## Known limitation (V1)

Imported/screenshot-parsed transactions all land on **today's date** — `api_add` doesn't yet accept a `date` parameter, so historical dates from `/history` imports aren't persisted. Fix path: add a `date` field to the `add` action in `Code.gs` and pass it through `api_add` in `bot.py`.
