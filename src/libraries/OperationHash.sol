// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

library OperationHash {
    function hash(PoolKey memory key, IPoolManager.SwapParams memory params, address trader, uint256 nonce)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(block.chainid, key, params, trader, nonce));
    }
}
