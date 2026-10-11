# IMD integration review — unverified production boundary

Reviewed 2026-10-11. No `.imd/reads/network.json`, official factory/router/distributor source or deployed-contract ABI was supplied. No supplied address was substituted with a guessed address. No public-chain transaction or RPC-based contract verification was performed.

## Evidence inspected

- The task's six pinned security/address reference and license files. They are input-only and are not build dependencies.
- [Identity-md/univ4hook-start-template at 8254234c70e74de59f32ad6ff524da59a59aa52a](https://github.com/Identity-md/univ4hook-start-template/tree/8254234c70e74de59f32ad6ff524da59a59aa52a), including README, Foundry configuration and repository tree. It supplies a hook scaffold and local pool harness, not verified launch factory/fee-distributor/reward-distributor ABIs. Its native-ETH launch is a token-only concentrated-liquidity position at an opening boundary. Our native fixture preserves that structural opening and uses 87% instead of the template's entire-supply demonstration. The actual release opening market cap and range must come from IMD's approved launch economics.
- [Identity-md/worker at 0bf1c6333e786bc240dcfaaaa730f33d153271b5](https://github.com/Identity-md/worker/tree/0bf1c6333e786bc240dcfaaaa730f33d153271b5), `dist/client.js` and `dist/cli.js`. These contain launch manifest/economics schemas and validation logic; they do not establish the onchain factory/router/claim/fee APIs needed here.
- [Identity-md/identitymd-skill-crafting at fa541fd81326b532d315576fa113c78b67b30ca7](https://github.com/Identity-md/identitymd-skill-crafting/tree/fa541fd81326b532d315576fa113c78b67b30ca7), repository tree. It provides contributor examples rather than protocol interfaces.
- Canonical [Uniswap v4-core v4.0.0 source at e50237c43811bd9b526eff40f26772152a42daba](https://github.com/Uniswap/v4-core/tree/e50237c43811bd9b526eff40f26772152a42daba), vendored with licenses. `IPoolManager`, `IHooks`, `StateLibrary`, actual balance deltas and actual PoolManager execution are used. The matching version places swap/liquidity parameter structs inside IPoolManager.
- [Chainlink's AggregatorV3 API reference](https://docs.chain.link/data-feeds/api-reference), for decimals and round metadata semantics. No address shown there was installed as deployment configuration.

These observations are limited to the inspected sources. They do not assert that no official interface exists elsewhere.

## Verified manifest fields, not a launch manifest

The inspected worker's `UniV4HookManifest` exposes:

| Field | Observed shape |
| --- | --- |
| `kind` | `univ4_hook` |
| `hook.contract` | Solidity contract identifier |
| `hook.constructorArgs` | Array of up to 16 strings |
| `hook.permissions` | Up to 14 hook permissions |
| `token` | `contract`, `name`, `symbol`, `decimals` |
| `pool` | `pairedCurrency`, `fee`, `tickSpacing`, `initialPrice` |
| `notes` | Text |

The separate `LaunchEconomics` schema has `poolBps`, positive `initialMarketCapWei`, and `remainderTo` required below 90% pool share. For this request the intended pool value is **8700**, the swarm share **1000**, and remainder **300** to the actual paying wallet. The inspected `UniV4LaunchPolicy` includes supply, contributor/liquidity/treasury shares, wallet caps, contributor lock/recent-contributor rules, paired-currency allowlist, fee tiers, opening-market-cap limits, gas ceiling and ownership fields. Their exact release values/rules were not supplied and are not invented.

**Known compatibility gap:** the inspected `univ4_hook` token schema lacks constructor arguments, and CLI manifest constructor extraction supplies no token arguments. `UnlkToken` deliberately takes three explicit allocation recipients. The core also uses several companion contracts and a tuple hook configuration. The verified schema does not prove that the official deployer can orchestrate these dependencies, accept that tuple, or perform authenticated one-time setup before initialization. A reviewed IMD deployment integration is required; submitting this code under an invented `launch.json` would not solve it. No `launch.json` is included.

## Exact missing interfaces and evidence

| Boundary | Required evidence before release | Present implementation |
| --- | --- | --- |
| Authorized launch factory | Actual initializer identity reported by PoolManager; constructor/deployment order; allocation receipts; CREATE2 deployer semantics; setup calls before initialize; opening tick/range calculation | Immutable `launchFactory` and authenticated one-time configuration; `MockLaunchFactory` is local only |
| Official route | Actual caller/beneficiary propagation, sourcing and delivery semantics, exact-input/output and multihop behavior, permission to use the restricted route | `UnlkSwapRouter` implements an independent direct-call route; no assertion that IMD uses it |
| Native swarm rewards | Token/distributor identity; immutable recipient and cumulative-delivery state or authentic callback; original entitlement/proof/release rules; deduplication across claims/epochs; upgrade and clawback powers | `IClaimEvidence` is a **required unverified boundary**, not an official ABI; `MockRewards` implements local Merkle/release scenarios only |
| Fee distribution | Actual official method for receiving native/ERC-20 LP fees and dividing payer/IMD amounts; wallet identities; authorization; rounding; failure behavior; withdrawal rights | `IFeeDistribution` is a **required unverified boundary**; local mock validates 80/20 conservation |
| Principal protection | Actual position ownership and all removal/transfer/approval/emergency/governance paths; compatibility with official fee collection | Independent permanent v4 position lock implemented/tested; official factory compatibility unverified |
| Chain dependencies | Canonical manager, Chainlink ETH/USD proxy and feed config, and WETH if used; chain ID, code hashes, verified implementation/proxy powers and pinned fork block | Constructor parameters and read-only checker; no production addresses provided |

A production claim adapter must expose:

```solidity
function token() external view returns (address);
function distributor() external view returns (address);
function claimed(address recipient) external view returns (uint256);
```

`claimed` must derive from immutable native onchain claim state, not logs or a new admin-written allowance. Native claims must remain callable when the adapter/hook is unavailable. If the real IMD distributor exposes only a claimed bitmap, an adapter must verify original immutable leaf contents and native claim state onchain before exposing cumulative delivered amounts; arbitrary user-supplied amounts cannot be accepted. If native proofs cannot establish actual recipient/delivery, do not ship the adapter.

A production fee adapter must expose immutable `payer()` and `imd()` and consume already-transferred fees through `distribute(address,uint256)`. Its semantics must match official distribution; it must not invent a new fee or award an extra credit. Native ETH receipt and all downstream collection rights must be inspected. The source includes **no purported production adapter** for an unavailable official interface.

## Unfinished work

Obtain verified official interfaces and chain data, implement/review minimal immutable adapters, reconcile token constructor and companion deployment with the manifest, run pinned Sepolia fork integration, establish official router support, verify fee-policy and withdrawal rights, perform an independent security/economic review, and prepare the separate release manifest. Mainnet release and public websites remain outside this assignment.
