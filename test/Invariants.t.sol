// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {SystemFixture} from "./fixtures/SystemFixture.sol";
import {Test} from "forge-std/Test.sol";
import {UnlkHook} from "../src/UnlkHook.sol";
import {UnlkToken} from "../src/UnlkToken.sol";
import {UnlkSwapRouter} from "../src/UnlkSwapRouter.sol";
import {MockWETH, MockRewards, MockEthUsd} from "./fixtures/LocalFixtures.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

contract ActionHandler is Test {
    UnlkHook public immutable hook;
    UnlkToken public immutable token;
    UnlkSwapRouter public immutable router;
    MockWETH public immutable weth;
    MockRewards public immutable rewards;
    MockEthUsd public immutable feed;
    address[3] public actors;
    bool immutable tokenIs0;
    mapping(address => uint256) public ghostBuys;
    mapping(address => uint256) public ghostSales;
    uint16 public highestP = 2500;
    bool public unlockedObserved;
    uint256 public successfulBuys;
    uint256 public successfulSales;
    uint256 public rejectedSales;

    constructor(
        UnlkHook h,
        UnlkToken t,
        UnlkSwapRouter r,
        MockWETH w,
        MockRewards d,
        MockEthUsd f,
        address a,
        address b,
        address payer
    ) {
        hook = h;
        token = t;
        router = r;
        weth = w;
        rewards = d;
        feed = f;
        actors = [a, b, payer];
        tokenIs0 = address(t) < address(w);
        for (uint256 i; i < 3; ++i) {
            w.mint(actors[i], 1000 ether);
            vm.startPrank(actors[i]);
            w.approve(address(r), type(uint256).max);
            t.approve(address(r), type(uint256).max);
            vm.stopPrank();
        }
    }

    function buy(uint256 actorSeed, uint96 amountSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 amount = bound(amountSeed, 1e12, 0.5 ether);
        vm.prank(actor);
        try router.swap(_request(true, amount)) returns (uint256, uint256 output) {
            ghostBuys[actor] += output;
            ++successfulBuys;
        } catch {}
    }

    function sell(uint256 actorSeed, uint96 amountSeed, bool withinQuota) external {
        address actor = actors[actorSeed % 3];
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;
        uint256 limit = withinQuota ? _min(balance, hook.remainingQuota(actor)) : balance;
        if (limit == 0) return;
        uint256 amount = bound(amountSeed, 1, limit);
        vm.prank(actor);
        try router.swap(_request(false, amount)) returns (uint256 input, uint256) {
            ghostSales[actor] += input;
            ++successfulSales;
        } catch {
            ++rejectedSales;
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint96 amountSeed) external {
        address from = actors[fromSeed % 3];
        address to = actors[toSeed % 3];
        uint256 amount = bound(amountSeed, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(to, amount);
    }

    function sync(uint256 actorSeed) external {
        hook.syncPayer();
        hook.syncRewards(actors[actorSeed % 3]);
    }

    function claim() external {
        if (block.timestamp < rewards.releaseTime()) return;
        try rewards.claim(0, actors[0], 1_000_000 ether, new bytes32[](0)) {} catch {}
    }

    function advance(uint16 secondsSeed) external {
        uint256 elapsed = bound(secondsSeed, 1, 301);
        vm.warp(block.timestamp + elapsed);
        vm.roll(block.number + 1);
        feed.fresh();
        hook.updateMilestone();
        assertGe(hook.p(), highestP);
        if (unlockedObserved) assertTrue(hook.fullyUnlocked());
        highestP = hook.p();
        unlockedObserved = hook.fullyUnlocked();
    }

    function _request(bool buy_, uint256 amount) private view returns (UnlkSwapRouter.SwapRequest memory) {
        bool zeroForOne = buy_ ? !tokenIs0 : tokenIs0;
        return UnlkSwapRouter.SwapRequest(
            zeroForOne,
            -int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            amount,
            1,
            block.timestamp + 1
        );
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}

contract SystemInvariantTest is SystemFixture {
    using StateLibrary for IPoolManager;
    ActionHandler internal handler;

    function setUp() public virtual override {
        super.setUp();
        // Make native claims reachable from the first generated action, rather than relying on rare long sequences.
        _advance(1 hours);
        handler = new ActionHandler(hook, token, router, weth, rewards, feed, alice, bob, payer);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = ActionHandler.buy.selector;
        selectors[1] = ActionHandler.sell.selector;
        selectors[2] = ActionHandler.transfer.selector;
        selectors[3] = ActionHandler.sync.selector;
        selectors[4] = ActionHandler.claim.selector;
        selectors[5] = ActionHandler.advance.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariantEligibleEqualsOnlyExecutedBuysAndSynchronizedProofs() public view {
        address[3] memory actors = [alice, bob, payer];
        for (uint256 i; i < 3; ++i) {
            uint256 expected = handler.ghostBuys(actors[i]) + hook.claimedCredit(actors[i]);
            if (actors[i] == payer && hook.payerCredited()) expected += 30_000_000 ether;
            assertLe(hook.claimedCredit(actors[i]), rewards.claimed(actors[i]));
            assertEq(hook.eligible(actors[i]), expected);
            assertEq(hook.sold(actors[i]), handler.ghostSales(actors[i]));
        }
    }

    function invariantNoActorExceedsItsQuotaBeforeUnlock() public view {
        if (hook.fullyUnlocked()) return;
        address[3] memory actors = [alice, bob, payer];
        for (uint256 i; i < 3; ++i) {
            assertLe(hook.sold(actors[i]), hook.eligible(actors[i]) * hook.p() / 10000);
        }
    }

    function invariantSupplyConservedAndRouterHasNoCustody() public view {
        uint256 total = token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(payer)
            + token.balanceOf(address(manager)) + token.balanceOf(address(vault))
            + token.balanceOf(address(rewards));
        assertEq(total, token.totalSupply());
        assertEq(total, 1_000_000_000 ether);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(weth.balanceOf(address(router)), 0);
        (address trader, bytes32 operation) = router.context();
        assertEq(trader, address(0));
        assertEq(operation, bytes32(0));
    }

    function invariantPrincipalLiquidityNeverDecreases() public view {
        (uint128 liquidity,,) = IPoolManager(address(manager))
            .getPositionInfo(hook.poolId(), address(vault), LOWER, UPPER, bytes32(0));
        assertEq(liquidity, vault.lockedLiquidity());
        assertEq(hook.eligible(address(vault)), 0);
        assertEq(hook.sold(address(vault)), 0);
    }
}

contract FullyUnlockedInvariantTest is SystemInvariantTest {
    function setUp() public override {
        super.setUp();
        feed.set(300000e8);
        _confirm();
        assertTrue(hook.fullyUnlocked());
        feed.setBroken(true);
    }

    function invariantUnlockRemainsPermanentDespiteInvalidFeed() public view {
        assertTrue(hook.fullyUnlocked());
        assertEq(hook.p(), 10000);
        assertEq(hook.remainingQuota(bob), type(uint256).max);
    }
}
