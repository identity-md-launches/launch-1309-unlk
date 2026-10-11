// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {SystemFixture} from "./fixtures/SystemFixture.sol";
import {UnlkHook} from "../src/UnlkHook.sol";
import {UnlkOracle} from "../src/UnlkOracle.sol";
import {UnlkSwapRouter} from "../src/UnlkSwapRouter.sol";
import {MockWETH} from "./fixtures/LocalFixtures.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// LOCAL flash-loan fixture. This tests an atomic price excursion; it is not a production lender.
interface IFlashBorrower {
    function onFlashLoan(uint256 amount) external;
}

contract LocalFlashLender {
    IERC20 immutable currency;

    constructor(IERC20 currency_) {
        currency = currency_;
    }

    function loan(uint256 amount) external {
        uint256 beforeBalance = currency.balanceOf(address(this));
        require(currency.transfer(msg.sender, amount));
        IFlashBorrower(msg.sender).onFlashLoan(amount);
        require(currency.balanceOf(address(this)) >= beforeBalance, "unpaid fixture loan");
    }
}

contract LocalFlashAttacker is IFlashBorrower {
    LocalFlashLender immutable lender;
    IERC20 immutable quote;
    UnlkSwapRouter immutable router;
    UnlkHook immutable hook;
    UnlkSwapRouter.SwapRequest private request;
    uint16 public observedP;

    constructor(LocalFlashLender l, IERC20 q, UnlkSwapRouter r, UnlkHook h) {
        lender = l;
        quote = q;
        router = r;
        hook = h;
        quote.approve(address(r), type(uint256).max);
    }

    function attack(UnlkSwapRouter.SwapRequest calldata r) external {
        request = r;
        lender.loan(r.maxInput);
    }

    function onFlashLoan(uint256 amount) external {
        require(msg.sender == address(lender));
        router.swap(request);
        hook.updateMilestone();
        observedP = hook.p();
        require(quote.transfer(address(lender), amount));
    }
}

