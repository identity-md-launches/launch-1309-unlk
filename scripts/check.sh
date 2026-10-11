#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/check_dependencies.py
forge build
forge lint src --severity high --deny warnings
forge lint src --severity med
forge test
forge fmt --check
python3 scripts/verify_artifacts.py
python3 scripts/export_abis.py
