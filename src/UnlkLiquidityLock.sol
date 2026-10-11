// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IUnlkHookView, IFeeDistribution} from "./interfaces/IIntegration.sol";
import {UnlkToken} from "./UnlkToken.sol";

/// @notice Permanent custody of initial principal. No negative liquidity, NFT, approval, sweep or upgrade path.
/// Official IMD fee compatibility requires a reviewed immutable IFeeDistribution adapter.
contract UnlkLiquidityLock is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    IPoolManager public immutable poolManager;
    address public immutable setupAuthority;
    address public immutable launchFactory;
    IFeeDistribution public immutable feeDistribution;
    IUnlkHookView public hook;
    bool public seeded;
    uint128 public lockedLiquidity;
    int24 public tickLower;
    int24 public tickUpper;
    uint256 public initialTokenUsed;
    uint256 public initialQuoteUsed;
    uint8 private action;
    uint128 private adding;

    error Unauthorized();
    error InvalidConfig();
    error InvalidLiquidity();
    error SettlementMismatch();
    event HookConfigured(address indexed hook);
    event PrincipalLocked(uint128 liquidity, uint256 tokenUsed, uint256 quoteUsed);
    event FeesCollected(uint256 amount0, uint256 amount1);

    constructor(
        IPoolManager manager_,
        address setupAuthority_,
        address launchFactory_,
        IFeeDistribution fees_
    ) {
        if (
            address(manager_) == address(0) || setupAuthority_ == address(0) || launchFactory_ == address(0)
                || address(fees_) == address(0)
        ) revert InvalidConfig();
        poolManager = manager_;
        setupAuthority = setupAuthority_;
        launchFactory = launchFactory_;
        feeDistribution = fees_;
    }

    function configureHook(IUnlkHookView hook_) external {
        if (msg.sender != setupAuthority || address(hook) != address(0)) revert Unauthorized();
        if (
            address(hook_) == address(0) || hook_.liquidityLock() != address(this)
                || address(hook_.poolManager()) != address(poolManager)
        ) revert InvalidConfig();
        UnlkToken token = UnlkToken(hook_.token());
        if (
            token.poolVault() != address(this) || feeDistribution.payer() != token.payer()
                || feeDistribution.imd() == address(0)
        ) revert InvalidConfig();
        hook = hook_;
        emit HookConfigured(address(hook_));
    }

    /// @notice Launch factory supplies any quote funds from its OWN balance; token-only opening needs none. Minted 87% is already in this vault.
    /// @dev Range, liquidity and quote funding become permanent; unused principal is also non-withdrawable.
    function seed(uint128 liquidity, int24 lower, int24 upper, uint256 quoteFunding)
        external
        payable
        nonReentrant
    {
        if (msg.sender != launchFactory) revert Unauthorized();
        if (
            seeded || address(hook) == address(0) || !hook.bound() || liquidity == 0
                || liquidity > uint128(type(int128).max) || lower >= upper
        ) revert InvalidLiquidity();
        PoolKey memory key = hook.poolKey();
        bool is0 = Currency.unwrap(key.currency0) == hook.token();
        IERC20 quote = IERC20(Currency.unwrap(is0 ? key.currency1 : key.currency0));
        if (address(quote) == address(0)) {
            if (msg.value != quoteFunding) revert InvalidLiquidity();
        } else {
            if (msg.value != 0) revert InvalidLiquidity();
            uint256 beforeBalance = quote.balanceOf(address(this));
            if (quoteFunding != 0) quote.safeTransferFrom(msg.sender, address(this), quoteFunding);
            if (quote.balanceOf(address(this)) != beforeBalance + quoteFunding) revert SettlementMismatch();
        }
        seeded = true;
        tickLower = lower;
        tickUpper = upper;
        lockedLiquidity = liquidity;
        adding = liquidity;
        action = 1;
        bytes memory result = poolManager.unlock(abi.encode(key));
        if (action != 0) revert SettlementMismatch();
        (uint256 used0, uint256 used1) = abi.decode(result, (uint256, uint256));
        initialTokenUsed = is0 ? used0 : used1;
        initialQuoteUsed = is0 ? used1 : used0;
        // Full allocation must enter the pool, allowing at most 1e9 token-wei (one billionth token) of liquidity rounding.
        uint256 allocation = UnlkToken(hook.token()).POOL_ALLOCATION();
        if (
            initialTokenUsed > allocation || allocation - initialTokenUsed > 1e9
                || initialQuoteUsed > quoteFunding
        ) {
            revert InvalidLiquidity();
        }
        emit PrincipalLocked(liquidity, initialTokenUsed, initialQuoteUsed);
    }

    /// @notice Permissionless fee poke. Fees can leave; principal never can. No reward-credit side effects.
    function collectFees() external nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (!seeded) revert InvalidLiquidity();
        PoolKey memory key = hook.poolKey();
        action = 2;
        bytes memory result = poolManager.unlock(abi.encode(key));
        if (action != 0) revert SettlementMismatch();
        (amount0, amount1) = abi.decode(result, (uint256, uint256));
        emit FeesCollected(amount0, amount1);
        _distribute(key.currency0, amount0);
        _distribute(key.currency1, amount1);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || action == 0) revert Unauthorized();
        uint8 currentAction = action;
        action = 0;
        PoolKey memory key = abi.decode(data, (PoolKey));
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams(
            tickLower, tickUpper, currentAction == 1 ? int256(uint256(adding)) : int256(0), bytes32(0)
        );
        (BalanceDelta delta, BalanceDelta fees) = poolManager.modifyLiquidity(key, params, "");
        if (currentAction == 1) {
            if (BalanceDelta.unwrap(fees) != 0 || delta.amount0() > 0 || delta.amount1() > 0) {
                revert InvalidLiquidity();
            }
            uint256 used0 = _pay(key.currency0, delta.amount0());
            uint256 used1 = _pay(key.currency1, delta.amount1());
            return abi.encode(used0, used1);
        }
        if (
            BalanceDelta.unwrap(delta) != BalanceDelta.unwrap(fees) || delta.amount0() < 0
                || delta.amount1() < 0
        ) {
            revert InvalidLiquidity();
        }
        uint256 amount0 = uint256(uint128(delta.amount0()));
        uint256 amount1 = uint256(uint128(delta.amount1()));
        if (amount0 != 0) poolManager.take(key.currency0, address(feeDistribution), amount0);
        if (amount1 != 0) poolManager.take(key.currency1, address(feeDistribution), amount1);
        return abi.encode(amount0, amount1);
    }

    function _pay(Currency currency, int128 delta) private returns (uint256 amount) {
        amount = uint256(-int256(delta));
        if (amount == 0) return 0;
        if (Currency.unwrap(currency) == address(0)) {
            // Reset transient reserves left by any earlier sync in this transaction.
            poolManager.sync(currency);
            if (poolManager.settle{value: amount}() != amount) revert SettlementMismatch();
            return amount;
        }
        poolManager.sync(currency);
        // The callback can only spend this vault's own prefunded assets; no depositor parameter exists.
        IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
        if (poolManager.settle() != amount) revert SettlementMismatch();
    }

    function _distribute(Currency currency, uint256 amount) private {
        if (amount == 0) return;
        feeDistribution.distribute(Currency.unwrap(currency), amount);
    }
}
