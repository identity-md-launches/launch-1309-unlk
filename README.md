# UNLOCK (UNLK): The $5M Unlock Experiment

Implemented Solidity/Foundry source and local tests. **Code only; no public-network deployment occurred.** Token name and symbol are both `UNLK`. This is an independently implemented core with an actual Uniswap v4 PoolManager test integration. **It is not yet verified compatible with IMD's launch factory, native reward distributor, fee distributor or production router.** The exact missing boundaries and verified manifest observations are in [the integration review](docs/IMD_INTEGRATION.md).

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
| `UnlkToken` | Standard OpenZeppelin ERC-20; fixed 1,000,000,000 × 10^18 supply; constructor mints 10% to the swarm distributor, 87% to the liquidity vault and 3% to the paying wallet. No owner, later mint, pause, blacklist, upgrade, transfer tax or transfer quota. |
| `UnlkHook` | Authenticates initialization and swaps; binds one PoolKey; records lifetime acquisition/sale counters; synchronizes verified credits; permanently advances tiers. |
| `UnlkSwapRouter` | Authenticated direct-call execution, caller-only funding, exact settlement, caller-only token delivery, batches, slippage/deadline checks and native proceeds/refund withdrawals. |
| `UnlkLiquidityLock` | One-time seeding of the 87% allocation; permanent principal custody; permissionless fee collection to a fixed distribution boundary. |
| `UnlkOracle` | Implemented timestamp-weighted v4 tick history, liquidity validation, Chainlink ETH/USD validation and fixed-supply USD FDV. |
| `HookDeployer` | CREATE2 calculation and deployment primitive for future reviewed deployment. Nothing in this assignment broadcasts it. |

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

The hook takes **zero extra fee**. The fixed pool LP fee is 12,500 millionths = **1.25%**. All official liquidity is held by the permanent vault. Its fee distribution boundary must preserve the official 80/20 division of collected fees: economically 1% payer / 0.25% IMD, subject to pool/collection integer rounding. The mock demonstrates that split; official distribution compatibility remains unverified.

## User operations

- Call the supported router directly from the wallet that funds and receives the trade. Smart wallets execute the call themselves. There are no signed intents, trusted forwarders, recipient overrides, arbitrary payer arguments or `tx.origin` checks. Foreign routers and arbitrary multihop payloads are rejected.
- Approve only the intended ERC-20 input budget. `maxInput` is prefunded exclusively from `msg.sender`; callbacks only spend the router's own balance. Native input requires exact `msg.value`. Bought UNLK is delivered immediately to the authenticated caller.
- Native sale proceeds and unused native prefunding become `nativeCredit[caller]`. Call `withdrawNative()` to receive them. Anyone else's credits are inaccessible; a rejecting smart wallet can retry. ERC-20 refunds are returned within the swap transaction.
- Read `eligible`, `sold`, `remainingQuota`, `pendingPayerCredit`, `pendingRewardCredit`, `p` and `fullyUnlocked`. Native reward claims remain on the native distributor, with its eligibility, proof and release rules. Claiming has no quota/price gate and no dependency on credit synchronization.
- Anyone can call `syncPayer()` or `syncRewards(wallet)`. The wallet argument chooses whose immutable native claim state is read; the resulting credit always goes to that same rightful wallet. No amount or alternate recipient can be supplied. Duplicate synchronization credits zero.
- Anyone can call `updateMilestone()`. Active confirmation requires valid requests/trades no more than five minutes apart. No user has an admin tier-setting or oracle-changing power.

## Handoff and release status

[GitHub handoff](docs/GITHUB_HANDOFF.md) states the publication status without inventing a URL or commit. The assignment forbids touching `.git/`; this run has no GitHub CLI, repository destination or GitHub authorization. Repository publication and the exact uploaded commit must be supplied by the contributor-network uploader or an authorized publishing session.

**Release is prohibited while any critical/high finding or integration gate remains open.** No independent contributor audit has been performed in this run. Missing official interfaces, public-chain verification/fork testing, manifest compatibility and oracle economic-risk review remain explicitly unfinished. Deployment, a website and a public release are separate tasks.
