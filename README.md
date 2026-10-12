# UNLOCK (UNLK): The $5M Unlock Experiment

Implemented Solidity/Foundry source and local tests. **Code only; no public-network deployment occurred.** Token name is `UNLOCK`, symbol `UNLK`. The launch flow is reconciled with the Sourcify-verified mainnet IMD `LaunchFactory` and its `MerkleDistributor`/`PoolFees` (copied as test fixtures in `test/imd/`): local tests run the factory's real `launch()` against the vendored Uniswap v4 PoolManager. Remaining gaps (Sepolia addresses, per-chain distributor hash confirmation, swap-route sign-off, fork run, independent review) are listed in [the integration review](docs/IMD_INTEGRATION.md) and the [Sepolia readiness checklist](docs/SEPOLIA_READINESS.md). The published-commit dependency failure is diagnosed and repaired in [dependency verification](docs/DEPENDENCY_VERIFICATION.md).

No live addresses, keys or future reward allocations are needed to compile or test. All sample actors, rewards, feeds, factories and fee distributors are explicitly local fixtures. The original request's security and address references were read; no addresses were copied from their tables.

## Reproduce offline

Requires Foundry and the pinned Solidity **0.8.26** compiler installed in Foundry's compiler cache. The execution environment supplies this compiler. Dependencies are ordinary files in `lib/`, with commits, licenses and file hashes in `dependencies.lock.json` and `dependencies.files.json`. There are no submodules or network-dependent build steps.

```sh
python3 scripts/check_dependencies.py
forge build
forge test
forge fmt --check
forge lint src --severity high --deny warnings
forge lint src --severity med
python3 scripts/verify_artifacts.py
python3 scripts/export_abis.py
```

`bash scripts/check.sh` runs the main checks. `bytecode_hash = "none"`, Cancun EVM, optimizer 200 runs, no FFI and no filesystem cheatcode permissions are configured in root `foundry.toml`. The compiler is pinned by version, not by a binary path. Automatic build-time lint is disabled because this Foundry version exhausted memory in unfiltered lint; the explicit source checks above remain enabled. [Validation results](docs/VALIDATION.md) record executed commands, test coverage, static warnings and unavailable checks.

A local simulation, with no keys, RPC or broadcasting:

```sh
forge script script/LocalDemo.s.sol:LocalDemo --disable-code-size-limit
```

The flag accommodates the **simulation harness**, which embeds all fixture creation code. All six production contracts separately satisfy the normal runtime and initcode limits; `verify_artifacts.py` enforces them. The simulation refuses any chain ID other than 31337. Native ETH, token-only opening is exercised separately by `NativeLaunchTest`.

## Contracts

| Contract | Responsibility |
| --- | --- |
| `UnlkToken` | Standard OpenZeppelin ERC-20 `UNLOCK`/`UNLK`; fixed 1,000,000,000 × 10^18 supply minted once to its deployer, the IMD launch factory, which splits 10% to the contributor distributor, up to 87% into the pool position it keeps, and the remainder (3% plus seed rounding) to the launch owner. No owner, later mint, pause, blacklist, upgrade, transfer tax or transfer quota. |
| `UnlkHook` | Authenticates initialization and swaps; binds one PoolKey; verifies the companions and the factory-created distributor at bind; accepts liquidity only from the factory and never a removal; records lifetime acquisition/sale counters; synchronizes verified credits; permanently advances tiers. |
| `UnlkSwapRouter` | Authenticated direct-call execution, caller-only funding, exact settlement, caller-only token delivery, batches, slippage/deadline checks and native proceeds/refund withdrawals. |
| `MerkleClaimEvidence` | Immutable adapter over the verified IMD `MerkleDistributor`: records a native claim once per round and account from the distributor's own `claimed` flag plus a proof of the `(account, amount)` leaf against the round root. |
| `UnlkOracle` | Implemented timestamp-weighted v4 tick history, liquidity validation, Chainlink ETH/USD validation and fixed-supply USD FDV. |
| `HookDeployer` | Encodes the hook's flat constructor words (manifest order) and predicts/deploys by CREATE2 for local tests. The factory does the real deployment. |

