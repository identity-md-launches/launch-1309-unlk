# Executed validation

Run date: 2026-10-11 UTC. These are the implementation author's local results, not independent verification. No public deployment, public-chain transaction, signing key or live reward allocation was used.

Toolchain: Foundry **1.8.3**, commit `cae51ad458f6abb64852b7709eb784352429825d`; Solidity **0.8.26** pinned in `foundry.toml`, Cancun, optimizer 200, `bytecode_hash = "none"`.

## Final commands and results

| Command | Result |
| --- | --- |
| `forge clean` then `forge build` | Exit 0; **101 source files** compiled with 0.8.26; compiler successful (timing in the saved log) |
| `forge test` | **113 passed, 0 failed, 0 skipped**, 14 suites |
| `env -i PATH="$PATH" HOME="$HOME" forge test --threads 4` | Exit 0; **113 passed, 0 failed, 0 skipped**, 14 suites; no application environment supplied |
| `forge fmt --check` | Exit 0 |
| `forge lint src --severity high --deny warnings` | Exit 0; **no high-severity source findings** |
| `forge lint src --severity high med` | Exit 0; no high findings; 33 medium warnings, classified below |
| `python3 scripts/check_dependencies.py` | Exit 0; **407 vendored files** match submitted hashes |
| `python3 scripts/verify_artifacts.py` | Exit 0; six production contracts within EIP-170/EIP-3860 limits; no unresolved library links |
| `python3 scripts/export_abis.py` | Exit 0; **12 ABIs** exported from compiler output |
| `forge script script/LocalDemo.s.sol:LocalDemo --disable-code-size-limit` | Exit 0; local simulation succeeded; no broadcast/RPC; gas is simulation-only, not a live deployment estimate |

The minimal-environment test command preserves only executable and compiler-home discovery, not application configuration. No project test uses `vm.env*`, `vm.setEnv`, FFI or filesystem access. Test isolation also works with four parallel test threads. Public-network fork tests were not included in the local passing count.

Saved evidence: [build](validation/build.txt), [tests](validation/tests.txt), [source lint](validation/lint-high-medium.txt), [production sizes](validation/contract-sizes.json). Empty [high lint output](validation/lint-high.txt) means no diagnostics in that completed check.

## Test coverage

| Area | Exercised cases |
| --- | --- |
| Launch | Fixed supply/allocations/name/decimals; valid CREATE2 flags; unbound factory authentication; wrong fee/spacing/key; one-time setup and seed; unconfigured calls; non-manager callback rejection |
| Execution | Real PoolManager; both ERC-20 currency orders and native ETH; exact input/output; input partial fills; rejected partial exact-output; deadlines/slippage; sequential batches; later-step atomic rollback |
| Quotas | Exact cap and cap+1; actual executed deltas; gross input including fee; uint256-max multiplication boundary; zero-E recipients; transfers/chains; independent wallets; rollback of nonce, price, observations, E/S and balances |
| Authentication | Victim allowance protection; foreign/direct router attacks; arbitrary hookData; callback replay without live context; rejected arbitrary multihop payload; direct smart wallet attribution instead of owner/tx.origin |
| Credits | Payer once; pending credits; unclaimed rewards excluded; native Merkle proof/recipient/release validation; duplicate claims/sync; permissionless rightful sync; claim/sync/sale; evidence failure without native claim failure |
| Fees/liquidity | 1.25% pool fee and zero hook fee; 80/20 local distribution and fee rounding; gross sale accounting; no recipient credit; fee collection leaves principal liquidity unchanged; removal blocked; unauthorized additions; donations create no E |
| Native settlement | Reset of stale PoolManager reserve selection in a smart-wallet transaction; token-only zero-ETH opening; input value mismatch; actual buys/sells; refunds/proceeds ownership; batches; no cross-wallet withdrawal; checks-effects-interactions against recursion; rejecting wallet can trade and retry withdrawal |
| Oracle | Exact warm-up boundary; 30-minute geometric TWAP; conservative negative tick rounding in both orders; latest-observation/feed freshness; malformed/negative/future/incomplete rounds; sanity ceiling; thin actual quote reserve; same-block and atomic flash-loan manipulation; sustained manipulation timing; confirmation gaps and invalidity resets |
| Unlock | Every threshold boundary and percentage; falling-price permanence; invalid-feed persistence; E=0 seller after unlock; p=10000 without bypass flag still enforces E/S; protocol fee changes cannot silently alter total fees |
| Tooling | Local simulation tested as a function through an unrelated caller; refusal of public chain IDs; read-only release checker success/wrong chain/wrong hash; dependency and ABI generation |

