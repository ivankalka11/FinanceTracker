"""Set up the 10:00 WIB stock and gold price snapshot (function "price-snapshot").

What it does, in order:
  1. makes sure .env has a CRON_SECRET (creates a random one if empty);
  2. stores it as a Supabase function secret, with the Emas key;
  3. deploys the "price-snapshot" function (without a user login: the secret guards it);
  4. writes supabase/.temp/vault_setup.sql (git-ignored) with the two Vault secrets the
     database job reads. Paste that file into the Supabase SQL Editor and run it once.

No secret value is printed. Run it from the project root, after
`npx supabase login`, `npx supabase link`, and running the scheduled-jobs migration:

    python scripts/setup_price_cron.py
"""
import os
import secrets
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENV_FILE = ROOT / ".env"
sys.path.insert(0, str(ROOT / "TelegramBot"))
import env_loader  # noqa: E402,F401  (loads the root .env; real env vars win)


def ensure_secret() -> str:
    value = os.environ.get("CRON_SECRET", "").strip()
    if value:
        return value
    value = secrets.token_urlsafe(32)
    text = ENV_FILE.read_text(encoding="utf-8") if ENV_FILE.exists() else ""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if line.startswith("CRON_SECRET="):
            lines[i] = f"CRON_SECRET={value}"
            break
    else:
        lines += ["", "# --- Scheduled price snapshot (created by setup_price_cron.py) ---", f"CRON_SECRET={value}"]
    ENV_FILE.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return value


def run(args: list[str]) -> int:
    return subprocess.run(args, cwd=ROOT, shell=(os.name == "nt")).returncode


def main() -> int:
    url = os.environ.get("SUPABASE_URL", "").strip().rstrip("/")
    if not url:
        print("Set SUPABASE_URL in .env first.")
        return 1
    secret = ensure_secret()
    emas = os.environ.get("EMAS_API_KEY", "").strip()

    pairs = [f"CRON_SECRET={secret}"] + ([f"EMAS_API_KEY={emas}"] if emas else [])
    if run(["npx", "supabase", "secrets", "set", *pairs]):
        return 1
    if run(["npx", "supabase", "functions", "deploy", "price-snapshot", "--no-verify-jwt"]):
        return 1

    sql = ROOT / "supabase" / ".temp" / "vault_setup.sql"
    sql.parent.mkdir(parents=True, exist_ok=True)
    sql.write_text(
        "-- Run once in the Supabase SQL Editor. Safe to re-run: old values are replaced.\n"
        "delete from vault.secrets where name in ('ft_project_url', 'ft_cron_secret');\n"
        f"select vault.create_secret('{url}', 'ft_project_url');\n"
        f"select vault.create_secret('{secret}', 'ft_cron_secret');\n",
        encoding="utf-8",
    )
    print("\nDone. Last step: open supabase/.temp/vault_setup.sql, paste it into the Supabase SQL Editor and run it.")
    print("(It holds the cron secret, so do not share or commit it; the folder is git-ignored.)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