[ABIs](docs/abi/) are exported from compiler artifacts, including the unverified integration boundary interfaces. [Architecture and accounting](docs/ARCHITECTURE.md), [configuration and future deployment](docs/DEPLOYMENT.md), and [security review/checklist](docs/SECURITY_REVIEW.md) explain the invariants and responsibilities.

## Wallet rights and milestones

`E[wallet]` is cumulative actual official-pool UNLK delivered to that wallet, its verified 3% payer allocation if applicable, and native rewards **already claimed** and synchronized. `S[wallet]` is cumulative gross UNLK actually spent on official-pool sales, including the pool's token-denominated input fee. Before final unlock:

```text
Q = max(0, floor(E × p / 10000) − S)
A sale of executed amount q requires S + q ≤ floor(E × p / 10000).
```

| Verified USD FDV | p (basis points) |
| --- | ---: |
| Initial | 2500 |
| $100,000 | 3500 |
| $250,000 | 4500 |
| $500,000 | 5500 |
| $1,000,000 | 7000 |
| $2,500,000 | 8500 |
| $5,000,000 | 10000 **and a separate permanent full-unlock flag** |

**Transfers do not move rights.** A transfer-only recipient with `E = 0` cannot sell into the official pool until it acquires its own eligible rights or final unlock occurs. Transfers, donations, LP operations and fee distributions do not manufacture E or reset S. Other markets cannot be globally restricted while preserving an ordinary freely transferable ERC-20; this experiment governs its one official pool.

At full unlock every wallet can sell, including transfer-only recipients. Authentication, fees, slippage and settlement still apply. Falling prices and invalid oracle data never lower an already reached tier. `p = 10000` alone does not bypass the cumulative cap.

The hook takes **zero extra fee**. The fixed pool LP fee is 12,500 millionths = **1.25%**. All official liquidity is the launch factory's seeded position; it has no removal path and the hook refuses any non-zero removal. Fees are claimed by anyone through the factory's `claimFees(launchNumber)`: 80% to the requester (`REQUESTER_BPS`, reassignable only by the requester) and 20% to the network recipient named by `LaunchFees` at payout, with `withdraw`/`withdrawNetwork` for payments a recipient rejected. Tested against the verified sources.

## User operations

- Call the supported router directly from the wallet that funds and receives the trade. Smart wallets execute the call themselves. There are no signed intents, trusted forwarders, recipient overrides, arbitrary payer arguments or `tx.origin` checks. Foreign routers and arbitrary multihop payloads are rejected.
- Approve only the intended ERC-20 input budget. `maxInput` is prefunded exclusively from `msg.sender`; callbacks only spend the router's own balance. Native input requires exact `msg.value`. Bought UNLK is delivered immediately to the authenticated caller.
- Native sale proceeds and unused native prefunding become `nativeCredit[caller]`. Call `withdrawNative()` to receive them. Anyone else's credits are inaccessible; a rejecting smart wallet can retry. ERC-20 refunds are returned within the swap transaction.
- Read `eligible`, `sold`, `remainingQuota`, `pendingPayerCredit`, `pendingRewardCredit`, `p` and `fullyUnlocked`. Native reward claims remain on the IMD distributor (`claim(round, account, amount, proof)`), with its lock, proof and sweep rules. Claiming has no quota/price gate and no dependency on this project.
- After a native claim, anyone can call `MerkleClaimEvidence.attest(round, account, amount, proof)` with the same leaf, then `syncRewards(account)`. The credit always goes to the leaf's account; a wrong amount fails the proof, an unclaimed leaf is refused, and each round is attested once per account. Anyone can call `syncPayer()`; duplicate synchronization credits zero.
- Anyone can call `updateMilestone()`. Active confirmation requires valid requests/trades no more than five minutes apart. No user has an admin tier-setting or oracle-changing power.

## Handoff and release status

[GitHub handoff](docs/GITHUB_HANDOFF.md) states the publication status without inventing a URL or commit. The assignment forbids touching `.git/`; this run has no GitHub CLI, repository destination or GitHub authorization. Repository publication and the exact uploaded commit must be supplied by the contributor-network uploader or an authorized publishing session.

**Release is prohibited while any critical/high finding or integration gate remains open.** No independent contributor audit has been performed in this run. Missing official interfaces, public-chain verification/fork testing, manifest compatibility and oracle economic-risk review remain explicitly unfinished. Deployment, a website and a public release are separate tasks.
