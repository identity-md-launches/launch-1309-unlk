// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IChainlinkEthUsd, IClaimEvidence, IFeeDistribution} from "../../src/interfaces/IIntegration.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {UnlkLiquidityLock} from "../../src/UnlkLiquidityLock.sol";

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

contract MockRewards is IClaimEvidence {
    using SafeERC20 for IERC20;
    address public token;
    address public immutable configurator;
    bytes32 public immutable root;
    uint256 public immutable releaseTime;
    mapping(address => uint256) private actualClaimed;
    mapping(uint256 => bool) public used;
    bool public brokenEvidence;

    constructor(bytes32 root_, uint256 releaseTime_) {
        root = root_;
        releaseTime = releaseTime_;
        configurator = msg.sender;
    }

    function configure(address token_) external {
        require(msg.sender == configurator && token == address(0) && token_ != address(0));
        token = token_;
    }

    function distributor() external view returns (address) {
        return address(this);
    }

    function claimed(address recipient) external view returns (uint256) {
        require(!brokenEvidence, "fixture evidence failure");
        return actualClaimed[recipient];
    }

    function setBrokenEvidence(bool value) external {
        brokenEvidence = value;
    }

    function claim(uint256 index, address recipient, uint256 amount, bytes32[] calldata proof) external {
        require(block.timestamp >= releaseTime, "unreleased");
        require(!used[index], "duplicate");
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(index, recipient, amount))));
        require(MerkleProof.verify(proof, root, leaf), "invalid proof");
        used[index] = true;
        actualClaimed[recipient] += amount;
        IERC20(token).safeTransfer(recipient, amount);
    }
}

contract MockFeeDistribution is IFeeDistribution {
    using SafeERC20 for IERC20;
    address public immutable payer;
    address public immutable imd;
    address public immutable configurator;
    address public vault;

    constructor(address payer_, address imd_) {
        payer = payer_;
        imd = imd_;
        configurator = msg.sender;
    }

    function configure(address vault_) external {
        require(msg.sender == configurator && vault == address(0));
        vault = vault_;
    }
    mapping(address => uint256) public nativeClaim;
    receive() external payable {}

    function withdrawNative() external {
        uint256 amount = nativeClaim[msg.sender];
        nativeClaim[msg.sender] = 0;
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        require(ok);
    }

    function distribute(address currency, uint256 amount) external {
        require(msg.sender == vault, "only vault");
        uint256 payerPart = amount * 4 / 5;
        if (currency == address(0)) {
            nativeClaim[payer] += payerPart;
            nativeClaim[imd] += amount - payerPart;
        } else {
            IERC20(currency).safeTransfer(payer, payerPart);
            IERC20(currency).safeTransfer(imd, amount - payerPart);
        }
    }
}

contract MockLaunchFactory {
    using SafeERC20 for IERC20;
    address public immutable authority;

    constructor() {
        authority = msg.sender;
    }

    function initialize(IPoolManager manager, PoolKey calldata key, uint160 sqrtPrice) external {
        require(msg.sender == authority);
        manager.initialize(key, sqrtPrice);
    }

    function seedNative(UnlkLiquidityLock vault, uint128 liquidity, int24 lower, int24 upper) external {
        require(msg.sender == authority);
        vault.seed(liquidity, lower, upper, 0);
    }

    function seed(
        UnlkLiquidityLock vault,
        IERC20 quote,
        uint256 funding,
        uint128 liquidity,
        int24 lower,
        int24 upper
    ) external {
        require(msg.sender == authority);
        quote.safeTransferFrom(msg.sender, address(this), funding);
        quote.forceApprove(address(vault), funding);
        vault.seed(liquidity, lower, upper, funding);
    }
}
