"""Download the on-device OCR model files into pwa/models/ (git-ignored).

The app hosts these itself so scanning needs no third-party server at run
time and keeps working offline. Files are the PP-OCRv6 "tiny" models
(Apache-2.0, from PaddleOCR) converted for onnxruntime by the
ppu-paddle-ocr project.

Usage (from the project root):
    python scripts/fetch_ocr_models.py           # skips files already present
    python scripts/fetch_ocr_models.py --force   # download again
"""
import hashlib
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEST = ROOT / "pwa" / "models"
BASE = "https://huggingface.co/snowfluke/ppu-paddle-ocr-models/resolve/main"
FILES = {
    "det.ort": f"{BASE}/detection/ort/PP-OCRv6_tiny_det.ort",
    "rec.ort": f"{BASE}/recognition/ort/PP-OCRv6_tiny_rec.ort",
    "dict.txt": f"{BASE}/recognition/ppocrv6_tiny_dict.txt",
}
MAX_BYTES = 40_000_000  # refuse anything unexpectedly large


def main() -> int:
    DEST.mkdir(parents=True, exist_ok=True)
    force = "--force" in sys.argv
    for name, url in FILES.items():
        path = DEST / name
        if path.exists() and path.stat().st_size > 0 and not force:
            print(f"{name}: already here ({path.stat().st_size:,} bytes)")
            continue
        req = urllib.request.Request(url, headers={"User-Agent": "finance-tracker-setup"})
        with urllib.request.urlopen(req, timeout=120) as res:
            data = res.read(MAX_BYTES + 1)
        if not data or len(data) > MAX_BYTES:
            print(f"{name}: unexpected size, not saved")
            return 1
        path.write_bytes(data)
        print(f"{name}: {len(data):,} bytes  sha256 {hashlib.sha256(data).hexdigest()[:16]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
