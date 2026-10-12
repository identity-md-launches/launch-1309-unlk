#!/usr/bin/env python3
"""Export ABIs from forge build artifacts using only Python's standard library."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONTRACTS = {
    "UnlkToken": "UnlkToken.sol",
    "UnlkHook": "UnlkHook.sol",
    "UnlkOracle": "UnlkOracle.sol",
    "UnlkSwapRouter": "UnlkSwapRouter.sol",
    "MerkleClaimEvidence": "MerkleClaimEvidence.sol",
    "HookDeployer": "HookDeployer.sol",
    "IClaimEvidence": "IIntegration.sol",
    "IMerkleDistributor": "IIntegration.sol",
    "IRouteContext": "IIntegration.sol",
    "IChainlinkEthUsd": "IIntegration.sol",
    "IPoolManager": "IPoolManager.sol",
    "IHooks": "IHooks.sol",
}
for name, source in CONTRACTS.items():
    artifact = json.loads((ROOT / "out" / source / (name + ".json")).read_text())
    target = ROOT / "docs" / "abi" / (name + ".json")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(artifact["abi"], indent=2) + "\n")
print(f"Exported {len(CONTRACTS)} ABIs")