contract OracleTest is SystemFixture {
    function _warm() internal {
        _advance(30 minutes);
        oracle.checkpoint();
    }

    function testWarmupAndExactWindow() public {
        vm.expectRevert(UnlkOracle.InvalidOracle.selector);
        oracle.fdvUsd();
        _advance(30 minutes - 1);
        oracle.checkpoint();
        vm.expectRevert(UnlkOracle.InvalidOracle.selector);
        oracle.fdvUsd();
        _advance(1);
        oracle.checkpoint();
        uint256 fdv = oracle.fdvUsd();
        assertGt(fdv, 49000 ether);
        assertLt(fdv, 51000 ether);
        assertEq(oracle.twapTick(), -175000);
    }

    function testSameTimestampManipulationHasNoTimeWeight() public {
        _warm();
        uint256 beforeFdv = oracle.fdvUsd();
        uint256 count = oracle.observationCount();
        _buy(alice, 500 ether);
        assertEq(oracle.fdvUsd(), beforeFdv);
        assertEq(oracle.observationCount(), count);
        hook.updateMilestone();
        assertEq(hook.p(), 2500);
        assertFalse(hook.fullyUnlocked());
    }

    function testFlashLoanCannotCrossMilestoneInItsTransaction() public {
        _warm();
        LocalFlashLender lender = new LocalFlashLender(IERC20(address(weth)));
        LocalFlashAttacker attacker = new LocalFlashAttacker(lender, IERC20(address(weth)), router, hook);
        weth.mint(address(lender), 1000 ether);
        // Own capital repays the loan; this also proves a well-funded atomic manipulator gains no elapsed time.
        weth.mint(address(attacker), 500 ether);
        uint256 fdv = oracle.fdvUsd();
        attacker.attack(_request(true, -int256(500 ether), 500 ether));
        assertEq(weth.balanceOf(address(lender)), 1000 ether);
        assertEq(oracle.fdvUsd(), fdv);
        assertEq(attacker.observedP(), 2500);
    }

    function testOneBlockSpikeCannotConfirm() public {
        _warm();
        _buy(alice, 500 ether);
        _advance(12);
        hook.updateMilestone();
        assertFalse(hook.fullyUnlocked());
        assertEq(hook.p(), 2500);
    }

    function testSustainedManipulationRequiresWindowAndConfirmation() public {
        _warm();
        _buy(alice, 500 ether);
        _advance(30 minutes);
        hook.updateMilestone();
        assertEq(hook.tierForFdv(oracle.fdvUsd()), 6);
        assertFalse(hook.fullyUnlocked());
        for (uint256 i; i < 11; ++i) {
            _advance(5 minutes);
            hook.updateMilestone();
        }
        assertFalse(hook.fullyUnlocked());
        _advance(5 minutes);
        hook.updateMilestone();
        assertTrue(hook.fullyUnlocked());
        // An onchain-only oracle cannot distinguish a funded 90-minute manipulation from a lasting market price.
    }

    function testConfirmationGapRestartsRatherThanCountingUnobservedTime() public {
        feed.set(300000e8);
        _warm();
        hook.updateMilestone();
        _advance(1 hours);
        hook.updateMilestone();
        assertFalse(hook.fullyUnlocked());
        for (uint256 i; i < 11; ++i) {
            _advance(5 minutes);
            hook.updateMilestone();
        }
        assertFalse(hook.fullyUnlocked());
        _advance(5 minutes);
        hook.updateMilestone();
        assertTrue(hook.fullyUnlocked());
    }

    function testStaleCheckpointAndFeedPreventNewTierButNotTrades() public {
        _warm();
        _advance(301);
        vm.expectRevert(UnlkOracle.InvalidOracle.selector);
        oracle.fdvUsd();
        oracle.checkpoint();
        assertGt(oracle.fdvUsd(), 0);
        vm.warp(block.timestamp + 1 hours + 1);
        oracle.checkpoint();
        vm.expectRevert(UnlkOracle.InvalidOracle.selector);
        oracle.fdvUsd();
        assertFalse(hook.updateMilestone());
        assertEq(hook.p(), 2500);
        uint256 bought = _buy(alice, 1 ether);
        _sell(alice, bought / 4);
    }

    function testBadChainlinkRoundsAndAnswersFailClosed() public {
        _warm();
        feed.set(0);
        _invalid();
        feed.set(-1);
        _invalid();
        feed.set(2000e8);
        feed.setRound(2, block.timestamp, block.timestamp, 1);
        _invalid();
        feed.setRound(0, block.timestamp, block.timestamp, 0);
        _invalid();
        feed.setRound(2, block.timestamp, block.timestamp + 1, 2);
        _invalid();
        feed.setRound(2, block.timestamp + 1, block.timestamp, 2);
        _invalid();
        feed.setRound(2, 0, block.timestamp, 2);
        _invalid();
        feed.setRound(2, block.timestamp, 0, 2);
        _invalid();
        feed.setRound(2, block.timestamp, block.timestamp, 2);
        feed.setDecimals(19);
        _invalid();
        feed.setDecimals(8);
        feed.set(1_000_001e8);
        _invalid();
        feed.set(2000e8);
        feed.setBroken(true);
        _invalid();
    }

    function _invalid() internal {
        vm.expectRevert();
        oracle.fdvUsd();
        assertFalse(hook.updateMilestone());
        assertEq(hook.p(), 2500);
    }

    function testInvalidDataResetsUnfinishedConfirmation() public {
        feed.set(300000e8);
        _warm();
        hook.updateMilestone();
        _advance(5 minutes);
        hook.updateMilestone();
        assertGt(hook.qualifyingSince(5), 0);
        feed.setBroken(true);
        assertFalse(hook.updateMilestone());
        assertEq(hook.qualifyingSince(5), 0);
        feed.setBroken(false);
        hook.updateMilestone();
        for (uint256 i; i < 11; ++i) {
            _advance(5 minutes);
            hook.updateMilestone();
        }
        assertFalse(hook.fullyUnlocked());
        _advance(5 minutes);
        hook.updateMilestone();
        assertTrue(hook.fullyUnlocked());
    }

    function testEveryTierAndPermanentUnlock() public {
        uint256[6] memory targets = [uint256(120000), 300000, 600000, 1200000, 3000000, 6000000];
        uint16[6] memory ps = [uint16(3500), 4500, 5500, 7000, 8500, 10000];
        _warm();
        uint256 baseFdv = oracle.fdvUsd();
        for (uint256 i; i < targets.length; ++i) {
            feed.set(int256(2000e8 * targets[i] * 1 ether / baseFdv));
            _confirm();
            assertEq(hook.p(), ps[i]);
            assertEq(hook.tier(), i + 1);
        }
        assertTrue(hook.fullyUnlocked());
        feed.set(1);
        _advance(7 days);
        feed.setBroken(true);
        hook.updateMilestone();
        assertEq(hook.p(), 10000);
        assertTrue(hook.fullyUnlocked());
        vm.prank(payer);
        token.transfer(bob, 1_000_000 ether);
        assertEq(hook.eligible(bob), 0);
        _sell(bob, 1_000_000 ether);
        assertEq(hook.sold(bob), 1_000_000 ether);
    }

    function testFallingPricesNeverLowerReachedTier() public {
        feed.set(30000e8);
        _confirm();
        uint16 p = hook.p();
        assertGt(p, 2500);
        feed.set(1);
        _confirm();
        assertEq(hook.p(), p);
        assertFalse(hook.fullyUnlocked());
    }

    function testThresholdMappingBoundaries() public view {
        uint256[6] memory thresholds = [uint256(100000), 250000, 500000, 1000000, 2500000, 5000000];
        for (uint8 i; i < 6; ++i) {
            assertEq(hook.tierForFdv(thresholds[i] * 1 ether - 1), i);
            assertEq(hook.tierForFdv(thresholds[i] * 1 ether), i + 1);
        }
    }

    function testOracleCannotBeReboundOrConfiguredByAnyone() public {
        vm.prank(bob);
        vm.expectRevert(UnlkOracle.Unauthorized.selector);
        oracle.bind(key);
        vm.prank(address(hook));
        vm.expectRevert(UnlkOracle.Unauthorized.selector);
        oracle.bind(key);
        vm.prank(bob);
        vm.expectRevert(UnlkOracle.Unauthorized.selector);
        oracle.setLiquidityRange(-60, 60);
    }

    function testNegativeTickAveragesRoundConservativelyForBothOrders() public {
        _warm();
        _advance(1);
        _buy(alice, 0.1 ether);
        _advance(1);
        oracle.checkpoint();
        int24 average = oracle.twapTick();
        assertLe(average, -174999);
        assertGe(average, -175000);
    }
}

contract Token0OracleTest is OracleTest {
    function setUp() public override {
        _deploy(true);
        _initialize(-175000);
    }
}
