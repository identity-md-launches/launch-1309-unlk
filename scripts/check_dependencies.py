#!/usr/bin/env python3
"""Verify every vendored file against the pinned upstream commits, without network access.

`dependencies.files.json` records the SHA-256 of each file exactly as published by the pinned
upstream commit in `dependencies.lock.json`. `dependencies.formatted.json` records, for files that
the network's post-publication `forge fmt` pass reformatted, the SHA-256 of the formatted bytes and
the SHA-256 of the upstream file's *token stream* (whitespace outside string literals removed).

A vendored file passes only if
  1. its bytes equal the pinned upstream file (exact hash), or
  2. its bytes equal the recorded formatted hash AND its token stream equals the pinned upstream
     token stream. Whitespace inside string literals is preserved, so an error message, EIP-712
     type string or revert reason cannot change under this rule. Any change to a token, comment
     character or literal fails. Or,
  3. (files where `forge fmt` also wrapped a single-statement branch in braces) the entry embeds
     the pinned upstream bytes, whose SHA-256 must equal `dependencies.files.json`, and running
     `forge fmt --raw` on those bytes with this repository's `foundry.toml` must reproduce the
     vendored bytes exactly. This rule needs `forge` on PATH and no network.

Rewriting `dependencies.files.json` to accept an unknown modification is never done here.
"""
import base64
import hashlib
import json
import subprocess
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIB = ROOT / "lib"


def token_stream(data: bytes) -> bytes:
    """Remove whitespace outside string literals. Comments keep their characters, lose spacing.

    Quotes inside `//` and `/* */` comments (an apostrophe in prose) do not open a literal.
    """
    out = bytearray()
    i, n = 0, len(data)
    quote = None
    line_comment = block_comment = False
    while i < n:
        c = data[i]
        if quote is not None:
            out.append(c)
            if c == 0x5C and i + 1 < n:  # backslash escape inside a literal
                out.append(data[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if line_comment and c == 0x0A:
            line_comment = False
        elif block_comment and c == 0x2A and data[i + 1:i + 2] == b"/":
            block_comment = False
            out.extend(b"*/")
            i += 2
            continue
        elif not line_comment and not block_comment and c == 0x2F and data[i + 1:i + 2] == b"/":
            line_comment = True
        elif not line_comment and not block_comment and c == 0x2F and data[i + 1:i + 2] == b"*":
            block_comment = True
        if c in b" \t\r\n\f\v":
            i += 1
            continue
        if not line_comment and not block_comment and c in b"\"'":
            quote = c
        out.append(c)
        i += 1
    return bytes(out)


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> int:
    exact = json.loads((ROOT / "dependencies.files.json").read_text())
    formatted_path = ROOT / "dependencies.formatted.json"
    formatted = json.loads(formatted_path.read_text()) if formatted_path.exists() else {}
    actual = {str(p.relative_to(ROOT)): p.read_bytes() for p in sorted(LIB.rglob("*")) if p.is_file()}
    problems = []
    if set(actual) != set(exact):
        problems.append(f"file set differs: missing {sorted(set(exact) - set(actual))}, "
                        f"extra {sorted(set(actual) - set(exact))}")
    exact_ok = formatted_ok = refmt_ok = 0
    for rel, data in actual.items():
        if rel not in exact:
            continue
        digest = sha(data)
        if digest == exact[rel]:
            exact_ok += 1
            continue
        entry = formatted.get(rel)
        if entry is None:
            problems.append(f"{rel}: hash {digest} is neither the pinned upstream file nor a recorded formatting")
            continue
        if digest != entry["formattedSha256"]:
            problems.append(f"{rel}: hash {digest} is not the recorded formatted file {entry['formattedSha256']}")
            continue
        if sha(token_stream(data)) == entry["upstreamTokenSha256"]:
            formatted_ok += 1
            continue
        blob = entry.get("upstreamZlibBase64")
        if blob is None:
            problems.append(f"{rel}: token stream differs from the pinned upstream file")
            continue
        upstream = zlib.decompress(base64.b64decode(blob))
        if sha(upstream) != exact[rel]:
            problems.append(f"{rel}: embedded upstream bytes do not match the pinned hash")
            continue
        try:
            fmt = subprocess.run(["forge", "fmt", "--raw", "-"], input=upstream, capture_output=True,
                                 cwd=ROOT, check=True).stdout
        except (OSError, subprocess.CalledProcessError) as error:
            problems.append(f"{rel}: forge fmt reproduction unavailable ({error})")
            continue
        if fmt != data:
            problems.append(f"{rel}: forge fmt of the pinned upstream file does not reproduce the vendored file")
            continue
        refmt_ok += 1
    if problems:
        print("\n".join(problems), file=sys.stderr)
        raise SystemExit("Vendored dependency files differ from the pinned upstream commits")
    print(f"Verified {len(actual)} vendored files: {exact_ok} byte-identical to upstream, "
          f"{formatted_ok} forge-fmt formatted with an identical upstream token stream, "
          f"{refmt_ok} reproduced by forge fmt from embedded pinned upstream bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
