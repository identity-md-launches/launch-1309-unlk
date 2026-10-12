// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {SystemFixture} from "./fixtures/SystemFixture.sol";
import {UnlkHook} from "../src/UnlkHook.sol";
import {UnlkSwapRouter} from "../src/UnlkSwapRouter.sol";
import {HookDeployer} from "../src/HookDeployer.sol";
import {LaunchFactory} from "./imd/LaunchFactory.sol";
import {UnlkOracle} from "../src/UnlkOracle.sol";
import {UnlkToken} from "../src/UnlkToken.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlkHookView} from "../src/interfaces/IIntegration.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract LaunchTest is SystemFixture {
    function testLaunchAllocationAndLockedPrincipal() public view {
        assertEq(token.name(), "UNLOCK");
        assertEq(token.symbol(), "UNLK");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        // 10% to the factory-created distributor, at most 87% into the factory-held pool position, 3% plus seed
        // rounding to the remainder wallet; the factory keeps nothing.
        assertEq(token.balanceOf(address(distributor)), 100_000_000 ether);
        assertApproxEqAbs(token.balanceOf(payer), 30_000_000 ether, 1e9);
        assertGe(token.balanceOf(payer), 30_000_000 ether);
        assertApproxEqAbs(token.balanceOf(address(manager)), 870_000_000 ether, 1e9);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(_factoryLiquidity(seedLower, seedUpper), seedLiquidity);
        assertEq(hook.swarm(), address(distributor));
        assertEq(hook.payer(), payer);
        assertEq(hook.quoteToken(), _quoteAddress());
        assertTrue(hook.bound());
        assertEq(uint160(address(hook)) & 0x3fff, hook.FLAGS());
        (,,, address requester) = factory.positionOf(LAUNCH_NUMBER);
        assertEq(requester, payer);
    }

    function testOneTimeSetup() public {
        vm.expectRevert(UnlkSwapRouter.Unauthorized.selector);
        router.configureHook(IUnlkHookView(address(hook)));
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
        vm.prank(address(factory));
        vm.expectRevert();
        manager.initialize(wrong, TickMath.getSqrtPriceAtTick(0));
    }

    function testLaunchIsOnceAndDeployerOnly() public {
        LaunchFactory.LaunchParams memory params = _launchParams(1 << 96, seedLower, seedUpper, 1);
        vm.expectRevert(abi.encodeWithSelector(LaunchFactory.AlreadyLaunched.selector, LAUNCH_NUMBER));
        factory.launch(params);
        vm.prank(bob);
        vm.expectRevert(LaunchFactory.NotDeployer.selector);
        factory.launch(params);
    }

    function testFactoryHoldsPrincipalAndCannotRemoveIt() public {
        uint128 before = _factoryLiquidity(seedLower, seedUpper);
        assertGt(before, 0);
        // The factory's only liquidity-changing callback paths are launch() and the zero-delta fee claim.
        factory.claimFees(LAUNCH_NUMBER);
        assertEq(_factoryLiquidity(seedLower, seedUpper), before);
        // Even the factory's own callback path only ever adds (uint128) or collects (zero delta); the hook also
        // refuses any negative delta from anyone (see CreditsAndFeesTest).
        vm.prank(address(factory));
        manager.unlock(
            abi.encode(
                LaunchFactory.Seeding({
                    key: key, tickLower: seedLower, tickUpper: seedUpper, liquidity: 0, token: address(token)
                })
            )
        );
        assertEq(_factoryLiquidity(seedLower, seedUpper), before);
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

    /// @dev A hook deployed outside the factory (same config, local CREATE2 deployer) cannot be bound by anyone
    /// but the factory, and the factory binds only the exact fee/spacing it was configured for.
    function _sideHook() internal returns (UnlkHook side) {
        UnlkHook.Config memory config = UnlkHook.Config(
            manager,
            UnlkToken(rewards.token()),
            address(factory),
            payer,
            address(router),
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
        side = deployer.deploy(salt, config);
    }

    function testOnlyFactoryCanInitializeUnboundOfficialPool() public {
        UnlkHook side = _sideHook();
        PoolKey memory sideKey = key;
        sideKey.hooks = IHooks(address(side));
        vm.expectRevert();
        manager.initialize(sideKey, TickMath.getSqrtPriceAtTick(175020));
        assertFalse(side.bound());
    }

    function testLaunchRejectsWrongFeeOrTickSpacing() public {
        LaunchFactory.LaunchParams memory params =
            _launchParams(TickMath.getSqrtPriceAtTick(OPENING_TICK), LOWER, UPPER, 1);
        params.fee = 3000;
        vm.expectRevert();
        factory.launch(params);
        params = _launchParams(TickMath.getSqrtPriceAtTick(OPENING_TICK), LOWER, UPPER, 1);
        params.tickSpacing = 120;
        vm.expectRevert();
        factory.launch(params);
        assertEq(predictedHook.code.length, 0);
    }

    function testLaunchRejectsSeedThatSpendsPairedCurrency() public {
        // A range straddling the price would need WETH the factory must not spend: the whole launch reverts.
        weth.mint(address(factory), 1 ether);
        LaunchFactory.LaunchParams memory params = _launchParams(
            TickMath.getSqrtPriceAtTick(tokenIs0 ? OPENING_TICK : -OPENING_TICK), LOWER, UPPER, 1e15
        );
        vm.expectRevert();
        factory.launch(params);
        assertEq(predictedHook.code.length, 0);
    }

    function testUnboundCreditsCannotBeSynchronized() public {
        UnlkHook side = _sideHook();
        vm.expectRevert(UnlkHook.InvalidPool.selector);
        side.syncPayer();
        vm.expectRevert(UnlkHook.InvalidEvidence.selector);
        side.syncRewards(alice);
        assertFalse(side.updateMilestone());
    }

    function testCompanionMisconfigurationFailsTheLaunchAtomically() public {
        // A router that does not point back at the predicted hook: beforeInitialize refuses, nothing deploys.
        UnlkSwapRouter other = new UnlkSwapRouter(manager, address(this));
        UnlkHook.Config memory config = UnlkHook.Config(
            manager,
            UnlkToken(rewards.token()),
            address(factory),
            payer,
            address(other),
            rewards,
            oracle,
            SPACING
        );
        hookInitCode = deployer.initCode(config);
        _mineHookSalt();
        LaunchFactory.LaunchParams memory params =
            _launchParams(TickMath.getSqrtPriceAtTick(OPENING_TICK), LOWER, UPPER, 1);
        vm.expectRevert();
        factory.launch(params);
        assertEq(predictedHook.code.length, 0);
        assertEq(rewards.token().code.length, 0);
    }

    function testForeignCallerCannotConfigureUnsetRouter() public {
        UnlkSwapRouter empty = new UnlkSwapRouter(manager, address(this));
        vm.prank(bob);
        vm.expectRevert(UnlkSwapRouter.Unauthorized.selector);
        empty.configureHook(IUnlkHookView(address(hook)));
    }
}
