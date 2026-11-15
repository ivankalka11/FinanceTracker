"""Switch the Telegram bot over to the Supabase "telegram" function (V2 phase 4).

What it does, in order:
  1. makes sure .env has a TELEGRAM_WEBHOOK_SECRET (creates a random one if empty);
  2. stores the bot token, that secret and the price/OCR keys as Supabase secrets;
  3. deploys the "telegram" function;
  4. tells Telegram to send updates to the function (the webhook).

No secret value is printed. Run it from the project root, after
`npx supabase login` and `npx supabase link`:

    python scripts/setup_telegram_webhook.py          # switch to the Supabase bot
    python scripts/setup_telegram_webhook.py --status # show where Telegram sends updates
    python scripts/setup_telegram_webhook.py --off    # remove the webhook (the old
                                                      # Python bot can poll again)
"""
import json
import os
import secrets
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENV_FILE = ROOT / ".env"
sys.path.insert(0, str(ROOT / "TelegramBot"))
import env_loader  # noqa: E402,F401  (loads the root .env; real env vars win)


def telegram(token: str, method: str, payload: dict | None = None) -> dict:
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/{method}",
        data=json.dumps(payload or {}).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as res:
            return json.load(res)
    except urllib.error.HTTPError as e:
        return json.load(e)


def ensure_webhook_secret() -> str:
    """Return TELEGRAM_WEBHOOK_SECRET, writing a new random one into .env if missing."""
    value = os.environ.get("TELEGRAM_WEBHOOK_SECRET", "").strip()
    if value:
        return value
    value = secrets.token_urlsafe(32).replace("-", "a").replace("_", "b")  # Telegram allows A-Z a-z 0-9 _ -
    text = ENV_FILE.read_text(encoding="utf-8") if ENV_FILE.exists() else ""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if line.startswith("TELEGRAM_WEBHOOK_SECRET="):
            lines[i] = f"TELEGRAM_WEBHOOK_SECRET={value}"
            break
    else:
        lines += ["", "# --- Telegram webhook (created by setup_telegram_webhook.py) ---",
                  f"TELEGRAM_WEBHOOK_SECRET={value}"]
    ENV_FILE.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("Created TELEGRAM_WEBHOOK_SECRET in .env")
    return value


def run(label: str, command: str) -> bool:
    """Run a shell command without echoing it (it may contain secrets)."""
    print(f"> {label}")
    return subprocess.run(command, cwd=ROOT, shell=True).returncode == 0


def main() -> int:
    token = os.environ.get("BOT_TOKEN", "").strip()
    base = os.environ.get("SUPABASE_URL", "").strip().rstrip("/")
    if not token or not base:
        print("BOT_TOKEN and SUPABASE_URL must be set in .env.")
        return 1
    url = f"{base}/functions/v1/telegram"

    if "--status" in sys.argv:
        info = telegram(token, "getWebhookInfo").get("result", {})
        print("Webhook:", info.get("url") or "(none - the bot is in polling mode)")
        print("Waiting updates:", info.get("pending_update_count", 0))
        if info.get("last_error_message"):
            print("Last error:", info["last_error_message"])
        return 0

    if "--off" in sys.argv:
        res = telegram(token, "deleteWebhook")
        print("Webhook removed." if res.get("ok") else f"Telegram said: {res.get('description')}")
        return 0 if res.get("ok") else 1

    secret = ensure_webhook_secret()
    pairs = {"TELEGRAM_BOT_TOKEN": token, "TELEGRAM_WEBHOOK_SECRET": secret}
    for key in ("GEMINI_API_KEY", "GEMINI_MODEL", "EMAS_API_KEY"):
        if os.environ.get(key, "").strip():
            pairs[key] = os.environ[key].strip()
    args = " ".join(f'{k}="{v}"' for k, v in pairs.items())
    if not run(f"store {len(pairs)} secrets in Supabase ({', '.join(pairs)})", f"npx supabase secrets set {args}"):
        print("Could not store the secrets. Run `npx supabase login` and `npx supabase link` first.")
        return 1
    if not run("deploy the telegram function", "npx supabase functions deploy telegram --no-verify-jwt"):
        return 1

    res = telegram(token, "setWebhook", {
        "url": url,
        "secret_token": secret,
        "allowed_updates": ["message", "callback_query"],
        "drop_pending_updates": True,
    })
    if not res.get("ok"):
        print(f"Telegram refused the webhook: {res.get('description')}")
        return 1
    print(f"Done. Telegram now sends updates to {url}")
    print("Next: in the app open Settings -> Link Telegram and send the code to the bot.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
