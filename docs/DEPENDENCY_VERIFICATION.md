# Dependency verification of the published commit

## Finding

On a clean clone of `7c02c96b3d6cd07c8df9ed8a7811c95ac2ca1976`, `scripts/check_dependencies.py` failed: all 407 vendored files existed but 177 SHA-256 values differed from `dependencies.files.json`.

## Cause (verified, not assumed)

1. All 407 files were fetched again from the pinned upstream commits in `dependencies.lock.json` (raw GitHub, 2026-10-12). Every one of the 407 recorded hashes equals the pristine upstream file: the lock file was correct.
2. The 177 differing files are all `.sol`, and every working-tree file equals its Git blob in the published commit: the modification happened before or at publication, not on clone.
3. Running `forge fmt` (Foundry 1.8.3) on the pristine upstream copies with this repository's `foundry.toml` reproduced the published bytes for **all 177 files, byte for byte**. The cause is the network's post-publication `forge fmt` pass: `[fmt]` in the protected `foundry.toml` has no `lib/` exclusion, so vendored sources were reformatted after the hashes were recorded.

## Repair

`lib/` and `foundry.toml` are protected and the formatting pass runs again after every delivery, so the files cannot be restored in place. Instead the check now proves the relationship offline:

- `dependencies.files.json` is **unchanged**: it still pins the pristine upstream hashes.
- `dependencies.formatted.json` records, per reformatted file, the formatted hash and the SHA-256 of the upstream *token stream* (all whitespace outside string literals removed; comments keep their characters). 159 files pass this rule, which cannot accept a changed token, literal or comment character.
- 18 files where `forge fmt` also wrapped single-statement branches in braces embed the pinned upstream bytes (zlib, base64). The check hashes them against `dependencies.files.json` and runs `forge fmt --raw` on them, requiring the output to equal the vendored file exactly.

Result on this tree: `Verified 407 vendored files: 230 byte-identical to upstream, 159 forge-fmt formatted with an identical upstream token stream, 18 reproduced by forge fmt from embedded pinned upstream bytes`.

Licenses were untouched: the LICENSE files of all four dependencies are among the 230 byte-identical files.
