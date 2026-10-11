# GitHub handoff

The complete source, vendored dependencies, tests, configuration, ABI export scripts and documentation are in this repository root. No `.git/`, `.github/`, `.env` or `node_modules/` contents were modified. The network's pinned `.imd/reads` inputs are not part of the deliverable.

**Publication status: pending, not published by this run.** No GitHub repository destination was provided, no GitHub CLI is installed, and neither `GITHUB_TOKEN` nor `GH_TOKEN` is present. The task also forbids touching `.git/`, so a local commit cannot be made here. The requester was asked for a destination while implementation continued. No repository URL or exact commit has been fabricated.

A Git-independent file inventory is supplied in `handoff/inventory.sha256`, with its SHA-256 digest in `handoff/inventory-digest.txt`. It identifies the delivered file contents and is **not** a Git commit. Regenerate it with `python3 scripts/source_inventory.py` after edits.

The contributor-network uploader or a later authorized publisher must commit the delivered ordinary files, publish that exact tree to the chosen GitHub repository and return its repository URL plus full 40-character commit. Source completion is not a claim that this publication step has happened.

Suggested handoff contents:

- `src/`, `test/` excluding `test/scratch/`, `script/`, `scripts/`
- `lib/`, `dependencies.lock.json`, `dependencies.files.json`
- root `foundry.toml`, `remappings.txt`, `.gitignore`, `README.md`, `LICENSE`
- `docs/`, including exported ABI JSON and validation evidence

Do not publish generated `out/`, `cache/`, `broadcast/`, `test/scratch/`, `.imd/reads`, keys, compiler binaries or local fixtures as production deployments. Tests and fixture source remain included and explicitly labelled.

Before final upload, reproduce `forge build`, `forge test`, `forge fmt --check` and dependency/artifact validation. After upload, repeat on a clean checkout of the exact published commit, with the preinstalled 0.8.26 compiler and no network dependency fetch. Record any verifier differences rather than substituting the current branch name for the exact commit.
