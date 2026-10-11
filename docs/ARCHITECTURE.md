# Architecture and accounting

## Atomic trade attribution

The canonical immutable PoolManager is the only callback caller. Before initialization, the hook checks the PoolManager-reported initializer equals the immutable launch factory, verifies currencies/fee/spacing/self-address, verifies token allocation and distributor provenance, and permanently binds the complete PoolId. The pool is initialized with the hook attached; adding a hook to an already plain pool is not an alternative.

For each swap the router:

1. Accepts a direct caller and fixed official pool. ERC-20 `transferFrom` always uses literal `msg.sender` as the source at entry; native input must match `msg.value`. The budget arrives at the router before unlocking PoolManager. Nonstandard fee-on-transfer/rebasing assets are unsupported.
2. Records `(caller, operationHash)` with a monotonic nonce. The hash binds chain ID, complete PoolKey, direction, signed exact-input/output amount, price limit, caller and nonce. The router's immutable hook link and the PoolKey bind the verifying contracts. There is no signature or arbitrary external execution path to replay.
3. Calls the real PoolManager. `beforeSwap` verifies the supported router, live context, nonempty operation, exact hash and nonce. Arbitrary hookData alone is never identity evidence.
4. `afterSwap` uses the **actual** signed UNLK BalanceDelta. Negative means sold; positive means bought. Sale limits are checked and the corresponding lifetime counter updated. The hook returns no fee/delta adjustment.
5. The callback settles from the router's own prefunded balances and takes outputs to itself. Native settlement explicitly clears any earlier PoolManager transient reserve selection with `sync(native)`; ERC-20 settlement synchronizes its own input currency. Exact settlement returns and balance differences are checked. The entry function enforces max input, minimum output, complete exact-output filling and exact UNLK delivery to the same caller. Any failure rolls back pool state, token movement, nonce, oracle observations and counters.

Exact-input swaps may partially execute at the supplied price limit. Only executed input consumes S; only delivered output credits E. Exact-output swaps must fill the requested output entirely or revert. The router supports up to 16 sequential official-pool swaps, settling and delivering each before the next; a later failure reverts the whole batch. It does not expose arbitrary multihop, universal-router commands, forwarded identity, signatures or ERC-1271 signature validation. Smart wallets are supported through authenticated direct execution, including native withdrawals.

Native proceeds/refunds are separate caller-owned liabilities. `withdrawNative` clears the caller's debt and total liabilities before sending ETH to literal `msg.sender`. It has no recipient argument. Recursion finds zero debt, and a failed send reverts the withdrawal without losing the credit. Other trades preserve all preexisting router balances and liabilities. Donated balances cannot be swept as trade output.

## E, S and credits

All quantities are integer token wei (18 decimals). `Math.mulDiv(E,p,10000)` uses OpenZeppelin's full-precision multiplication/division, avoiding intermediate overflow. Conversion of a negative int128 pool delta first widens to int256, avoiding negation overflow. Additions remain checked.

A buy credits net UNLK received. A sale consumes **gross UNLK debited**, including the 1.25% input fee if UNLK is input. With WETH/native input, the buy fee is in quote currency and is not extra E. There are no trader exemptions or counter resets, even at full unlock. S continues accumulating after full unlock for observability.

Payer credit is proven by `UnlkToken`'s immutable payer and constant constructor mint. Synchronization does not inspect a transferable current balance: transferring that allocation cannot move the original right. It is credited once regardless of synchronization caller.

Reward evidence is an explicitly unverified integration boundary. A reviewed immutable adapter must identify the native distributor that received `token.swarm()`, identify UNLK, and expose cumulative **actually delivered** claims per recipient. `syncRewards` subtracts the previously credited cumulative amount; decreasing evidence or a per-wallet amount above the entire 10% budget is rejected. A caller cannot supply logs, amounts, replacement proofs or a destination. Unclaimed Merkle entitlements are not E. Native claims never call the hook; evidence adapter failure therefore affects synchronization, not native eligibility/release/claiming. The local Merkle fixture tests proof binding, release time, duplicates and these failure semantics; it is not an IMD adapter.

