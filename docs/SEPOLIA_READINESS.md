# Sepolia readiness checklist

Status on 2026-10-12: **not ready**. High findings ORC-01 (economic) and the operational parts of INT-01 remain open, and no independent reviewer has run. Nothing here authorizes a deployment.

| # | Item | State |
| --- | --- | --- |
| 1 | Sepolia `LaunchFactory`, `LaunchFees`, `PoolManager` addresses from `network.json`, with `cast code` and Sourcify/explorer match to the mainnet sources in `test/imd/` | Missing (not supplied, never guessed) |
| 2 | Sepolia Chainlink ETH/USD proxy: code, `decimals() == 8`, heartbeat; WETH if a WETH pool is chosen | Missing |
| 3 | `factory.distributorCreationCodeHash()` equals the locally compiled `MerkleDistributor` creation-code hash, or an `eth_call` simulation of `launch()` yields the distributor address | Not run (needs item 1) |
| 4 | Router, `MerkleClaimEvidence`, oracle deployed with predicted token/distributor; `configureHook(predictedHook)` executed by the setup authority | Not run (needs a funded deployer; out of scope) |
| 5 | Manifest: token args `[]`, hook args `[$poolManager, $token, $factory, $owner, router, adapter, oracle, 60]`, permissions = the eight flags of `0x3fc0`, fee 12500, spacing 60, token-only opening range | Prepared in `DEPLOYMENT.md`; manifest is written by the launch task, not here |
| 6 | `$owner == economics.remainderTo`; one leaf per account per round in the contributor tree | Requester/IMD confirmation pending |
| 7 | Fork test at a recorded Sepolia block running `launch()` through the real factory from the real deployer (`vm.prank`) | Not run: no Sepolia RPC/addresses supplied. Local equivalent: all tests under `test/` run the verified factory logic |
| 8 | Post-launch read-only gate `CheckReleaseConfig.run(hook, 11155111, managerCodeHash, feedCodeHash)` | Not run |
| 9 | ORC-01 independent economic review, including the quote-depth floor relative to the actual opening FDV | Pending |
| 10 | Independent adversarial review of the full tree and of `test/imd/` provenance | Pending |

Checks executed in this job (Foundry 1.8.3, solc 0.8.26, offline-reproducible):

```text
python3 scripts/check_dependencies.py   -> Verified 407 vendored files (230 exact, 159 token-identical, 18 forge-fmt reproduced)
forge build                              -> Compiler run successful
forge test                               -> 118 passed, 0 failed, 0 skipped (14 suites)
forge fmt --check src test script        -> clean
forge lint src --severity high --deny warnings ; forge lint src --severity med
python3 scripts/verify_artifacts.py      -> all six production artifacts within EIP-170/3860, no link references
python3 scripts/export_abis.py           -> 12 ABIs
```

Unavailable: Sepolia fork integration, Slither/Mythril, independent review.
