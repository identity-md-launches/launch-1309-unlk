// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {SystemFixture} from "./fixtures/SystemFixture.sol";
import {CheckReleaseConfig} from "../script/CheckReleaseConfig.s.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

contract ReleaseConfigTest is SystemFixture {
    function testReadOnlyReleaseChecksOnLocalFixture() public {
        CheckReleaseConfig checker = new CheckReleaseConfig();
        (PoolId id, uint128 liquidity, uint256 pending) =
            checker.run(hook, block.chainid, address(manager).codehash, address(feed).codehash);
        assertEq(PoolId.unwrap(id), PoolId.unwrap(hook.poolId()));
        assertEq(liquidity, vault.lockedLiquidity());
        assertEq(pending, 30_000_000 ether);
    }

    function testReadOnlyReleaseChecksRejectWrongChainOrHash() public {
        CheckReleaseConfig checker = new CheckReleaseConfig();
        vm.expectRevert("chain mismatch");
        checker.run(hook, 1, address(manager).codehash, address(feed).codehash);
        vm.expectRevert("manager code mismatch");
        checker.run(hook, block.chainid, bytes32(uint256(1)), address(feed).codehash);
    }
}