The core trusts the reviewed immutable adapter's interpretation of native state. This cannot be established from the currently available IMD sources, so production release remains gated.

## Fees and liquidity principal

The pool key fixes `fee = 12500` (millionths). All return-delta flags are false. All liquidity callbacks permit only the immutable lock, and the lock has only a single seed action and zero-liquidity fee pokes. There are no negative liquidity calls, emergency withdrawals, NFT transfers, arbitrary calls, approvals to withdraw principal, governance setters or delegatecall paths. The hook independently rejects any nonzero removal delta even if its caller is the lock.

Seeding must place the 87% token allocation into the pool within at most 1e9 token wei (one billionth of a UNLK) of liquidity-unit rounding. That dust, any surplus quote prefunding and all unsolicited donations to the vault remain permanently locked. The supplied native launch fixture starts at the upper boundary of a token1 position, so all seed principal is UNLK and quote funding is zero. A WETH two-sided fixture also tests both currency orders; it is not proposed as a replacement for IMD's opening curve.

Fee pokes require the returned total delta to equal the accrued fee delta. PoolManager delivers those fees directly to the immutable distribution boundary; the lock never exposes arbitrary recipients. The distribution call is atomic with the fee poke. A broken distributor can block fee collection but cannot remove principal or block separate reward claims.

The native PoolManager governance can set protocol fees independently of this hook. Any nonzero protocol fee causes official swaps to fail closed, preventing a silently different total fee. Ordinary ERC-20 transfers remain unaffected. The release reviewer must establish that this condition is operationally compatible with the selected manager and official IMD fees; our hook cannot revoke upstream governance rights.

## Oracle and permanent tiers

The oracle records actual PoolManager ticks before and after each swap/liquidity operation and can also be checkpointed by anyone. It stores one observation per timestamp. A same-timestamp replacement adds zero price-time weight. Every observation includes tick cumulative and cumulative seconds with invalid liquidity. Binary search interpolates the precise 30-minute window start; storage grows with observations, but lookup cost is logarithmic.

Prices are geometric TWAPs (`exp(mean(log price))`) implemented by time-weighted ticks. The average is normalized to ETH per UNLK **before** rounding toward negative infinity, so neither currency ordering rounds the price optimistically. The resulting tick is converted with vendored TickMath and full-precision math. Fixed supply × UNLK/ETH TWAP × fresh ETH/USD gives USD FDV with 18 decimals.

Fixed rules:

| Rule | Value |
| --- | --- |
| TWAP window and minimum warm-up | 30 minutes |
| Maximum checkpoint age for a direct oracle read | 5 minutes |
| Minimum active liquidity | Immutable constructor value; nonzero, chain/position reviewed |
| Minimum actual quote principal in the sole locked range | 10 ETH/WETH, excluding collected/accrued fees and virtual reserves |
| Chainlink maximum age | Immutable constructor value between 60 seconds and one day; select using verified feed heartbeat |
| Chainlink checks | Positive answer; nonzero round/start/update; start ≤ update ≤ now; completed round; decimals ≤ 18; fresh |
| ETH/USD sanity ceiling | $1,000,000 per ETH, fixed |
| Confirmation after a qualifying TWAP | 60 minutes of qualifying samples, gaps ≤ 5 minutes |

A token-only opening with no quote principal cannot unlock on an arbitrary initial spot price or a tiny first trade. A full valid 30-minute liquidity window is required after reaching the floor. Any invalid second in that window invalidates a new-tier read. Trade authentication and settlement remain active even when feed reads fail.

Confirmation is **sampled**, not a mathematical proof that external USD markets stayed continuously above a threshold. Every successful swap and public milestone request samples the TWAP. A lower observed tier clears the relevant unfinished confirmations; invalid data clears all unfinished confirmations; a gap over five minutes restarts them. Reached tiers are permanent. There is no same-block shortcut to elapsed confirmation time.

An attacker willing to fund a sufficiently large price distortion through the entire time window and confirmation can cause a tier increase. The tests demonstrate that limitation, not immunity to sustained manipulation. The 10 ETH floor is a minimum, not a proof of manipulation cost for a $5M irreversible decision. Economic calibration and separate adversarial review are release gates. No price oracle is called for native reward claims.
