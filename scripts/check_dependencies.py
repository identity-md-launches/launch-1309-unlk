#!/usr/bin/env python3
"""Verify every vendored file against the submitted lock, without network access."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
lock = json.loads((ROOT / "dependencies.files.json").read_text())
actual = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
          for p in sorted((ROOT / "lib").rglob("*")) if p.is_file()}
if actual != lock:
    raise SystemExit("Vendored dependency files differ from dependencies.files.json")
print(f"Verified {len(actual)} vendored files")
