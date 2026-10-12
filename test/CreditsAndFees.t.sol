// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {SystemFixture} from "./fixtures/SystemFixture.sol";
import {UnlkHook} from "../src/UnlkHook.sol";
import {MerkleClaimEvidence} from "../src/MerkleClaimEvidence.sol";
import {MerkleDistributor} from "./imd/MerkleDistributor.sol";
import {LaunchFactory} from "./imd/LaunchFactory.sol";
import {PoolFees} from "./imd/PoolFees.sol";
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

    function testNativeClaimThenAttestThenSyncThenSale() public {
        _advance(1 hours);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(bob);
        distributor.claim(0, alice, REWARD, proof);
        assertEq(token.balanceOf(alice), REWARD);
        assertEq(hook.eligible(alice), 0);
        assertEq(hook.pendingRewardCredit(alice), 0);
        vm.expectRevert();
        _sell(alice, REWARD / 4);
        vm.prank(bob);
        assertEq(rewards.attest(0, alice, REWARD, proof), REWARD);
        assertEq(hook.pendingRewardCredit(alice), REWARD);
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
        vm.expectRevert(
            abi.encodeWithSelector(MerkleDistributor.StillLocked.selector, uint64(block.timestamp + 1 hours))
        );
        distributor.claim(0, alice, REWARD, proof);
        _advance(1 hours);
        vm.expectRevert(MerkleDistributor.InvalidProof.selector);
        distributor.claim(0, bob, REWARD, proof);
        vm.expectRevert(MerkleDistributor.InvalidProof.selector);
        distributor.claim(0, alice, REWARD + 1, proof);
        distributor.claim(0, alice, REWARD, proof);
        vm.expectRevert(MerkleDistributor.AlreadyClaimed.selector);
        distributor.claim(0, alice, REWARD, proof);
        rewards.attest(0, alice, REWARD, proof);
        vm.expectRevert(MerkleClaimEvidence.AlreadyAttested.selector);
        rewards.attest(0, alice, REWARD, proof);
        hook.syncRewards(alice);
        hook.syncRewards(alice);
        assertEq(hook.eligible(alice), REWARD);
    }

    function testAttestationRequiresActualClaimAndExactLeaf() public {
        bytes32[] memory proof = new bytes32[](0);
        // Valid leaf, not claimed yet: no credit can be manufactured ahead of the native claim.
        vm.expectRevert(MerkleClaimEvidence.NotClaimed.selector);
        rewards.attest(0, alice, REWARD, proof);
        _advance(1 hours);
        distributor.claim(0, alice, REWARD, proof);
        // Claimed, but a different amount or account does not match the committed leaf.
        vm.expectRevert(MerkleClaimEvidence.InvalidProof.selector);
        rewards.attest(0, alice, REWARD + 1, proof);
        vm.expectRevert(MerkleClaimEvidence.NotClaimed.selector);
        rewards.attest(0, bob, REWARD, proof);
        vm.expectRevert(MerkleClaimEvidence.NotClaimed.selector);
        rewards.attest(1, alice, REWARD, proof);
        assertEq(rewards.claimed(alice), 0);
        rewards.attest(0, alice, REWARD, proof);
        assertEq(rewards.claimed(alice), REWARD);
        assertEq(rewards.claimed(bob), 0);
    }

    function testNativeClaimNeverDependsOnAdapterOrFeed() public {
        _advance(1 hours);
        feed.setBroken(true);
        // The adapter is a reader; the distributor's claim path does not know it exists.
        distributor.claim(0, alice, REWARD, new bytes32[](0));
        assertEq(token.balanceOf(alice), REWARD);
        assertEq(hook.eligible(alice), 0);
        hook.syncRewards(alice);
        assertEq(hook.eligible(alice), 0);
        rewards.attest(0, alice, REWARD, new bytes32[](0));
        hook.syncRewards(alice);
        _sell(alice, REWARD / 4);
        assertEq(hook.sold(alice), REWARD / 4);
    }

    function testClaimTransferAndPayerTransferDoNotDuplicateCredit() public {
        _advance(1 hours);
        distributor.claim(0, alice, REWARD, new bytes32[](0));
        rewards.attest(0, alice, REWARD, new bytes32[](0));
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
        vm.prank(bob);
        (uint256 f0, uint256 f1) = factory.claimFees(LAUNCH_NUMBER);
        uint256 fee = tokenIs0 ? f1 : f0;
        assertApproxEqAbs(fee, 0.0125 ether, 2);
        // Verified PoolFees split: REQUESTER_BPS 8000 to the requester, the rest to LaunchFees.feeRecipient().
        assertEq(weth.balanceOf(payer) - payerBefore, fee * 8000 / 10000);
        assertEq(weth.balanceOf(imd) - imdBefore, fee - fee * 8000 / 10000);
        assertEq(weth.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(weth.balanceOf(address(factory)), 0);
        assertEq(hook.eligible(payer), 0);
        assertEq(hook.eligible(imd), 0);
        (f0, f1) = factory.claimFees(LAUNCH_NUMBER);
        assertEq(f0, 0);
        assertEq(f1, 0);
    }

    function testRequesterShareIsTransferableOnlyByRequesterAndOwedOnRejection() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PoolFees.NotRequester.selector, LAUNCH_NUMBER));
        factory.setRequester(LAUNCH_NUMBER, bob);
        vm.prank(payer);
        factory.setRequester(LAUNCH_NUMBER, bob);
        (,,, address requester) = factory.positionOf(LAUNCH_NUMBER);
        assertEq(requester, bob);
        uint256 bobBefore = weth.balanceOf(bob);
        _buy(alice, 1 ether);
        factory.claimFees(LAUNCH_NUMBER);
        assertGt(weth.balanceOf(bob), bobBefore);
        // Network share changes recipient at payout time through LaunchFees (IMD governance, not ours).
        address newRecipient = makeAddr("moved network recipient");
        launchFees.setFeeRecipient(newRecipient);
        _buy(alice, 1 ether);
        factory.claimFees(LAUNCH_NUMBER);
        assertGt(weth.balanceOf(newRecipient), 0);
        assertEq(hook.eligible(bob), 0);
        assertEq(hook.eligible(newRecipient), 0);
    }

    function testSaleFeesCountGrossInputAndNeverCreditFeeRecipients() public {
        uint256 bought = _buy(alice, 1 ether);
        factory.claimFees(LAUNCH_NUMBER);
        uint256 q = bought / 4;
        _sell(alice, q);
        (uint256 f0, uint256 f1) = factory.claimFees(LAUNCH_NUMBER);
        uint256 fee = tokenIs0 ? f0 : f1;
        assertApproxEqAbs(fee, q * 12500 / 1e6, 2);
        assertEq(hook.sold(alice), q);
        assertEq(hook.eligible(payer), 0);
        assertEq(hook.eligible(imd), 0);
    }

    function testFeeCollectionDoesNotReducePrincipal() public {
        uint128 beforeLiquidity = _factoryLiquidity(seedLower, seedUpper);
        _buy(alice, 1 ether);
        factory.claimFees(LAUNCH_NUMBER);
        uint128 afterLiquidity = _factoryLiquidity(seedLower, seedUpper);
        assertEq(beforeLiquidity, afterLiquidity);
        assertEq(afterLiquidity, seedLiquidity);
        assertEq(hook.eligible(address(factory)), 0);
    }

    function testNegativeLiquidityForbiddenEvenForFactory() public {
        IPoolManager.ModifyLiquidityParams memory params =
            IPoolManager.ModifyLiquidityParams(seedLower, seedUpper, -1, bytes32(0));
        vm.prank(address(manager));
        vm.expectRevert(UnlkHook.PrincipalLocked.selector);
        hook.beforeRemoveLiquidity(address(factory), key, params, "");
        vm.expectRevert(LaunchFactory.NotPoolManager.selector);
        factory.unlockCallback(abi.encode(key));
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
        assertEq(hook.eligible(address(factory)), 0);
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
