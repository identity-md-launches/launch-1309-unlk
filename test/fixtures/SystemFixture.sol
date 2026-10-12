// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UnlkToken} from "../../src/UnlkToken.sol";
import {UnlkHook} from "../../src/UnlkHook.sol";
import {UnlkOracle} from "../../src/UnlkOracle.sol";
import {UnlkSwapRouter} from "../../src/UnlkSwapRouter.sol";
import {MerkleClaimEvidence} from "../../src/MerkleClaimEvidence.sol";
import {HookDeployer} from "../../src/HookDeployer.sol";
import {IUnlkHookView, IMerkleDistributor} from "../../src/interfaces/IIntegration.sol";
import {MockWETH, MockEthUsd} from "./LocalFixtures.sol";
import {LaunchFactory} from "../imd/LaunchFactory.sol";
import {LaunchFees} from "../imd/LaunchFees.sol";
import {LaunchRegistry} from "../imd/LaunchRegistry.sol";
import {MerkleDistributor} from "../imd/MerkleDistributor.sol";

/// @notice LOCAL system: the vendored v4 PoolManager plus a local instance of IMD's verified `LaunchFactory`
/// sources (test/imd). The launch transaction here is the factory's real `launch()` logic; the WETH, feed and
/// quote-depth top-up are explicitly local fixtures.
abstract contract SystemFixture is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PoolManager internal manager;
    MockWETH internal weth;
    MockEthUsd internal feed;
    LaunchFees internal launchFees;
    LaunchFactory internal factory;
    MerkleDistributor internal distributor;
    MerkleClaimEvidence internal rewards;
    UnlkToken internal token;
    UnlkSwapRouter internal router;
    UnlkOracle internal oracle;
    UnlkHook internal hook;
    HookDeployer internal deployer;
    PoolKey internal key;
    address internal alice;
    address internal bob;
    address internal payer;
    address internal imd;
    address internal predictedHook;
    bytes32 internal hookSalt;
    bytes internal hookInitCode;
    uint256 internal constant REWARD = 1_000_000 ether;
    uint64 internal constant LAUNCH_NUMBER = 1309;
    uint64 internal constant SWEEP_DELAY = 365 days;
    uint64 internal constant CONTRIBUTOR_LOCK = 1 hours;
    bool internal tokenIs0;
    int24 internal constant SPACING = 60;
    int24 internal constant LOWER = -887220;
    int24 internal constant UPPER = 887220;
    /// @dev Opening tick of the token priced in quote (normalized so token is currency0), spacing aligned.
    int24 internal constant OPENING_TICK = -174960;
    int24 internal seedLower;
    int24 internal seedUpper;
    uint128 internal seedLiquidity;

    function setUp() public virtual {
        _deploy(false);
        _launchTokenOnly(OPENING_TICK);
        _localQuoteDepth(10000 ether);
    }

    /// @dev Deploys the manager, factory and companions, predicts every launch address and configures the
    /// companions with the predicted hook. Nothing of the launch itself happens here.
    function _deploy(bool forceToken0) internal {
        vm.warp(1_800_000_000);
        alice = makeAddr("local Alice");
        bob = makeAddr("local Bob");
        payer = makeAddr("local paying wallet");
        imd = makeAddr("local IMD fee recipient and treasury");
        manager = new PoolManager(address(this));
        launchFees = new LaunchFees(address(this), imd, imd, 12500);
        factory = new LaunchFactory(manager, address(this), launchFees);
        weth = new MockWETH();
        // Ordering fixtures use code relocation for WETH only, never for the actual hook or manager.
        address quoteFixture = forceToken0 ? address(uint160(type(uint160).max - 100)) : address(0x10000);
        vm.etch(quoteFixture, address(weth).code);
        weth = MockWETH(quoteFixture);
        feed = new MockEthUsd();
        address predictedToken = factory.predictToken(LAUNCH_NUMBER, type(UnlkToken).creationCode);
        address predictedDistributor = _predictDistributor(predictedToken);
        rewards = new MerkleClaimEvidence(IMerkleDistributor(predictedDistributor), predictedToken);
        router = new UnlkSwapRouter(manager, address(this));
        oracle = new UnlkOracle(manager, feed, predictedToken, _quoteAddress(), address(this), 1 hours, 1e18);
        deployer = new HookDeployer();
        UnlkHook.Config memory config = UnlkHook.Config(
            manager,
            UnlkToken(predictedToken),
            address(factory),
            payer,
            address(router),
            rewards,
            oracle,
            SPACING
        );
        hookInitCode = deployer.initCode(config);
        _mineHookSalt();
        oracle.configureHook(predictedHook);
        router.configureHook(IUnlkHookView(predictedHook));
        tokenIs0 = predictedToken < _quoteAddress();
        key = PoolKey(
            Currency.wrap(tokenIs0 ? predictedToken : _quoteAddress()),
            Currency.wrap(tokenIs0 ? _quoteAddress() : predictedToken),
            12500,
            SPACING,
            IHooks(predictedHook)
        );
        weth.mint(address(this), 1_000_000 ether);
        weth.mint(alice, 10_000 ether);
        weth.mint(bob, 10_000 ether);
    }

    /// @dev Mines the CREATE2 salt against the factory's own prediction formula (hash computed once locally,
    /// then confirmed through `LaunchFactory.predictHook`, which is what the real deployer calls).
    function _mineHookSalt() internal {
        bytes32 codeHash = keccak256(hookInitCode);
        for (uint256 i;; ++i) {
            hookSalt = bytes32(i);
            predictedHook = address(
                uint160(
                    uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), hookSalt, codeHash)))
                )
            );
            if (uint160(predictedHook) & 0x3fff == 0x3fc0) break;
        }
        assertEq(factory.predictHook(hookInitCode, hookSalt), predictedHook, "factory prediction");
    }

    function _quoteAddress() internal view virtual returns (address) {
        return address(weth);
    }

    /// @dev The factory's real launch: token-only concentrated position with the opening price at the range
    /// boundary on the token side, exactly as `_seedRequesterPool` requires (no paired currency may be spent).
    function _launchTokenOnly(int24 normalizedTick) internal {
        int24 tick = tokenIs0 ? normalizedTick : -normalizedTick;
        if (tokenIs0) {
            (seedLower, seedUpper) = (tick, UPPER);
        } else {
            (seedLower, seedUpper) = (LOWER, tick);
        }
        uint160 sqrt = TickMath.getSqrtPriceAtTick(tick);
        seedLiquidity =
            _tokenOnlyLiquidity(UnlkToken(Currency.unwrap(tokenIs0 ? key.currency0 : key.currency1)), sqrt);
        _launch(sqrt, seedLower, seedUpper, seedLiquidity);
    }

    function _tokenOnlyLiquidity(UnlkToken, uint160 sqrt) internal view returns (uint128) {
        uint256 amount = 870_000_000 ether;
        if (tokenIs0) {
            uint160 upper = TickMath.getSqrtPriceAtTick(seedUpper);
            uint256 intermediate = Math.mulDiv(sqrt, upper, 1 << 96);
            return uint128(Math.mulDiv(amount, intermediate, upper - sqrt));
        }
        uint160 lower = TickMath.getSqrtPriceAtTick(seedLower);
        return uint128(Math.mulDiv(amount, 1 << 96, sqrt - lower));
    }

    function _launchParams(uint160 sqrt, int24 lower, int24 upper, uint128 liquidity)
        internal
        view
        returns (LaunchFactory.LaunchParams memory params)
    {
        params.launchNumber = LAUNCH_NUMBER;
        params.kind = "univ4_hook";
        params.tokenCreationCode = type(UnlkToken).creationCode;
        params.hookCreationCode = hookInitCode;
        params.hookSalt = hookSalt;
        params.hookFlags = 0x3fc0;
        params.totalSupply = 1_000_000_000 ether;
        params.poolBps = 8700;
        params.remainderTo = payer;
        params.merkleRoot = _rewardRoot();
        params.contributorLockSeconds = CONTRIBUTOR_LOCK;
        params.sweepDelaySeconds = SWEEP_DELAY;
        params.pairedCurrency = Currency.wrap(_quoteAddress());
        params.fee = 12500;
        params.tickSpacing = SPACING;
        params.sqrtPriceX96 = sqrt;
        params.tickLower = lower;
        params.tickUpper = upper;
        params.liquidity = liquidity;
        params.record = LaunchRegistry.Launch({
            kind: "univ4_hook",
            launchNumber: LAUNCH_NUMBER,
            recordedAt: 0,
            sourceCommit: bytes32(0),
            manifestHash: bytes32(0),
            attestationHash: bytes32(0),
            verifierKey: bytes32(0),
            sourceRepoUrl: "local fixture"
        });
        params.agentIds = new uint256[](0);
        params.requester = payer;
    }

    function _launch(uint160 sqrt, int24 lower, int24 upper, uint128 liquidity) internal {
        (address tokenAddress, address hookAddress, address distributorAddress) =
            factory.launch(_launchParams(sqrt, lower, upper, liquidity));
        token = UnlkToken(tokenAddress);
        hook = UnlkHook(hookAddress);
        distributor = MerkleDistributor(distributorAddress);
        assertEq(hookAddress, predictedHook, "hook prediction");
        assertEq(tokenAddress, rewards.token(), "token prediction");
        assertEq(distributorAddress, rewards.distributor(), "distributor prediction");
        _approveRouter(alice);
        _approveRouter(bob);
        _approveRouter(payer);
    }

    /// @dev One leaf `(alice, REWARD)` in the verified distributor's double-hashed leaf shape.
    function _rewardRoot() internal view returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(alice, REWARD))));
    }

    function _predictDistributor(address predictedToken) internal view returns (address) {
        bytes32 codeHash = keccak256(
            bytes.concat(
                type(MerkleDistributor).creationCode,
                abi.encode(IERC20(predictedToken), address(factory), launchFees, SWEEP_DELAY)
            )
        );
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), address(factory), bytes32(uint256(LAUNCH_NUMBER)), codeHash
                        )
                    )
                )
            )
        );
    }

    /// @dev LOCAL ONLY. Adds quote-side depth below the opening price through the factory's own settlement
    /// path (a second factory-owned position) so two-sided trading and oracle depth can be exercised. On a
    /// real chain only `launch()` and `claimFees()` reach the factory's callback, so this cannot happen there.
    function _localQuoteDepth(uint256 quoteAmount) internal {
        if (_quoteAddress() == address(0)) {
            vm.deal(address(factory), quoteAmount);
        } else {
            weth.mint(address(factory), quoteAmount);
        }
        int24 lower;
        int24 upper;
        uint128 liquidity;
        if (tokenIs0) {
            (lower, upper) = (LOWER, seedLower);
            uint160 sqrtL = TickMath.getSqrtPriceAtTick(lower);
            uint160 sqrtU = TickMath.getSqrtPriceAtTick(upper);
            liquidity = uint128(Math.mulDiv(quoteAmount, 1 << 96, sqrtU - sqrtL));
        } else {
            (lower, upper) = (seedUpper, UPPER);
            uint160 sqrtL = TickMath.getSqrtPriceAtTick(lower);
            uint160 sqrtU = TickMath.getSqrtPriceAtTick(upper);
            liquidity = uint128(Math.mulDiv(quoteAmount, Math.mulDiv(sqrtL, sqrtU, 1 << 96), sqrtU - sqrtL));
        }
        vm.prank(address(factory));
        manager.unlock(
            abi.encode(
                LaunchFactory.Seeding({
                    key: key, tickLower: lower, tickUpper: upper, liquidity: liquidity, token: address(token)
                })
            )
        );
    }

    /// @dev LOCAL warm-up: a non-actor wallet buys so quote enters the factory's token-only range (the oracle's
    /// 10 ETH quote-depth floor). Same block as the launch, so it adds no price-time weight to the TWAP.
    function _localWarmUpBuy(uint256 quoteAmount) internal {
        // Same derivation as forge-std makeAddr, kept inline so view invariants can recompute it.
        address warm = address(uint160(uint256(keccak256("local warm-up buyer"))));
        weth.mint(warm, quoteAmount);
        _approveRouter(warm);
        _buy(warm, quoteAmount);
    }

    function _approveRouter(address who) internal {
        vm.startPrank(who);
        weth.approve(address(router), type(uint256).max);
        token.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _claimReward() internal {
        distributor.claim(0, alice, REWARD, new bytes32[](0));
    }

    function _attestReward() internal returns (uint256) {
        return rewards.attest(0, alice, REWARD, new bytes32[](0));
    }

    function _request(bool buy, int256 specified, uint256 maxInput)
        internal
        view
        returns (UnlkSwapRouter.SwapRequest memory)
    {
        bool zeroForOne = buy ? !tokenIs0 : tokenIs0;
        return UnlkSwapRouter.SwapRequest(
            zeroForOne,
            specified,
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            maxInput,
            1,
            block.timestamp + 1 hours
        );
    }

    function _buy(address who, uint256 amount) internal returns (uint256 output) {
        vm.prank(who);
        (, output) = router.swap(_request(true, -int256(amount), amount));
    }

    function _sell(address who, uint256 amount) internal returns (uint256 output) {
        vm.prank(who);
        (, output) = router.swap(_request(false, -int256(amount), amount));
    }

    function _advance(uint256 seconds_) internal {
        vm.warp(block.timestamp + seconds_);
        vm.roll(block.number + 1);
        feed.fresh();
    }

    function _confirm() internal {
        _advance(30 minutes);
        hook.updateMilestone();
        for (uint256 i; i < 12; ++i) {
            _advance(5 minutes);
            hook.updateMilestone();
        }
    }

    function _factoryLiquidity(int24 lower, int24 upper) internal view returns (uint128 liquidity) {
        (liquidity,,) = IPoolManager(address(manager))
            .getPositionInfo(hook.poolId(), address(factory), lower, upper, bytes32(0));
    }
}
