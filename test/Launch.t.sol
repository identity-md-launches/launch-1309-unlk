// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {SystemFixture} from "./fixtures/SystemFixture.sol";
import {UnlkHook} from "../src/UnlkHook.sol";
import {UnlkSwapRouter} from "../src/UnlkSwapRouter.sol";
import {UnlkLiquidityLock} from "../src/UnlkLiquidityLock.sol";
import {UnlkOracle} from "../src/UnlkOracle.sol";
import {IUnlkHookView} from "../src/interfaces/IIntegration.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract LaunchTest is SystemFixture {
    function testLaunchAllocationAndLockedPrincipal() public view {
        assertEq(token.name(), "UNLK");
        assertEq(token.symbol(), "UNLK");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(rewards)), 100_000_000 ether);
        assertEq(token.balanceOf(payer), 30_000_000 ether);
        assertApproxEqAbs(vault.initialTokenUsed(), 870_000_000 ether, 1e9);
        assertLe(token.balanceOf(address(vault)), 1e9);
        assertTrue(vault.seeded());
        assertTrue(hook.bound());
        assertEq(uint160(address(hook)) & 0x3fff, hook.FLAGS());
    }

    function testOneTimeSetup() public {
        vm.expectRevert(UnlkSwapRouter.Unauthorized.selector);
        router.configureHook(IUnlkHookView(address(hook)));
        vm.expectRevert(UnlkLiquidityLock.Unauthorized.selector);
        vault.configureHook(IUnlkHookView(address(hook)));
        vm.expectRevert(UnlkOracle.Unauthorized.selector);
        oracle.configureHook(address(hook));
    }

    function testOnlyCanonicalManagerCanCallHook() public {
        vm.expectRevert(UnlkHook.Unauthorized.selector);
        hook.beforeInitialize(address(factory), key, 1 << 96);
        vm.expectRevert(UnlkHook.Unauthorized.selector);
        hook.afterInitialize(address(factory), key, 1 << 96, 0);
    }

    function testUnauthorizedFactoryAndWrongPoolRejected() public {
        PoolKey memory wrong = key;
        wrong.tickSpacing = 120;
        vm.expectRevert();
        manager.initialize(wrong, TickMath.getSqrtPriceAtTick(0));
        vm.expectRevert();
        factory.initialize(manager, wrong, TickMath.getSqrtPriceAtTick(0));
    }

    function testOnlyFactorySeedsOnce() public {
        vm.expectRevert(UnlkLiquidityLock.Unauthorized.selector);
        vault.seed(100, -60, 60, 1);
        vm.prank(address(factory));
        vm.expectRevert(UnlkLiquidityLock.InvalidLiquidity.selector);
        vault.seed(100, -60, 60, 1);
    }

    function testPayerCreditExactDeduplicated() public {
        assertEq(hook.eligible(payer), 0);
        (address recipient, uint256 pending) = hook.pendingPayerCredit();
        assertEq(recipient, payer);
        assertEq(pending, 30_000_000 ether);
        vm.prank(bob);
        assertEq(hook.syncPayer(), pending);
        assertEq(hook.eligible(payer), pending);
        assertEq(hook.syncPayer(), 0);
        assertEq(hook.remainingQuota(payer), 7_500_000 ether);
    }

    function testUnconfiguredComponentsFailClosed() public {
        UnlkSwapRouter empty = new UnlkSwapRouter(manager, address(this));
        vm.expectRevert(UnlkSwapRouter.InvalidSwap.selector);
        empty.swap(_request(true, -int256(1 ether), 1 ether));
    }
}

contract InitializationGuardTest is SystemFixture {
    function setUp() public override {
        _deploy(false);
    }

    function testOnlyFactoryCanInitializeUnboundOfficialPool() public {
        vm.expectRevert();
        manager.initialize(key, TickMath.getSqrtPriceAtTick(175000));
        assertFalse(hook.bound());
        factory.initialize(manager, key, TickMath.getSqrtPriceAtTick(175000));
        assertTrue(hook.bound());
        vm.expectRevert();
        factory.initialize(manager, key, TickMath.getSqrtPriceAtTick(175000));
    }

    function testFactoryCannotBindWrongFeeOrTickSpacing() public {
        PoolKey memory wrong = key;
        wrong.fee = 3000;
        vm.expectRevert();
        factory.initialize(manager, wrong, TickMath.getSqrtPriceAtTick(175000));
        assertFalse(hook.bound());
        wrong = key;
        wrong.tickSpacing = 120;
        vm.expectRevert();
        factory.initialize(manager, wrong, TickMath.getSqrtPriceAtTick(175000));
        assertFalse(hook.bound());
    }

    function testUnboundCreditsCannotBeSynchronized() public {
        vm.expectRevert(UnlkHook.InvalidPool.selector);
        hook.syncPayer();
        vm.expectRevert(UnlkHook.InvalidEvidence.selector);
        hook.syncRewards(alice);
        assertFalse(hook.updateMilestone());
    }

    function testForeignCallerCannotConfigureUnsetRouter() public {
        UnlkSwapRouter empty = new UnlkSwapRouter(manager, address(this));
        vm.prank(bob);
        vm.expectRevert(UnlkSwapRouter.Unauthorized.selector);
        empty.configureHook(IUnlkHookView(address(hook)));
    }
}
