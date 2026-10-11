// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {SystemFixture} from "./fixtures/SystemFixture.sol";
import {UnlkHook} from "../src/UnlkHook.sol";
import {UnlkLiquidityLock} from "../src/UnlkLiquidityLock.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CreditsAndFeesTest is SystemFixture, IUnlockCallback {
    using StateLibrary for IPoolManager;

    function testUnclaimedRewardsNotEligible() public view {
        assertEq(hook.eligible(alice), 0);
        assertEq(hook.pendingRewardCredit(alice), 0);
        assertEq(token.balanceOf(alice), 0);
    }

    function testNativeClaimThenSyncThenSale() public {
        _advance(1 hours);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(bob);
        rewards.claim(0, alice, REWARD, proof);
        assertEq(token.balanceOf(alice), REWARD);
        assertEq(hook.eligible(alice), 0);
        assertEq(hook.pendingRewardCredit(alice), REWARD);
        vm.expectRevert();
        _sell(alice, REWARD / 4);
        vm.prank(bob);
        assertEq(hook.syncRewards(alice), REWARD);
        assertEq(hook.pendingRewardCredit(alice), 0);
        assertEq(hook.syncRewards(alice), 0);
        _sell(alice, REWARD / 4);
        assertEq(hook.sold(alice), REWARD / 4);
        assertEq(hook.eligible(bob), 0);
    }

    function testProofReleaseAndDedupRemainNativeRules() public {
        bytes32[] memory proof = new bytes32[](0);
        vm.expectRevert("unreleased");
        rewards.claim(0, alice, REWARD, proof);
        _advance(1 hours);
        vm.expectRevert("invalid proof");
        rewards.claim(0, bob, REWARD, proof);
        vm.expectRevert("invalid proof");
        rewards.claim(0, alice, REWARD + 1, proof);
        rewards.claim(0, alice, REWARD, proof);
        vm.expectRevert("duplicate");
        rewards.claim(0, alice, REWARD, proof);
        hook.syncRewards(alice);
        hook.syncRewards(alice);
        assertEq(hook.eligible(alice), REWARD);
    }

    function testCreditEvidenceFailureCannotBlockNativeClaim() public {
        _advance(1 hours);
        rewards.setBrokenEvidence(true);
        feed.setBroken(true);
        rewards.claim(0, alice, REWARD, new bytes32[](0));
        assertEq(token.balanceOf(alice), REWARD);
        vm.expectRevert("fixture evidence failure");
        hook.syncRewards(alice);
        assertEq(hook.eligible(alice), 0);
        rewards.setBrokenEvidence(false);
        hook.syncRewards(alice);
        _sell(alice, REWARD / 4);
        assertEq(hook.sold(alice), REWARD / 4);
    }

    function testClaimTransferAndPayerTransferDoNotDuplicateCredit() public {
        _advance(1 hours);
        rewards.claim(0, alice, REWARD, new bytes32[](0));
        vm.prank(alice);
        token.transfer(bob, REWARD);
        hook.syncRewards(alice);
        hook.syncRewards(bob);
        assertEq(hook.eligible(alice), REWARD);
        assertEq(hook.eligible(bob), 0);
        vm.prank(payer);
        token.transfer(bob, 1_000_000 ether);
        hook.syncPayer();
        assertEq(hook.eligible(payer), 30_000_000 ether);
        assertEq(hook.eligible(bob), 0);
    }

    function testPoolFee125BpsNoHookFeeAndDistribution80_20() public {
        uint256 payerBefore = weth.balanceOf(payer);
        uint256 imdBefore = weth.balanceOf(imd);
        _buy(alice, 1 ether);
        (uint256 f0, uint256 f1) = vault.collectFees();
        uint256 fee = tokenIs0 ? f1 : f0;
        assertApproxEqAbs(fee, 0.0125 ether, 2);
        assertEq(weth.balanceOf(payer) - payerBefore, fee * 4 / 5);
        assertEq(weth.balanceOf(imd) - imdBefore, fee - fee * 4 / 5);
        assertEq(weth.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(hook.eligible(payer), 0);
        assertEq(hook.eligible(imd), 0);
        (f0, f1) = vault.collectFees();
        assertEq(f0, 0);
        assertEq(f1, 0);
    }

    function testSaleFeesCountGrossInputAndNeverCreditFeeRecipients() public {
        uint256 bought = _buy(alice, 1 ether);
        vault.collectFees();
        uint256 q = bought / 4;
        _sell(alice, q);
        (uint256 f0, uint256 f1) = vault.collectFees();
        uint256 fee = tokenIs0 ? f0 : f1;
        assertApproxEqAbs(fee, q * 12500 / 1e6, 2);
        assertEq(hook.sold(alice), q);
        assertEq(hook.eligible(payer), 0);
        assertEq(hook.eligible(imd), 0);
    }

    function testFeeCollectionDoesNotReducePrincipal() public {
        (uint128 beforeLiquidity,,) = IPoolManager(address(manager))
            .getPositionInfo(hook.poolId(), address(vault), LOWER, UPPER, bytes32(0));
        _buy(alice, 1 ether);
        vault.collectFees();
        (uint128 afterLiquidity,,) = IPoolManager(address(manager))
            .getPositionInfo(hook.poolId(), address(vault), LOWER, UPPER, bytes32(0));
        assertEq(beforeLiquidity, afterLiquidity);
        assertEq(afterLiquidity, vault.lockedLiquidity());
        assertEq(hook.eligible(address(vault)), 0);
    }

    function testNegativeLiquidityForbiddenEvenForVault() public {
        IPoolManager.ModifyLiquidityParams memory params =
            IPoolManager.ModifyLiquidityParams(LOWER, UPPER, -1, bytes32(0));
        vm.prank(address(manager));
        vm.expectRevert(UnlkHook.PrincipalLocked.selector);
        hook.beforeRemoveLiquidity(address(vault), key, params, "");
        vm.expectRevert(UnlkLiquidityLock.Unauthorized.selector);
        vault.unlockCallback(abi.encode(key));
    }

    function testUnauthorizedLiquidityAndDonationNoCredit() public {
        IPoolManager.ModifyLiquidityParams memory params =
            IPoolManager.ModifyLiquidityParams(LOWER, UPPER, 1, bytes32(0));
        vm.prank(address(manager));
        vm.expectRevert(UnlkHook.Unauthorized.selector);
        hook.beforeAddLiquidity(bob, key, params, "");
        vm.prank(payer);
        token.transfer(address(this), 100 ether);
        manager.unlock("");
        assertEq(hook.eligible(address(this)), 0);
        assertEq(hook.sold(address(this)), 0);
        assertEq(hook.eligible(payer), 0);
        assertEq(hook.eligible(address(vault)), 0);
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager));
        manager.donate(key, tokenIs0 ? 100 ether : 0, tokenIs0 ? 0 : 100 ether, "");
        Currency currency = Currency.wrap(address(token));
        manager.sync(currency);
        token.transfer(address(manager), 100 ether);
        assertEq(manager.settle(), 100 ether);
        return "";
    }
}
