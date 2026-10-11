#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 2 ]]; then
  printf 'Usage: %s DEPLOYER_ADDRESS INIT_CODE_HASH\n' "$0" >&2
  exit 2
fi
# Pure address calculation. This does not broadcast, deploy, use a key, or access an RPC.
# Matching 16 bits is stricter than the required 14-bit mask and finds a valid 0x3fc0 hook.
cast create2 --deployer "$1" --init-code-hash "$2" --ends-with 3fc0
