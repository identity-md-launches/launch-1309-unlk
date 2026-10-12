// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IChainlinkEthUsd} from "../../src/interfaces/IIntegration.sol";

// ALL contracts in this file are LOCAL FIXTURES. They are not IMD contracts or production adapters.
contract MockWETH is ERC20 {
    constructor() ERC20("Local WETH fixture", "WETH") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockEthUsd is IChainlinkEthUsd {
    uint8 public decimals = 8;
    uint80 public roundId = 1;
    int256 public answer = 2000e8;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public answeredInRound = 1;
    bool public broken;

    constructor() {
        fresh();
    }

    function fresh() public {
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
    }

    function set(int256 value) external {
        answer = value;
        fresh();
    }

    function setBroken(bool value) external {
        broken = value;
    }

    function setDecimals(uint8 value) external {
        decimals = value;
    }

    function setRound(uint80 r, uint256 s, uint256 u, uint80 a) external {
        roundId = r;
        startedAt = s;
        updatedAt = u;
        answeredInRound = a;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!broken, "fixture feed failure");
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}

