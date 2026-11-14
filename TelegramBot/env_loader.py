"""Load the project-root .env into os.environ (no third-party dependency).

Import this before anything that reads os.environ. Variables already set in
the real environment (e.g. on a hosting platform) are NOT overridden.
"""
import os
from pathlib import Path

ROOT_ENV = Path(__file__).resolve().parent.parent / ".env"


def load_env(path: Path = ROOT_ENV) -> None:
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if key.startswith("export "):
            key = key[len("export "):].strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        os.environ.setdefault(key, value)


load_env()
