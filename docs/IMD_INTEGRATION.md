# IMD integration review (revised 2026-10-12)

Previous status: INT-01 and INT-02 open because no official factory, distributor, fee or manifest interface had been verified. This revision reconciles the project with **verified** sources. Mainnet release and Sepolia deployment remain outside this job.

## Authoritative sources inspected

| Source | Verification | What it establishes |
| --- | --- | --- |
| Ethereum mainnet `LaunchFactory` `0x12c63b581d07093f6126bc02263c58f7eadaa96f` | Sourcify **full match** (creation + runtime), compiler 0.8.26, optimizer 200, cancun, `bytecodeHash: none`; `cast code` on a public RPC returned code at block 26174644 | Launch flow, token/hook deployment, allocation split, fee split, principal custody. Copied verbatim to `test/imd/` (see its README for the single import adaptation) |
| `MerkleDistributor`, `PoolFees`, `LaunchFees`, `LaunchRegistry`, `HookFlags` | Same Sourcify match (compilation inputs of the factory) | Native claim state shape, fee recipients and withdrawal rights, requester reassignment |
| `Identity-md/worker` `dist/cli.js` and `dist/client.js` (main, fetched 2026-10-12) | Repository files, not on-chain | Manifest schema: `univ4_hook` token has **no constructor args**; hook `constructorArgs` are flat words with placeholders `$poolManager`, `$token`, `$owner`, `$factory`; a hook constructor input whose `internalType` ends in `IPoolManager` must be `$poolManager`; `validateHookConstructor` requires one manifest string per ABI input, so **tuple constructors are unsupported** |

No Sepolia address was obtained or guessed. The Sepolia factory, fees contract and PoolManager must come from `.imd/reads/network.json` or the chain table of the launch task; none was supplied here.

## Launch flow as implemented by the verified factory

1. `launch()` (deployer only) CREATE2-deploys the token (salt = launch number, no constructor args), then the hook (mined salt, flat constructor words). Hook flags must include an initialize flag and match the address exactly.
2. The token must have minted its **whole supply to the factory**; the factory checks balance and total supply.
3. The factory creates the `MerkleDistributor` (CREATE2, salt = launch number), transfers 10% (`SWARM_BPS`) and opens round 0 with the manifest's root and lock.
4. `initialize(key, sqrtPriceX96)` with the key the factory sorts itself; the hook's `beforeInitialize` sees `sender == factory`.
5. The factory adds a token-only position it keeps forever (it has no removal path; `claimFees` only runs zero-delta collections) and reverts if any paired currency is spent or more than `poolBps` is taken.
6. The remainder (3% plus seed rounding) goes to `remainderTo`; the registry records the launch.

## Compatibility matrix

| Requirement | Verified interface | Project state | Status |
| --- | --- | --- | --- |
| Token: no constructor args, whole supply to `msg.sender` | `LaunchFactory.launch` + CLI token args `[]` | `UnlkToken()` mints `SUPPLY` to `msg.sender`; name `UNLOCK`, symbol `UNLK` | Reconciled, tested (`LaunchTest`) |
| 10 / 87 / 3 allocation | Factory constants `SWARM_BPS = 1000`, `poolBps = 8700`, remainder to `remainderTo` | Hook verifies at bind that the distributor holds exactly 10% and the factory holds 90%; payer credit is the fixed 3% | Reconciled, tested |
| Flat hook constructor, 8 words | CLI `validateHookConstructor`, 16-word max | `(IPoolManager $poolManager, token $token, launchFactory $factory, payer $owner, router, rewards, oracle, tickSpacing)` | Reconciled; `HookDeployer.initCode` encodes exactly this |
| Hook constructor makes no external call | Launch checks on an empty chain | Only `Hooks.validateHookPermissions(this)` (pure) | Reconciled |
| CREATE2 flags `0x3fc0` | `HookFlags.matches` (exact equality) | `FLAGS = 0x3fc0`; mined against `predictHook` | Reconciled, tested |
| Companion setup before the launch tx | Hook exists only inside `launch()` | Router and oracle accept the **predicted** hook; the hook verifies `router.hook()`, `oracle.hook()`, `rewards.token()` reciprocally in `beforeInitialize`; a mismatch reverts the whole launch, deploying nothing | Reconciled, tested (`InitializationGuardTest`) |
| Liquidity custody | Factory keeps the position; `PoolFees._collect` is the only later callback | Hook accepts liquidity only from `launchFactory`, and only zero deltas on removal | Reconciled, tested |
| Fee split 80 / 20 | `LaunchFees.REQUESTER_BPS = 8000`; network share to `feeRecipient()` read at payout; `withdraw`/`withdrawNetwork` for rejected payments; `setRequester` by the requester only | No project fee contract; tests exercise claim, rejection ownership and recipient moves | Reconciled, tested (`CreditsAndFeesTest`, `NativeLaunchTest`) |
| Native claim evidence | `MerkleDistributor.claimed(round, account)` is a **bool**; amount only in the leaf | `MerkleClaimEvidence.attest(round, account, amount, proof)` requires the distributor's flag and a proof against `roundOf(round).root`; credit only to `account`, once per round | Implemented, tested; see assumption on one leaf per account |
| Native claim unrestricted | `claim` has no dependency on any adapter | Adapter is read-only; tests claim with a broken feed and without attesting | Reconciled, tested |
| Distributor address before launch | CREATE2 with `type(MerkleDistributor).creationCode ++ (token, factory, fees, sweepDelay)` | Local tests predict it exactly from the verified source; on a public chain the deployer must confirm `factory.distributorCreationCodeHash()` equals the hash of the compiled creation code (same solc 0.8.26 / 200 runs / cancun / no metadata hash) or simulate `launch()` with `eth_call` | **Open until confirmed per chain** |
| `$owner` equals `economics.remainderTo` | Both are the requester's wallet in the worker flow | Hook credits `PAYER_ALLOCATION` to `$owner`; a request naming a different owner would credit the wrong wallet | **Operational check in the readiness list** |
| Official swap route | No IMD router interface exists in the inspected sources | Trades must go through `UnlkSwapRouter` (hook rejects other senders) | **Unchanged project decision; needs product sign-off** |
| Sepolia addresses (factory, fees, PoolManager, Chainlink ETH/USD, WETH) | Not supplied | Constructor arguments / manifest fields | **Open; never guessed** |
| Fork integration | Public mainnet RPC reachable in this run, Sepolia RPC not supplied | Not executed: a mainnet `launch()` needs IMD's deployer key, and a Sepolia factory address was not provided. Local tests run the verified factory logic against the vendored PoolManager | **Unavailable, reported** |

## Exact unresolved interface requirements

1. Sepolia `LaunchFactory`, `LaunchFees`, `PoolManager`, Chainlink ETH/USD proxy and WETH addresses with code checks.
2. The deployer's `sweepDelaySeconds` and `contributorLockSeconds` for this launch (needed to predict the distributor; alternatively an `eth_call` simulation of `launch`).
3. Confirmation that IMD's tree builder emits one leaf per account per round.
4. Confirmation that the manifest's `$owner` is the same wallet as `economics.remainderTo`.
5. A statement that `UnlkSwapRouter` is the supported trading route for this launch's site/UI.
