# Security review and release gates

This is the implementation author's review and local test evidence, **not an independent audit**. No separate reviewer or sub-agent performed a review in this run. Tests and tool output carry no independent authority. No claim of production compatibility or deployment readiness is made.

## Prior rejection addressed

| Reported pattern | Implemented response and evidence |
| --- | --- |
| Arbitrary ERC-20 payer in router callback | The only router `transferFrom` uses literal `msg.sender` at entry; callbacks transfer the router's own prefunded assets. No `trader`/`from` parameter controls a pull. Victim-allowance and callback spoof tests pass. |
| Arbitrary depositor in liquidity callback | Factory quote funding is pulled from literal `msg.sender` before unlocking. The callback only spends vault balances. There is no callback-selected depositor. |
| Arbitrary native recipient | Native router proceeds/refunds accrue to the authenticated caller; only that caller can withdraw to itself. Debt is zeroed before the ETH call. Reentry, cross-wallet withdrawal and rejecting-wallet retry tests pass. Liquidity fees are taken directly by the canonical manager to an immutable distribution boundary. |
| TWAP remainder classified as weak PRNG | There is no randomness. Signed mean tick is floored using `mean * WINDOW > diff`, normalized before rounding for both currency orders. Negative-mean tests pass. |
| Hand-copied FullMath/TickMath warnings | Numeric dependencies are pinned, unmodified upstream libraries in `lib/`; project arithmetic uses OpenZeppelin Math and canonical v4 TickMath/SqrtPriceMath. No home-grown inverse/XOR implementation is presented as exponentiation. |
| Ignored settlement/liquidity returns | Every settle amount is checked; unlock results are decoded/checked; liquidity total delta is compared with fee delta when collecting. Only unused components of read-only slot0 getters are intentionally omitted. |
| Callback authorization | All callback entrypoints require the canonical immutable manager. Initialization checks the actual manager-provided factory sender. Swap identity also requires the immutable router's live operation context. |

A final settlement review reproduced `NonzeroNativeValue` when a smart wallet synchronized an ERC-20 in PoolManager before a native trade in the same transaction. Both native settlement paths now explicitly call `sync(native)` before settling. The regression test failed before this change and passes after it. This was an atomic availability failure, not a loss of funds.

## Review findings and status

| ID | Severity/type | Status and consequence |
| --- | --- | --- |
| INT-01 | High, **partially resolved 2026-10-12** | Factory, distributor and fee interfaces are now the Sourcify-verified mainnet `LaunchFactory` sources (`test/imd/`); `MerkleClaimEvidence` is an immutable adapter over the verified distributor; fee split, recipients, rejection ownership and principal custody are tested against the verified `PoolFees`. Still open: Sepolia addresses, distributor creation-code-hash confirmation per chain, no official swap route exists (project router stays), no fork run. See `IMD_INTEGRATION.md`. |
| INT-02 | High, **resolved in source, open operationally** | Token constructor is arg-less and mints to the factory; hook constructor is 8 flat words matching the CLI placeholders; companions take the predicted hook and the hook verifies them at bind so a bad setup reverts the launch atomically. Open: `$owner == remainderTo` and one-leaf-per-account confirmations. |
| ORC-01 | High economic release risk, **assessed below, independent review pending** | Manipulation is possible with capital, not prevented by the TWAP; see "ORC-01 assessment". |
| GOV-01 | Medium operational risk | Canonical PoolManager protocol-fee governance is external to this project. A nonzero protocol fee stops official swaps to preserve the promised total fee. Test verifies this; confirm policy compatibility at release. |
| OPS-01 | Medium availability risk | Immutable feed/claim/fee dependencies cannot be replaced. Feed failure delays tiers; claim-evidence failure delays sync; fee-distributor failure delays fee collection. Native claims and ordinary transfers remain independent. These are disclosed immutable-design tradeoffs. |
| LOCK-01 | Low operational limitation | No recovery exists for unsolicited vault assets, surplus seed quote or bounded seed dust. All remain locked. Calculate exact launch funding and verify it before seeding. |
| TOOL-01 | Tooling limitation | Foundry 1.8.3 unfiltered low-severity/interprocedural lint exceeded memory. Compilation is separated from explicit high/medium source lint, which completes. No individual source detector is suppressed. Independent Slither/Aderyn/audit remains required. |

## ORC-01 assessment (author's quantification, not an independent review)

The $5M tier is irreversible and sets `p = 10000` for every wallet. The rule is: FDV from a 30-minute time-weighted average tick of the official pool, converted with Chainlink ETH/USD, must stay at or above $5M for a full hour of confirmations spaced at most five minutes apart, and the pool must hold at least 10 ETH of quote principal inside the recorded range. These are the costs under explicit assumptions:

