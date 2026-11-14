"""Generate Dashboard/config.js from the project-root .env.

Browsers can't read .env, so this copies ONLY the values the dashboard needs
(APPS_SCRIPT_URL, API_SECRET) into a git-ignored config.js. Bot-only keys
(BOT_TOKEN, GEMINI_API_KEY, ...) are never written to the dashboard.

Run after editing .env:   python scripts/build_dashboard_config.py
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "TelegramBot"))
from env_loader import ROOT_ENV  # noqa: E402

DASHBOARD_KEYS = {"API_URL": "APPS_SCRIPT_URL", "SECRET": "API_SECRET"}


def read_env(path: Path) -> dict:
    values = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            v = v.strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                v = v[1:-1]
            values[k.strip()] = v
    return values


def main() -> None:
    if not ROOT_ENV.exists():
        sys.exit(f"Missing {ROOT_ENV}. Copy .env.example to .env and fill it in.")
    env = read_env(ROOT_ENV)
    missing = [src for src in DASHBOARD_KEYS.values() if not env.get(src)]
    if missing:
        sys.exit(f"Missing in .env: {', '.join(missing)}")
    config = {name: env[src] for name, src in DASHBOARD_KEYS.items()}
    out = ROOT / "Dashboard" / "config.js"
    out.write_text(
        "// GENERATED from .env by scripts/build_dashboard_config.py. Do not edit or commit.\n"
        f"window.FINANCE_CONFIG = {json.dumps(config, indent=2)};\n",
        encoding="utf-8",
    )
    print(f"Wrote {out.relative_to(ROOT)} ({', '.join(config)})")


if __name__ == "__main__":
    main()
