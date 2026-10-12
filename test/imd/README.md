# Verified IMD LaunchFactory sources (test fixture copy)

These files are a copy of the Sourcify **full match** (creation and runtime bytecode) for the
Ethereum mainnet `LaunchFactory` at `0x12c63b581d07093f6126bc02263c58f7eadaa96f`, compiler
`0.8.26+commit.8a97fa7a`, optimizer 200 runs, EVM `cancun`, `bytecodeHash: none`, verified
2026-10-08T17:44:20Z, deployed in transaction
`0x1441cd85a00735eb68f4e4964bc07fa4b21b038e9e1d7dcab2b5efbd7f9178f3` (block 26128678) by
`0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7`. They are MIT licensed (SPDX header in each file).

They are **test fixtures**: the local tests launch UNLOCK through this exact factory logic against
the vendored Uniswap v4 `PoolManager`. They are not deployed by this project and are not
production substitutes for the mainnet or Sepolia factory instances.

One edit was made so they compile against the vendored v4-core v4.0.0
(`e50237c43811bd9b526eff40f26772152a42daba`), whose `ModifyLiquidityParams` struct lives inside
`IPoolManager` rather than in `types/PoolOperation.sol`: the import in `LaunchFactory.sol` and
`PoolFees.sol` was replaced and the struct is referenced as `IPoolManager.ModifyLiquidityParams`.
The struct's ABI encoding is identical, so the calls the factory makes are unchanged.
`scripts/verify_imd_sources.py` re-derives this from Sourcify when network access is available.
