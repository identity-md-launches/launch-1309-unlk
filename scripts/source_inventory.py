#!/usr/bin/env python3
"""Create a content handoff fingerprint without reading or modifying Git metadata."""
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FILES = ["README.md", "LICENSE", "foundry.toml", "remappings.txt", ".gitignore",
         "dependencies.lock.json", "dependencies.files.json"]
DIRECTORIES = ["src", "test", "script", "scripts", "lib", "docs"]
paths = [ROOT / p for p in FILES]
for directory in DIRECTORIES:
    for p in (ROOT / directory).rglob("*"):
        if p.is_file() and "scratch" not in p.relative_to(ROOT).parts and "__pycache__" not in p.parts:
            paths.append(p)
lines = []
for p in sorted(paths):
    lines.append(f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(ROOT)}\n")
content = "".join(lines).encode()
target = ROOT / "handoff"
target.mkdir(exist_ok=True)
(target / "inventory.sha256").write_bytes(content)
digest = hashlib.sha256(content).hexdigest()
(target / "inventory-digest.txt").write_text(digest + "\n")
print(f"{len(lines)} files; inventory SHA-256 {digest}")
