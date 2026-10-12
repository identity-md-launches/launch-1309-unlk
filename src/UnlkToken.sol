// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice UNLOCK (UNLK). Fixed supply, minted once to the deployer. No owner, later mint, pause, blacklist,
/// upgrade, transfer tax or transfer quota.
/// @dev IMD's verified mainnet `LaunchFactory` (0x12c63b581d07093f6126bc02263c58f7eadaa96f) deploys the
/// token by CREATE2 with no constructor arguments and requires the whole supply to be minted to itself:
/// it then sends 10% to the contributor `MerkleDistributor`, seeds at most `poolBps` (8700) into the pool
/// it keeps, and sends the remainder (3% plus seed rounding) to the launch's `remainderTo` wallet. The
/// constants below are that policy, so the hook can reason about allocations without trusting a caller.
contract UnlkToken is ERC20 {
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    uint256 public constant SWARM_ALLOCATION = 100_000_000 ether;
    uint256 public constant POOL_ALLOCATION = 870_000_000 ether;
    uint256 public constant PAYER_ALLOCATION = 30_000_000 ether;

    constructor() ERC20("UNLOCK", "UNLK") {
        _mint(msg.sender, SUPPLY);
    }
}
