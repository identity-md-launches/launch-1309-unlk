// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed supply. Allocation provenance is immutable; transfers create no hook rights.
contract UnlkToken is ERC20 {
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    uint256 public constant PAYER_ALLOCATION = 30_000_000 ether;
    uint256 public constant POOL_ALLOCATION = 870_000_000 ether;
    address public immutable swarm;
    address public immutable poolVault;
    address public immutable payer;

    error InvalidAllocation();

    constructor(address swarm_, address poolVault_, address payer_) ERC20("UNLK", "UNLK") {
        if (
            swarm_ == address(0) || poolVault_ == address(0) || payer_ == address(0) || swarm_ == poolVault_
                || swarm_ == payer_ || poolVault_ == payer_
        ) revert InvalidAllocation();
        swarm = swarm_;
        poolVault = poolVault_;
        payer = payer_;
        _mint(swarm_, 100_000_000 ether);
        _mint(poolVault_, POOL_ALLOCATION);
        _mint(payer_, PAYER_ALLOCATION);
    }
}
