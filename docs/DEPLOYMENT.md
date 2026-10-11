# Configuration and future deployment

This assignment authorizes code and local simulation only. It contains no broadcast calls, signing-key reads, public-network deployments, live pool addresses or fabricated release allocations. Sepolia is the future integration target; Ethereum mainnet is a later separate release.

## Constructor and one-time settings

No contract obtains a launch owner implicitly from `msg.sender` or `tx.origin`. The setup authority is an explicit argument, remains available until the required configuration is complete, and has no replacement/reset function. Constructor dependencies are not called to require preexisting code, allowing address planning; cross-contract checks occur at authenticated setup/initialization.

| Contract | Constructor parameters | One-time operation |
| --- | --- | --- |
| Token | Actual swarm distributor, permanent pool vault, actual paying wallet | None; all 1 billion tokens mint once in the constructor |
| Router | Canonical PoolManager, explicit setup authority | Authority calls `configureHook(hook)` once; verifies reciprocal router/manager references |
| Lock | Canonical PoolManager, explicit setup authority, actual launch factory, reviewed official fee-distribution boundary | Authority calls `configureHook(hook)` once; checks reciprocal lock/manager and payer references |
| Oracle | Canonical PoolManager, verified Chainlink ETH/USD feed, UNLK, quote denomination, explicit setup authority, feed freshness limit, active-liquidity floor | Authority calls `configureHook(hook)` once. Hook then binds PoolKey once and locks the initial liquidity range |
| Hook | One tuple: manager, token, quote denomination, launch factory, supported router, liquidity lock, reviewed claim evidence, oracle, tick spacing | No admin setter; authorized factory binds the official pool through `beforeInitialize` |

`quoteToken = address(0)` means Uniswap's **native ETH currency encoding**, not a missing-address placeholder. Any nonzero quote must be the verified chain WETH with 18 decimals; arbitrary dollar/staked/rebasing tokens are invalid economic configurations. Every other required address must be real and nonzero. The constructor permits deferred code deployment, but this is not validation that an address is correct.

Fixed immutable policy includes supply/allocation, thresholds, p schedule, 1.25% LP fee, 30-minute TWAP, five-minute confirmation cadence, one-hour confirmation, minimum 10 ETH actual quote principal, permanent principal and full-unlock semantics. Feed freshness and active liquidity are constructor parameters fixed for that deployment. No later administrative oracle, route, allocation, counter, fee or rule changes are available.

## Required source of release parameters

Obtain the manager and official dependencies from the network's approved chain configuration and verified official artifacts. Obtain payer/swarm/distributor identity, release rules and opening economics from the authenticated launch record. Verify Chainlink proxy code, description/decimals/heartbeat/implementation, and WETH code/decimals if applicable, against authoritative chain-specific data. A proxy address alone does not establish immutable behavior; list upstream governance rights in the release review. Do not use local fixture addresses, a test key, a burn address or guessed reward leaves.

The read-only `CheckReleaseConfig` can be run on an explicitly supplied, pinned fork or against actual deployment state after a separately authorized deployment. It accepts hook address, expected chain ID, manager code hash and feed code hash as arguments. It checks reciprocal bindings, fees, principal position and token/credit sources. It performs no writes. A successful check does not verify native reward eligibility, fee-distributor semantics or the economics of the selected oracle floor.

No fork URL, approved chain-address table or existing deployment was supplied for this run; therefore no public-chain fork result is claimed.

## Order and hook address mining

