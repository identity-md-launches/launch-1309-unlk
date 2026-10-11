// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @notice Required boundary, NOT a verified IMD ABI. An immutable adapter must read native claim state.
interface IClaimEvidence {
    function distributor() external view returns (address);
    function token() external view returns (address);
    /// @dev Must return cumulative tokens actually delivered to this exact wallet by native claims.
    /// Unclaimed allocations, logs, caller-selected amounts and transferable receipts are NOT evidence.
    function claimed(address recipient) external view returns (uint256);
}

/// @notice Required fee integration boundary, NOT a verified IMD ABI.
interface IFeeDistribution {
    function payer() external view returns (address);
    function imd() external view returns (address);
    /// @dev Consume already-transferred fees, distribute 80% payer / 20% IMD. No principal rights.
    function distribute(address currency, uint256 amount) external;
}

interface IRouteContext {
    function context() external view returns (address trader, bytes32 operation);
}

interface IUnlkHookView {
    function poolKey() external view returns (PoolKey memory);
    function bound() external view returns (bool);
    function token() external view returns (address);
    function poolManager() external view returns (IPoolManager);
    function router() external view returns (address);
    function liquidityLock() external view returns (address);
}

interface IChainlinkEthUsd {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
