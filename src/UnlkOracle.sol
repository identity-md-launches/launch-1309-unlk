// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IChainlinkEthUsd} from "./interfaces/IIntegration.sol";

/// @notice Explicit v4 tick accumulator. No assumed built-in v4 oracle, no spot-price milestones.
contract UnlkOracle {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 public constant WINDOW = 30 minutes;
    uint256 public constant MAX_CHECKPOINT_AGE = 5 minutes;
    uint256 public constant MIN_QUOTE_DEPTH = 10 ether;
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    IPoolManager public immutable poolManager;
    IChainlinkEthUsd public immutable feed;
    address public immutable token;
    address public immutable quoteToken;
    address public immutable setupAuthority;
    uint256 public immutable maxFeedAge;
    uint128 public immutable minLiquidity;
    address public hook;
    PoolId public poolId;
    bool public bound;
    bool public tokenIs0;
    uint160 public rangeLower;
    uint160 public rangeUpper;

    struct Observation {
        uint64 time;
        int24 tick;
        bool liquid;
        int256 tickCumulative;
        uint256 badSeconds;
    }
    Observation[] public observations;

    error Unauthorized();
    error InvalidConfig();
    error InvalidOracle();
    event HookConfigured(address indexed hook);
    event Bound(PoolId indexed poolId);

    constructor(
        IPoolManager manager_,
        IChainlinkEthUsd feed_,
        address token_,
        address quoteToken_,
        address setupAuthority_,
        uint256 maxFeedAge_,
        uint128 minLiquidity_
    ) {
        if (
            address(manager_) == address(0) || address(feed_) == address(0) || token_ == address(0)
                || token_ == quoteToken_ || setupAuthority_ == address(0) || maxFeedAge_ < 60
                || maxFeedAge_ > 1 days || minLiquidity_ == 0
        ) revert InvalidConfig();
        poolManager = manager_;
        feed = feed_;
        token = token_;
        quoteToken = quoteToken_;
        setupAuthority = setupAuthority_;
        maxFeedAge = maxFeedAge_;
        minLiquidity = minLiquidity_;
    }

    function configureHook(address hook_) external {
        if (msg.sender != setupAuthority || hook != address(0)) revert Unauthorized();
        if (hook_ == address(0) || hook_.code.length == 0) revert InvalidConfig();
        hook = hook_;
        emit HookConfigured(hook_);
    }

    function bind(PoolKey calldata key) external {
        if (msg.sender != hook || bound) revert Unauthorized();
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (
            address(key.hooks) != hook || key.fee != 12500
                || !((c0 == token && c1 == quoteToken) || (c1 == token && c0 == quoteToken))
        ) revert InvalidConfig();
        bound = true;
        tokenIs0 = c0 == token;
        poolId = key.toId();
        emit Bound(poolId);
    }

    function setLiquidityRange(int24 lower, int24 upper) external {
        if (msg.sender != hook || rangeUpper != 0) revert Unauthorized();
        if (lower >= upper) revert InvalidConfig();
        rangeLower = TickMath.getSqrtPriceAtTick(lower);
        rangeUpper = TickMath.getSqrtPriceAtTick(upper);
    }

    /// @notice Anyone may checkpoint real pool state. The hook checkpoints on both sides of state changes.
    /// @dev One observation per timestamp; replacement within a block adds ZERO price-time weight.
    function checkpoint() external {
        if (!bound) revert InvalidOracle();
        (uint160 sqrtPrice, int24 tick, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);
        uint256 depth = 0;
        if (sqrtPrice != 0 && rangeUpper != 0 && liquidity != 0) {
            uint160 clamped =
                sqrtPrice < rangeLower ? rangeLower : (sqrtPrice > rangeUpper ? rangeUpper : sqrtPrice);
            // Actual quote principal in the sole locked position, excluding fees; not virtual reserves.
            depth = tokenIs0
                ? SqrtPriceMath.getAmount1Delta(rangeLower, clamped, liquidity, false)
                : SqrtPriceMath.getAmount0Delta(clamped, rangeUpper, liquidity, false);
        }
        // Protocol fees may be set by v4 governance. Refuse milestone data if opening fee economics change.
        bool liquid = sqrtPrice != 0 && liquidity >= minLiquidity && depth >= MIN_QUOTE_DEPTH
            && protocolFee == 0 && lpFee == 12500;
        uint256 n = observations.length;
        if (n == 0) {
            observations.push(Observation(uint64(block.timestamp), tick, liquid, 0, 0));
        } else {
            Observation storage prev = observations[n - 1];
            if (prev.time == block.timestamp) {
                prev.tick = tick;
                prev.liquid = liquid;
            } else {
                (int256 cumulative, uint256 bad) = _at(prev, block.timestamp);
                observations.push(Observation(uint64(block.timestamp), tick, liquid, cumulative, bad));
            }
        }
    }

    function observationCount() external view returns (uint256) {
        return observations.length;
    }

    /// @return tick Time-weighted ETH-per-UNLK tick, rounded towards negative infinity in BOTH currency orders.
    function twapTick() public view returns (int24 tick) {
        uint256 n = observations.length;
        if (n == 0 || block.timestamp < WINDOW) revert InvalidOracle();
        Observation storage last = observations[n - 1];
        uint256 cutoff = block.timestamp - WINDOW;
        if (observations[0].time > cutoff || block.timestamp - last.time > MAX_CHECKPOINT_AGE || !last.liquid)
        {
            revert InvalidOracle();
        }
        // Find the last observation at/before the window start. O(log n), no history scan.
        uint256 lo = 0;
        uint256 hi = n;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            if (observations[mid].time <= cutoff) lo = mid;
            else hi = mid;
        }
        (int256 startCumulative, uint256 startBad) = _at(observations[lo], cutoff);
        (int256 endCumulative, uint256 endBad) = _at(last, block.timestamp);
        if (endBad != startBad) revert InvalidOracle();
        int256 diff = tokenIs0 ? endCumulative - startCumulative : startCumulative - endCumulative;
        int256 mean = diff / int256(WINDOW);
        // No modulo-based pseudo-randomness: this is signed floor division, including negative ticks.
        if (mean * int256(WINDOW) > diff) --mean;
        tick = int24(mean);
    }

    /// @notice FDV is in USD with 18 decimals. Reverts on any invalid input; callers isolate failures.
    function fdvUsd() external view returns (uint256) {
        int24 tick = twapTick();
        // twapTick is already conservatively normalized to ETH per UNLK.
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(tick);
        uint256 ethPerToken;
        if (sqrtPrice <= type(uint128).max) {
            ethPerToken = Math.mulDiv(uint256(sqrtPrice) * sqrtPrice, 1 ether, 1 << 192);
        } else {
            uint256 ratioX128 = Math.mulDiv(sqrtPrice, sqrtPrice, 1 << 64);
            ethPerToken = Math.mulDiv(ratioX128, 1 ether, 1 << 128);
        }
        uint256 ethUsd = _ethUsd();
        uint256 tokenUsd = Math.mulDiv(ethPerToken, ethUsd, 1 ether);
        return Math.mulDiv(SUPPLY, tokenUsd, 1 ether);
    }

    function _ethUsd() private view returns (uint256) {
        uint8 decimals = feed.decimals();
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();
        if (
            decimals > 18 || roundId == 0 || answer <= 0 || updatedAt == 0 || startedAt == 0
                || startedAt > updatedAt || updatedAt > block.timestamp || answeredInRound < roundId
                || block.timestamp - updatedAt > maxFeedAge
        ) revert InvalidOracle();
        // A sanity ceiling avoids nonsensical/overflowing feeds. It is fixed and cannot be changed.
        uint256 normalized = uint256(answer) * (10 ** (18 - decimals));
        if (normalized > 1_000_000 ether) revert InvalidOracle();
        return normalized;
    }

    function _at(Observation storage observation, uint256 timestamp)
        private
        view
        returns (int256 cumulative, uint256 bad)
    {
        uint256 elapsed = timestamp - observation.time;
        cumulative = observation.tickCumulative + int256(observation.tick) * int256(elapsed);
        bad = observation.badSeconds + (observation.liquid ? 0 : elapsed);
    }
}
