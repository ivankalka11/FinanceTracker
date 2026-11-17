"""Upload the PWA (the pwa/ folder) to Cloudflare Pages in one step.

Reads CLOUDFLARE_PAGES_PROJECT (and optionally CLOUDFLARE_PAGES_BRANCH) from the root .env, rebuilds pwa/config.js,
then runs wrangler. Log in once first with:  npx wrangler login

Usage (from the project root):
    python scripts/deploy_pwa.py
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "TelegramBot"))
import env_loader  # noqa: E402,F401  (loads the root .env; real env vars win)


def main() -> int:
    project = os.environ.get("CLOUDFLARE_PAGES_PROJECT", "").strip()
    if not project:
        print("Set CLOUDFLARE_PAGES_PROJECT in .env first (your Cloudflare Pages project name).")
        return 1
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,56}[a-z0-9]", project):
        print("CLOUDFLARE_PAGES_PROJECT may only use lowercase letters, numbers and dashes.")
        return 1

    # Refresh pwa/config.js so the upload carries the current public values.
    built = subprocess.run([sys.executable, str(ROOT / "scripts" / "build_pwa_config.py")], cwd=ROOT)
    if built.returncode:
        return built.returncode

    # The on-device OCR models are git-ignored; fetch them if this checkout has none.
    models = subprocess.run([sys.executable, str(ROOT / "scripts" / "fetch_ocr_models.py")], cwd=ROOT)
    if models.returncode:
        return models.returncode

    # Only an upload to the project's production branch reaches the main address
    # (https://<name>.pages.dev); any other branch becomes a preview. A project that
    # wrangler created by itself uses the git branch you were on at the time, so the
    # branch is configurable: CLOUDFLARE_PAGES_BRANCH in .env (default "main").
    branch = os.environ.get("CLOUDFLARE_PAGES_BRANCH", "").strip() or "main"
    if not re.fullmatch(r"[A-Za-z0-9._/-]{1,100}", branch):
        print("CLOUDFLARE_PAGES_BRANCH has characters that are not allowed in a branch name.")
        return 1
    # For a new project, fix the production branch up front (fails harmlessly if it exists).
    subprocess.run(f"npx wrangler pages project create {project} --production-branch {branch}",
                   cwd=ROOT, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # Upload a copy whose _headers names this project's Supabase host instead of any *.supabase.co.
    host = (urlparse(os.environ.get("SUPABASE_URL", "").strip()).hostname or "").lower()
    pin = bool(re.fullmatch(r"[a-z0-9-]+\.supabase\.co", host))
    if not pin:
        print("SUPABASE_URL is missing or not a *.supabase.co address: the policy keeps allowing any Supabase project.")
    with tempfile.TemporaryDirectory() as tmp:
        site = Path(tmp) / "pwa"
        shutil.copytree(ROOT / "pwa", site)
        if pin:
            headers = site / "_headers"
            text = headers.read_text(encoding="utf-8")
            text = text.replace("https://*.supabase.co", f"https://{host}").replace("wss://*.supabase.co", f"wss://{host}")
            headers.write_text(text, encoding="utf-8", newline="\n")
        command = f'npx wrangler pages deploy "{site}" --project-name {project} --branch {branch} --commit-dirty=true'
        print(f"> {command}")
        return subprocess.run(command, cwd=ROOT, shell=True).returncode

if __name__ == "__main__":
    sys.exit(main())
