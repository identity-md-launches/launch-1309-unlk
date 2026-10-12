#!/usr/bin/env python3
"""Check production size/linking limits. Local fixtures/scripts are not deployable deliverables."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NAMES = ["UnlkToken", "UnlkHook", "UnlkOracle", "UnlkSwapRouter", "MerkleClaimEvidence", "HookDeployer"]
report = {}
for name in NAMES:
    artifact = json.loads((ROOT / "out" / (name + ".sol") / (name + ".json")).read_text())
    creation, runtime = artifact["bytecode"], artifact["deployedBytecode"]
    assert not creation.get("linkReferences"), f"{name}: external library linking required"
    assert not runtime.get("linkReferences"), f"{name}: external library linking required"
    sizes = {"initcodeBytes": len(creation["object"].removeprefix("0x")) // 2,
             "runtimeBytes": len(runtime["object"].removeprefix("0x")) // 2}
    assert sizes["runtimeBytes"] <= 24576, f"{name}: EIP-170 limit exceeded"
    assert sizes["initcodeBytes"] <= 49152, f"{name}: EIP-3860 limit exceeded"
    report[name] = sizes
print(json.dumps(report, indent=2))
