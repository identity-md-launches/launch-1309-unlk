// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {SystemFixture} from "./fixtures/SystemFixture.sol";
import {UnlkHook} from "../src/UnlkHook.sol";
import {UnlkToken} from "../src/UnlkToken.sol";
import {UnlkSwapRouter} from "../src/UnlkSwapRouter.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract AdversarialTest is SystemFixture {
    using stdStorage for StdStorage;

    function test100PercentAloneIsNotFullUnlock() public {
        // Explicit ledger unit fixture: this unreachable partial state verifies the separate bypass bit.
        stdstore.target(address(hook)).sig(hook.p.selector).enable_packed_slots().checked_write(uint16(10000));
        assertFalse(hook.fullyUnlocked());
        vm.prank(payer);
        token.transfer(bob, 1000 ether);
        assertEq(hook.remainingQuota(bob), 0);
        vm.expectRevert();
        _sell(bob, 1 ether);
    }

    function testQuotaMultiplicationDoesNotOverflowAtMaxEligible() public {
        // Artificial boundary fixture, not a claim that uint256.max acquisitions are economically reachable.
        stdstore.target(address(hook))
            .sig(hook.eligible.selector)
            .with_key(alice)
            .checked_write(type(uint256).max);
        assertEq(hook.remainingQuota(alice), type(uint256).max / 4);
    }

    function testNoMintPauseBlacklistUpgradeOrCounterResetEntrypoint() public {
        uint256 supply = token.totalSupply();
        (bool mintOK,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", alice, 1 ether));
        (bool pauseOK,) = address(token).call(abi.encodeWithSignature("pause()"));
        (bool upgradeOK,) = address(hook).call(abi.encodeWithSignature("upgradeTo(address)", bob));
        (bool resetOK,) = address(hook).call(abi.encodeWithSignature("reset(address)", payer));
        assertFalse(mintOK);
        assertFalse(pauseOK);
        assertFalse(upgradeOK);
        assertFalse(resetOK);
        assertEq(token.totalSupply(), supply);
    }

    function testTokenMintsWholeSupplyToDeployerOnly() public {
        vm.prank(bob);
        UnlkToken fresh = new UnlkToken();
        assertEq(fresh.balanceOf(bob), fresh.SUPPLY());
        assertEq(fresh.totalSupply(), fresh.SUPPLY());
        assertEq(
            fresh.SWARM_ALLOCATION() + fresh.POOL_ALLOCATION() + fresh.PAYER_ALLOCATION(), fresh.SUPPLY()
        );
    }

    function testProtocolFeeChangeCannotSilentlyAlterTradingEconomics() public {
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(key, uint24(500));
        vm.expectRevert();
        _buy(alice, 1 ether);
        assertEq(hook.eligible(alice), 0);
        // Ordinary token transfers remain independent of any PoolManager policy.
        vm.prank(payer);
        token.transfer(bob, 1 ether);
        assertEq(token.balanceOf(bob), 1 ether);
    }

    function testForeignPoolKeyRejectedEvenWithManagerPrank() public {
        PoolKey memory wrong = key;
        wrong.fee = 3000;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(true, -1, 1);
        vm.prank(address(manager));
        vm.expectRevert(UnlkHook.InvalidPool.selector);
        hook.beforeSwap(address(router), wrong, params, abi.encode(uint256(1)));
    }

    function testArbitraryHookDataAndMultihopPayloadCannotSelectVictim() public {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(true, -1, 1);
        bytes memory malicious = abi.encode(alice, bob, uint256(123), address(token));
        vm.prank(address(manager));
        vm.expectRevert(UnlkHook.InvalidRoute.selector);
        hook.beforeSwap(address(router), key, params, malicious);
        // This route exposes no arbitrary-pool execute/multihop selector.
        (bool ok,) =
            address(router).call(abi.encodeWithSignature("execute(bytes,bytes[])", malicious, new bytes[](0)));
        assertFalse(ok);
    }

    function testCallbacksAllRequireCanonicalManager() public {
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams(true, -1, 1);
        IPoolManager.ModifyLiquidityParams memory liquidityParams =
            IPoolManager.ModifyLiquidityParams(LOWER, UPPER, 0, 0);
        vm.expectRevert(UnlkHook.Unauthorized.selector);
        hook.beforeSwap(address(router), key, swapParams, "");
        vm.expectRevert(UnlkHook.Unauthorized.selector);
        hook.afterSwap(address(router), key, swapParams, BalanceDelta.wrap(0), "");
        vm.expectRevert(UnlkHook.Unauthorized.selector);
        hook.beforeAddLiquidity(address(factory), key, liquidityParams, "");
        vm.expectRevert(UnlkHook.Unauthorized.selector);
        hook.afterAddLiquidity(
            address(factory), key, liquidityParams, BalanceDelta.wrap(0), BalanceDelta.wrap(0), ""
        );
        vm.expectRevert(UnlkHook.Unauthorized.selector);
        hook.beforeRemoveLiquidity(address(factory), key, liquidityParams, "");
        vm.expectRevert(UnlkHook.Unauthorized.selector);
        hook.afterRemoveLiquidity(
            address(factory), key, liquidityParams, BalanceDelta.wrap(0), BalanceDelta.wrap(0), ""
        );
        vm.expectRevert(UnlkHook.Unauthorized.selector);
        hook.beforeDonate(alice, key, 1, 1, "");
        vm.expectRevert(UnlkHook.Unauthorized.selector);
        hook.afterDonate(alice, key, 1, 1, "");
    }
}
