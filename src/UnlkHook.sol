// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UnlkToken} from "./UnlkToken.sol";
import {UnlkOracle} from "./UnlkOracle.sol";
import {
    IClaimEvidence,
    IRouteContext,
    IMerkleDistributor,
    IUnlkCompanion
} from "./interfaces/IIntegration.sol";
import {OperationHash} from "./libraries/OperationHash.sol";

/// @notice Immutable quota hook. The integration contracts are security boundaries, not admin privileges.
/// @dev Deployed by IMD's `LaunchFactory` through CREATE2 in the launch transaction, with the flat constructor
/// words the manifest's `hook.constructorArgs` lists: `$poolManager`, `$token`, `$factory`, `$owner`, then the
/// pre-deployed router, claim adapter and oracle, then the tick spacing. The factory keeps the seeded liquidity,
/// so it is the only liquidity sender this hook accepts, and it can never remove principal (zero deltas only).
contract UnlkHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint24 public constant FEE = 12500;
    uint160 public constant FLAGS = 0x3fc0;
    uint256 public constant CONFIRMATION = 1 hours;
    uint256 public constant MAX_CONFIRMATION_GAP = 5 minutes;
    IPoolManager public immutable poolManager;
    UnlkToken public immutable token;
    address public immutable launchFactory;
    /// @notice The launch owner: the wallet the factory's `remainderTo` pays the 3% allocation to.
    address public immutable payer;
    address public immutable router;
    IClaimEvidence public immutable rewards;
    UnlkOracle public immutable oracle;
    int24 public immutable tickSpacing;

    /// @notice Paired currency, fixed when the factory binds the pool (address(0) is native ETH).
    address public quoteToken;
    /// @notice The contributor distributor the factory created for this launch, fixed at bind.
    address public swarm;
    PoolKey private _key;
    PoolId public poolId;
    bool public bound;
    mapping(address => uint256) public eligible;
    mapping(address => uint256) public sold;
    mapping(address => uint256) public claimedCredit;
    bool public payerCredited;
    uint16 public p = 2500;
    bool public fullyUnlocked;
    uint8 public tier;
    uint64[6] public qualifyingSince;
    uint64 public lastConfirmation;
    bytes32 private pendingOperation;
    address private pendingTrader;

    /// @dev Off-chain grouping of the flat constructor words; `HookDeployer` encodes it in constructor order.
    struct Config {
        IPoolManager manager;
        UnlkToken token;
        address launchFactory;
        address payer;
        address router;
        IClaimEvidence rewards;
        UnlkOracle oracle;
        int24 tickSpacing;
    }

    error Unauthorized();
    error InvalidConfig();
    error InvalidPool();
    error InvalidRoute();
    error QuotaExceeded();
    error PrincipalLocked();
    error InvalidEvidence();
    event PoolBound(PoolId indexed id);
    event Credit(address indexed recipient, uint256 amount, uint8 kind);
    event Sale(address indexed trader, uint256 amount);
    event Milestone(uint8 tier, uint16 p, bool fullyUnlocked, uint256 fdvUsd);

    /// @dev No external call and no code requirement: the launch checks run this constructor on an empty chain,
    /// and the factory deploys the token immediately before the hook in the same transaction.
    constructor(
        IPoolManager manager_,
        UnlkToken token_,
        address launchFactory_,
        address payer_,
        address router_,
        IClaimEvidence rewards_,
        UnlkOracle oracle_,
        int24 tickSpacing_
    ) {
        if (
            address(manager_) == address(0) || address(token_) == address(0) || launchFactory_ == address(0)
                || payer_ == address(0) || router_ == address(0) || address(rewards_) == address(0)
                || address(oracle_) == address(0) || tickSpacing_ <= 0 || tickSpacing_ > 32767
                || payer_ == launchFactory_
        ) revert InvalidConfig();
        poolManager = manager_;
        token = token_;
        launchFactory = launchFactory_;
        payer = payer_;
        router = router_;
        rewards = rewards_;
        oracle = oracle_;
        tickSpacing = tickSpacing_;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    modifier onlyManager() {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory h) {
        h.beforeInitialize = true;
        h.afterInitialize = true;
        h.beforeAddLiquidity = true;
        h.afterAddLiquidity = true;
        h.beforeRemoveLiquidity = true;
        h.afterRemoveLiquidity = true;
        h.beforeSwap = true;
        h.afterSwap = true;
    }

    function poolKey() external view returns (PoolKey memory) {
        return _key;
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        onlyManager
        returns (bytes4)
    {
        if (sender != launchFactory) revert Unauthorized();
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (
            bound || address(key.hooks) != address(this) || key.fee != FEE || key.tickSpacing != tickSpacing
                || !(c0 == address(token) || c1 == address(token))
        ) revert InvalidPool();
        address quote = c0 == address(token) ? c1 : c0;
        // Companions were configured with this predicted address before the launch; verify reciprocity now.
        if (
            address(oracle.poolManager()) != address(poolManager) || oracle.token() != address(token)
                || oracle.quoteToken() != quote || oracle.hook() != address(this)
                || IUnlkCompanion(router).hook() != address(this) || rewards.token() != address(token)
        ) revert InvalidConfig();
        // The factory has already created and funded the contributor distributor for this exact token: the
        // whole supply was minted to the factory, so a distributor opened by it and holding the 10% is the one.
        address distributor = rewards.distributor();
        if (
            IMerkleDistributor(distributor).token() != address(token)
                || IMerkleDistributor(distributor).opener() != launchFactory
                || token.balanceOf(distributor) != token.SWARM_ALLOCATION()
                || token.balanceOf(launchFactory) != token.SUPPLY() - token.SWARM_ALLOCATION()
        ) revert InvalidEvidence();
        quoteToken = quote;
        swarm = distributor;
        bound = true;
        _key = key;
        poolId = key.toId();
        oracle.bind(key);
        emit PoolBound(poolId);
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24)
        external
        onlyManager
        returns (bytes4)
    {
        _checkPool(key);
        oracle.checkpoint();
        return IHooks.afterInitialize.selector;
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata data
    ) external onlyManager returns (bytes4, BeforeSwapDelta, uint24) {
        _checkPool(key);
        if (sender != router || pendingOperation != bytes32(0) || data.length != 32) revert InvalidRoute();
        (address trader, bytes32 operation) = IRouteContext(router).context();
        uint256 nonce = abi.decode(data, (uint256));
        if (trader == address(0) || operation != OperationHash.hash(key, params, trader, nonce)) {
            revert InvalidRoute();
        }
        // A later PoolManager protocol-fee change cannot silently change the promised total trading fee.
        (,, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(poolId);
        if (protocolFee != 0 || lpFee != FEE) revert InvalidPool();
        pendingTrader = trader;
        pendingOperation = operation;
        oracle.checkpoint();
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata data
    ) external onlyManager returns (bytes4, int128) {
        _checkPool(key);
        address trader = pendingTrader;
        if (
            sender != router || trader == address(0) || data.length != 32
                || pendingOperation != OperationHash.hash(key, params, trader, abi.decode(data, (uint256)))
        ) revert InvalidRoute();
        delete pendingOperation;
        delete pendingTrader;
        int128 tokenDelta =
            Currency.unwrap(key.currency0) == address(token) ? delta.amount0() : delta.amount1();
        if (tokenDelta < 0) {
            uint256 q = uint256(-int256(tokenDelta));
            uint256 next = sold[trader] + q;
            if (!fullyUnlocked && next > Math.mulDiv(eligible[trader], p, 10000)) revert QuotaExceeded();
            sold[trader] = next;
            emit Sale(trader, q);
        } else if (tokenDelta > 0) {
            _credit(trader, uint256(uint128(tokenDelta)), 0);
        }
        oracle.checkpoint();
        // Feed failures and low liquidity never block swap settlement or native reward claims.
        _updateMilestone();
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external onlyManager returns (bytes4) {
        _checkPool(key);
        // All official-pool liquidity is the factory's seed; it has no removal path. No JIT fee diversion.
        if (sender != launchFactory) revert Unauthorized();
        if (oracle.rangeUpper() == 0) oracle.setLiquidityRange(params.tickLower, params.tickUpper);
        oracle.checkpoint();
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external onlyManager returns (bytes4, BalanceDelta) {
        _checkPool(key);
        oracle.checkpoint();
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external onlyManager returns (bytes4) {
        _checkPool(key);
        if (sender != launchFactory) revert Unauthorized();
        if (params.liquidityDelta != 0) revert PrincipalLocked();
        oracle.checkpoint();
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external onlyManager returns (bytes4, BalanceDelta) {
        _checkPool(key);
        oracle.checkpoint();
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    // Unrequested callbacks fail closed; neither callback has an address permission flag.
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyManager
        returns (bytes4)
    {
        revert Unauthorized();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyManager
        returns (bytes4)
    {
        revert Unauthorized();
    }

    /// @notice Public synchronization credits the fixed 3% policy allocation to the launch owner, never a caller
    /// amount. Seed rounding the factory also forwards to `remainderTo` is deliberately not credited.
    function syncPayer() external returns (uint256 amount) {
        if (!bound) revert InvalidPool();
        if (!payerCredited) {
            payerCredited = true;
            amount = token.PAYER_ALLOCATION();
            _credit(payer, amount, 1);
        }
    }

    function pendingPayerCredit() external view returns (address recipient, uint256 amount) {
        return (payer, payerCredited ? 0 : token.PAYER_ALLOCATION());
    }

    function pendingRewardCredit(address recipient) public view returns (uint256) {
        uint256 actual = rewards.claimed(recipient);
        if (actual < claimedCredit[recipient] || actual > 100_000_000 ether) revert InvalidEvidence();
        return actual - claimedCredit[recipient];
    }

    /// @notice Anyone can help a rightful recipient. Claiming remains entirely native to the distributor.
    function syncRewards(address recipient) external returns (uint256 amount) {
        if (!bound || recipient == address(0)) revert InvalidEvidence();
        amount = pendingRewardCredit(recipient);
        claimedCredit[recipient] += amount;
        if (amount != 0) _credit(recipient, amount, 2);
    }

    function remainingQuota(address trader) external view returns (uint256) {
        if (fullyUnlocked) return type(uint256).max;
        uint256 cap = Math.mulDiv(eligible[trader], p, 10000);
        return cap > sold[trader] ? cap - sold[trader] : 0;
    }

    function updateMilestone() external returns (bool) {
        if (!bound) return false;
        oracle.checkpoint();
        return _updateMilestone();
    }

    function tierForFdv(uint256 fdv) public pure returns (uint8) {
        if (fdv >= 5_000_000 ether) return 6;
        if (fdv >= 2_500_000 ether) return 5;
        if (fdv >= 1_000_000 ether) return 4;
        if (fdv >= 500_000 ether) return 3;
        if (fdv >= 250_000 ether) return 2;
        if (fdv >= 100_000 ether) return 1;
        return 0;
    }

    function _updateMilestone() private returns (bool changed) {
        if (fullyUnlocked) return false;
        uint256 fdv = 0;
        try oracle.fdvUsd() returns (uint256 value) {
            fdv = value;
        } catch {
            delete qualifyingSince;
            lastConfirmation = 0;
            return false;
        }
        uint8 observed = tierForFdv(fdv);
        if (block.timestamp - lastConfirmation > MAX_CONFIRMATION_GAP) delete qualifyingSince;
        lastConfirmation = uint64(block.timestamp);
        for (uint8 i = tier; i < 6; ++i) {
            if (observed <= i) {
                qualifyingSince[i] = 0;
            } else if (qualifyingSince[i] == 0) {
                qualifyingSince[i] = uint64(block.timestamp);
            } else if (block.timestamp - qualifyingSince[i] >= CONFIRMATION) {
                tier = i + 1;
                changed = true;
            }
        }
        if (changed) {
            uint16[7] memory percentages = [uint16(2500), 3500, 4500, 5500, 7000, 8500, 10000];
            p = percentages[tier];
            if (tier == 6) fullyUnlocked = true;
            emit Milestone(tier, p, fullyUnlocked, fdv);
        }
    }

    function _credit(address recipient, uint256 amount, uint8 kind) private {
        eligible[recipient] += amount;
        emit Credit(recipient, amount, kind);
    }

    function _checkPool(PoolKey calldata key) private view {
        if (!bound || PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert InvalidPool();
    }
}