Fuzz: **256 cases each** for the sale-boundary fuzz test in both currency orders. Two stateful invariant suites each run **128 sequences × 40 actions = 5,120 actions**, totaling **10,240 actions**. The first checks four accounting/liquidity invariants before full unlock. The second repeats them after full unlock, adds a permanence assertion and operates with a broken feed. These cover exact E provenance against actual native claim records, exact S execution, pre-unlock quota bounds, supply conservation/router custody, nondecreasing locked position liquidity and permanent quota bypass. Foundry 1.8.3 reports the assertions as two grouped invariant tests in the 113-test total.

Handler actions include buys, successful/rejected sales, transfers, native reward claims, synchronization and time progression. The reward release time is reached before constructing each handler, making successful claims reachable from its first action. Caught expected swap/proof failures are deliberate scenario outcomes; handler-level reverts are zero in the recorded run.

## Static findings and tool limitation

The completed high/medium source check reported:

- 24 `unsafe-typecast` warnings: guarded signed deltas become unsigned amounts; timestamps are stored in 64 bits; a bounded weighted tick is stored in int24; constants and positive feed answers are cast for full-precision math. Delta guards and canonical tick bounds constrain the conversions. Timestamp truncation would require exceeding a uint64 Unix timestamp. Feed normalization overflow reverts the oracle read and is caught for tier updates.
- 5 `reentrancy-no-eth` warnings: PoolManager/fee-distribution calls while the OpenZeppelin nonReentrant modifier still holds its status, and immutable oracle checkpointing before a possible p update. The guarded public entries and authenticated callback state machine prevent recursive settlement. The oracle only reads canonical pool state; feed/evidence reads are static calls. Native payouts use a separate debt-before-call withdrawal and produced no high finding.
- 1 `divide-before-multiply` warning: deliberate signed floor correction (`mean * WINDOW > diff`), not lossy financial multiplication. Both-order negative tick tests exercise it.
- 3 `incorrect-strict-equality` warnings: intentional before/after balance-difference checks rejecting nonstandard tokens or mismatched delivery. Preexisting donations form part of the baseline, so they cannot make a valid operation depend on an absolute zero balance.

No per-line detector suppressions or source finding exclusions were added. These classifications are author judgments and still require independent review.

An earlier `forge build` completed compilation but its **automatic unfiltered lint** grew to approximately 8 GB RSS and was killed. A subsequent unfiltered source lint was interrupted after the same resource problem. High/medium checks complete promptly; the unfiltered low-severity/interprocedural pass does not complete in this tool version on this callback/deployment graph. `lint_on_build = false` separates deterministic compilation from the explicit source checks in `scripts/check.sh`; it does not skip source compilation or tests. The check script makes high warnings fatal, then reports medium warnings separately. All project source remains available to the network's independent analyzer.

Low-severity lint was therefore **not successfully completed**; no clean-all-severities claim is made. Slither, Mythril, Aderyn, a formal proof engine and an independent audit were not run. Do not treat this tooling limitation as evidence that low findings do not exist.

The local script can warn about transient `foundry-pp/DeployHelper*.sol` artifacts left by Foundry's test instrumentation. Those files are not submitted dependencies; the simulation still succeeds and a clean build recreates normal artifacts. The code-size override applies only to the simulation harness, not the production contracts or build configuration.

## Unavailable checks and remaining work

- **Sepolia/mainnet fork tests not run:** no approved `.imd/reads/network.json`, pinned fork block/RPC or actual reviewed IMD dependency set was supplied. The normal tests are fully offline. `CheckReleaseConfig` provides a read-only, argument-driven future fork/deployment check; its local tests do not establish live compatibility.
- **Official IMD integration tests not run:** the available official starter and worker schemas do not supply the required factory/router/distributor APIs. Local fixtures are explicitly not evidence of their production behavior.
- **No independent audit/economic review:** open high release risks in `SECURITY_REVIEW.md` prohibit public release.
- **GitHub publication pending:** no destination/authorization supplied, and `.git/` is protected by the assignment. No repository URL or commit is claimed.

The prior-sync/native-settlement regression initially reproduced `NonzeroNativeValue` and passed after adding explicit `sync(native)` to both native settlement paths.

Several intermediate negative tests initially had test-harness/compiler issues (a getter consumed a prank/revert expectation; stack depth; nested simulation prank; ephemeral script address rules). They were repaired, and the final clean build and complete suites above passed. No known failing local test is omitted from the final run.