- **Assumption A (launch depth).** The factory seeds 870M UNLK token-only at the opening price. At an opening FDV of F dollars, moving the TWAP to $5M requires buying enough of that position to lift the marginal price by 5,000,000 / F. For a concentrated token-only position, the quote needed to move the price from sqrt price `a` to `b` is `L * (b - a) / 2^96`; the local fixture (opening FDV about $50k at $2000/ETH) needs roughly 12 ETH to satisfy the 10 ETH floor and about 100x the opening capitalisation in buys to reach $5M (the `testSustainedManipulation` test does this with fixture funds). At realistic Sepolia openings the figure is the same order as the FDV gap itself: an attacker must actually hold the price there, so the capital at risk is the quote spent minus what can be sold back after unlock.
- **Assumption B (holding cost).** The TWAP window is 30 minutes and confirmation takes 60 minutes with at most 5-minute gaps, so the manipulated price must persist for at least 90 minutes of wall-clock time, across at least 12 confirmation transactions anyone can send. Arbitrageurs can sell into the elevated price only through `UnlkSwapRouter` and only within their own quotas, which limits counter-pressure before unlock; this makes holding **cheaper** than on an open pool and is the main reason the risk is rated high.
- **Assumption C (exit).** After the unlock the attacker's own quota is 100%, so the attacker can sell the bought tokens back into the liquidity they created. The net loss is the 1.25% fee on both legs plus the price impact absorbed by other sellers who become fully unlocked at the same moment. For an attacker who already holds a large unlocked-at-unlock position, the unlock itself is the profit motive.
- **Not mitigated by the TWAP:** same-block and flash manipulation are blocked (tested), sustained manipulation is not. A 30-minute TWAP converts a flash attack into a 90-minute funded position; it does not make manipulation impossible.
- **What would change the economics (not applied, immutable parameters):** a longer confirmation (days), a minimum quote depth that scales with the tier (e.g. a floor of hundreds of ETH for the $5M tier), or an external volume/holder condition. Changing any of these alters the committed experiment rules, so they are listed for the requester's decision, not implemented.

Verdict: ORC-01 stays **open**. No independent reviewer ran in this job; the independent economic review is still pending.

**Do not release, deploy to public networks or advertise production compatibility while any critical/high item remains unresolved.** The high findings above are open, even though the core's executed high-severity source lint reports no findings. Fixing them is a future integration/review task, not authorization to change deployed immutable rules.

## Completed author checks

- [x] Fixed ERC-20 supply minted once to the factory; 10/87/3 split performed and verified at bind; no later mint/upgrade/pause/blacklist.
- [x] Token transfers do not consult the hook or move/reset E/S.
- [x] Pool key/fee/spacing/hook binding and manager-only callbacks.
- [x] Router context, nonce, pool/chain/parameter binding; no `tx.origin`, signature bypass, arbitrary payer/recipient or foreign route.
- [x] Quota uses actual executed gross input/net output; full-precision multiplication, atomic rollback and full-unlock distinction tested.
- [x] Claim provenance identifies the exact native distributor; amounts are not caller supplied; duplicate sync is harmless; unclaimed rewards are not E.
- [x] Native claim proof/release rules remain external and claims succeed when sync fails in local fixtures.
- [x] Native debt CEI, rejecting-wallet retry, donated router balances, caller-only withdrawal and reentry tested.
- [x] Permanent position ownership inspected; no principal withdrawal/approval/NFT/arbitrary-call path; fee collection preserves position liquidity.
- [x] TWAP history, warm-up, freshness, depth, ordering, floor rounding, feed failure, flash/same-block and sustained manipulation tested.
- [x] Confirmed tiers never decrease; full unlock includes E=0 recipients and retains route/fee checks.
- [x] Unit, fuzz and stateful invariant tests use the real vendored PoolManager without network access or test environment-variable reads.
- [x] Production bytecode has no unresolved library links and stays below normal size limits.

## Independent reviewer / release checklist

- [ ] Reproduce the exact source commit and dependency hashes in a clean offline compiler environment.
- [ ] Run independent static analysis and inspect each warning against actual access/control flow; complete a separate adversarial review.
- [ ] Close INT-01 and INT-02 with authoritative IMD interfaces, original reward eligibility/proof/release semantics, fee recipient verification, native initialization/route behavior and manifest support.
- [ ] Model adversarial capital, manipulation duration, liquidity distribution, oracle sampling gaps, opening price and irreversible $5M unlock to resolve ORC-01. Sampling cannot prove continuous external market conditions.
- [ ] Verify canonical chain addresses, code/implementation hashes, upstream manager and Chainlink governance, feed heartbeat and decimals; run pinned Sepolia fork tests.
- [ ] Confirm no new admin, bypass, allocation, price, reset or proxy powers entered through adapters or deployment helpers.
- [ ] Inspect every position removal, ERC6909, NFT transfer, approval, fee collection and emergency path in the final integration.
- [ ] Recompute CREATE2 hook permissions/constructor encoding and perform authenticated setup before initializing the exact official PoolKey.
- [ ] Execute the post-deployment PoolKey, fee, claim-credit and liquidity checks in `DEPLOYMENT.md` after a separately authorized test deployment.
- [ ] Have a reviewer other than the implementation author sign the final findings and record the actual repository URL/full commit. No public release until all critical/high findings are closed.
