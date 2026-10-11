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
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UnlkToken} from "../../src/UnlkToken.sol";
import {UnlkHook} from "../../src/UnlkHook.sol";
import {UnlkOracle} from "../../src/UnlkOracle.sol";
import {UnlkSwapRouter} from "../../src/UnlkSwapRouter.sol";
import {UnlkLiquidityLock} from "../../src/UnlkLiquidityLock.sol";
import {HookDeployer} from "../../src/HookDeployer.sol";
import {IUnlkHookView} from "../../src/interfaces/IIntegration.sol";
import {MockWETH, MockEthUsd, MockRewards, MockFeeDistribution, MockLaunchFactory} from "./LocalFixtures.sol";

abstract contract SystemFixture is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    PoolManager internal manager;
    MockWETH internal weth;
    MockEthUsd internal feed;
    MockRewards internal rewards;
    MockFeeDistribution internal fees;
    MockLaunchFactory internal factory;
    UnlkToken internal token;
    UnlkSwapRouter internal router;
    UnlkLiquidityLock internal vault;
    UnlkOracle internal oracle;
    UnlkHook internal hook;
    PoolKey internal key;
    address internal alice;
    address internal bob;
    address internal payer;
    address internal imd;
    uint256 internal constant REWARD = 1_000_000 ether;
    bool internal tokenIs0;
    int24 internal constant SPACING = 60;
    int24 internal constant LOWER = -887220;
    int24 internal constant UPPER = 887220;

    function setUp() public virtual {
        _deploy(false);
        _initialize(-175000);
    }

    function _deploy(bool forceToken0) internal {
        vm.warp(1_800_000_000);
        alice = makeAddr("local Alice");
        bob = makeAddr("local Bob");
        payer = makeAddr("local paying wallet");
        imd = makeAddr("local IMD treasury");
        manager = new PoolManager(address(this));
        factory = new MockLaunchFactory();
        weth = new MockWETH();
        // Ordering fixtures use code relocation for WETH only, never for the actual hook or manager.
        address quoteFixture = forceToken0 ? address(uint160(type(uint160).max - 100)) : address(0x10000);
        vm.etch(quoteFixture, address(weth).code);
        weth = MockWETH(quoteFixture);
        feed = new MockEthUsd();
        bytes32 root = keccak256(bytes.concat(keccak256(abi.encode(uint256(0), alice, REWARD))));
        rewards = new MockRewards(root, block.timestamp + 1 hours);
        fees = new MockFeeDistribution(payer, imd);
        router = new UnlkSwapRouter(manager, address(this));
        vault = new UnlkLiquidityLock(manager, address(this), address(factory), fees);
        token = new UnlkToken(address(rewards), address(vault), payer);
        rewards.configure(address(token));
        fees.configure(address(vault));
        oracle = new UnlkOracle(manager, feed, address(token), _quoteAddress(), address(this), 1 hours, 1e18);
        HookDeployer deployer = new HookDeployer();
        UnlkHook.Config memory config = UnlkHook.Config(
            manager,
            token,
            _quoteAddress(),
            address(factory),
            address(router),
            address(vault),
            rewards,
            oracle,
            SPACING
        );
        bytes32 codeHash = deployer.initCodeHash(config);
        bytes32 salt;
        for (uint256 i;; ++i) {
            salt = bytes32(i);
            if (uint160(deployer.predict(salt, codeHash)) & 0x3fff == 0x3fc0) break;
        }
        hook = deployer.deploy(salt, config);
        oracle.configureHook(address(hook));
        router.configureHook(IUnlkHookView(address(hook)));
        vault.configureHook(IUnlkHookView(address(hook)));
        tokenIs0 = address(token) < _quoteAddress();
        key = PoolKey(
            Currency.wrap(tokenIs0 ? address(token) : _quoteAddress()),
            Currency.wrap(tokenIs0 ? _quoteAddress() : address(token)),
            12500,
            SPACING,
            IHooks(address(hook))
        );
        weth.mint(address(this), 1_000_000 ether);
        weth.approve(address(factory), type(uint256).max);
        weth.mint(alice, 10_000 ether);
        weth.mint(bob, 10_000 ether);
        vm.startPrank(alice);
        weth.approve(address(router), type(uint256).max);
        token.approve(address(router), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        weth.approve(address(router), type(uint256).max);
        token.approve(address(router), type(uint256).max);
        vm.stopPrank();
        vm.prank(payer);
        token.approve(address(router), type(uint256).max);
    }

    function _quoteAddress() internal view virtual returns (address) {
        return address(weth);
    }

    function _initialize(int24 normalizedTick) internal virtual {
        uint160 sqrt = TickMath.getSqrtPriceAtTick(tokenIs0 ? normalizedTick : -normalizedTick);
        factory.initialize(manager, key, sqrt);
        uint160 lower = TickMath.getSqrtPriceAtTick(LOWER);
        uint160 upper = TickMath.getSqrtPriceAtTick(UPPER);
        uint256 amount = token.POOL_ALLOCATION();
        uint256 liquidity;
        if (tokenIs0) {
            uint256 intermediate = Math.mulDiv(sqrt, upper, 1 << 96);
            liquidity = Math.mulDiv(amount, intermediate, upper - sqrt);
        } else {
            liquidity = Math.mulDiv(amount, 1 << 96, sqrt - lower);
        }
        factory.seed(vault, IERC20(address(weth)), 10000 ether, uint128(liquidity), LOWER, UPPER);
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
}