1. Resolve the IMD manifest/deployment compatibility gaps in `IMD_INTEGRATION.md`. Verify factory ownership of initialization and the native token-only opening curve. Plan all companion addresses and explicit setup authority without live keys in this source project.
2. Deploy/configure reviewed native reward and fee boundaries according to their real APIs. Deploy the router and permanent vault with explicit authority and factory arguments. Mint the fixed-supply token to the actual distributor/vault/payer. This constructor pattern must first be reconciled with IMD's token deployment schema.
3. Deploy the oracle with the verified chain feed and fixed settings. Obtain the actual CREATE2 deployer address and finalized hook configuration. Compute `HookDeployer.initCodeHash(config)` using the finalized 0.8.26 compiler output and exact ABI encoding.
4. Mine a salt satisfying `(uint160(predictedHook) & 0x3fff) == 0x3fc0`. Enabled flags are before/after initialize, add liquidity, remove liquidity and swap. Donate and all return-delta flags are off. `scripts/mine-hook.sh DEPLOYER_ADDRESS INIT_CODE_HASH` performs an offchain calculation only; its stricter 16-bit suffix also satisfies the 14-bit condition. A salt from a different deployer, compiler build or constructor encoding is invalid.
5. Deploy the hook with that exact salt/configuration, verify the predicted address/code, and perform the router/vault/oracle authenticated one-time hook bindings. No hook can be attached after pool creation.
6. The authorized official factory initializes the complete PoolKey with this hook. Fee is 12500; quote/currency order and tick spacing must match. A foreign initializer, different key or repeat hook binding reverts atomically.
7. The factory seeds the 87% allocation through `lock.seed`. For the native opening, choose the approved token1 range with current price at its upper boundary and zero quote funding. Other exact opening layouts must be approved from official economics. Liquidity-unit rounding may leave at most 1e9 token wei permanently in the vault; materially incomplete allocation reverts. Any supplied quote surplus also remains permanently locked: calculate the required amount before calling.
8. Verify the full post-deployment checklist below, then synchronize the payer credit. Native reward credit synchronization can occur after eligible rewards are actually claimed. Do not add admin mint/upgrade/reset paths to address an integration error.

No deployment order in this document is an instruction to deploy during this assignment.

## Post-deployment verification and operations

- Recompute PoolId from both currencies, fee, spacing and hook. Check the canonical manager's pool state and the emitted hook binding. Confirm all hook address bits and zero return-delta permissions.
- Verify total supply, all three original allocation recipients and amounts, and the 87% actual pool seed/dust bound. Verify that the swarm source matches claim evidence and the paying wallet matches official fees.
- Verify each one-time configuration is sealed, reciprocal references match and no target is an unreviewed upgradeable adapter.
- Check the lock's exact position key, lower/upper ticks, salt zero, liquidity and `initialTokenUsed`. Inspect code and downstream permissions for negative-liquidity, NFT-transfer, emergency-withdraw, arbitrary-call and approval escape paths. The local lock has none.
- Check LP fee 12500 and protocol fee zero, collect sample fees through the real official distributor, and verify 80/20 payer/IMD accounting without reducing principal or creating E.
- Validate native proof/release behavior, cumulative actual claims, pending synchronization and duplicate/no-redirect cases. Native claiming must work even with a failing credit adapter.
- Compare oracle observations/derived FDV with independent calculations at a pinned block. Inspect active liquidity and actual quote principal; an untraded token-only pool cannot warm into tiers without reaching the liquidity floor.
- Run keeper or public requests at gaps no greater than five minutes during a desired confirmation. Missing a request delays new tiers; it does not remove rights. Operators can call the public request but cannot select a tier or price.
- Monitor dependency availability, claim synchronization, fee collection, protocol fee policy, immutable feed health and sustained manipulation risk. There is no admin recovery/oracle replacement/upgrade option. A broken immutable integration requires a separately reviewed new project, not hidden changes.

## Local and future read-only commands

```sh
# Local simulation only; no RPC or broadcast.
forge script script/LocalDemo.s.sol:LocalDemo --disable-code-size-limit

# Pure offchain salt calculation, with actual supplied values as two positional arguments.
bash scripts/mine-hook.sh DEPLOYER_ADDRESS INIT_CODE_HASH

# Future read-only check: invoke CheckReleaseConfig.run(hook,chainId,managerHash,feedHash)
# using a separately supplied, pinned fork and real verified values. No sample live addresses are provided.
```

`DEPLOYER_ADDRESS` and `INIT_CODE_HASH` above are CLI metavariables, not stand-in addresses or a deployment configuration.
