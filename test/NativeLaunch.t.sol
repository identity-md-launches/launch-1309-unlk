// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {SystemFixture} from "./fixtures/SystemFixture.sol";
import {UnlkSwapRouter} from "../src/UnlkSwapRouter.sol";
import {UnlkOracle} from "../src/UnlkOracle.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract NativeLaunchTest is SystemFixture {
    using StateLibrary for IPoolManager;
    int24 constant NATIVE_LOWER = 120000;
    int24 constant NATIVE_UPPER = 175020;

    function _quoteAddress() internal pure override returns (address) {
        return address(0);
    }

    function setUp() public override {
        _deploy(false);
        uint160 upper = TickMath.getSqrtPriceAtTick(NATIVE_UPPER);
        uint160 lower = TickMath.getSqrtPriceAtTick(NATIVE_LOWER);
        factory.initialize(manager, key, upper);
        uint128 liquidity = uint128(Math.mulDiv(token.POOL_ALLOCATION(), 1 << 96, upper - lower));
        factory.seedNative(vault, liquidity, NATIVE_LOWER, NATIVE_UPPER);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _nativeBuy(uint256 amount) internal returns (uint256 output) {
        vm.prank(alice);
        (, output) = router.swap{value: amount}(_request(true, -int256(amount), amount));
    }

    function testOneSidedOpeningLocks87PercentWithoutEthFunding() public view {
        assertEq(vault.initialQuoteUsed(), 0);
        assertEq(address(vault).balance, 0);
        assertApproxEqAbs(vault.initialTokenUsed(), token.POOL_ALLOCATION(), 1e9);
        assertEq(address(manager).balance, 0);
    }

    function testNativeBuySellAndFeeDistribution() public {
        uint256 bought = _nativeBuy(1 ether);
        assertEq(hook.eligible(alice), bought);
        assertEq(alice.balance, 99 ether);
        uint256 nativeBefore = alice.balance;
        uint256 output = _sell(alice, bought / 4);
        assertEq(alice.balance, nativeBefore);
        assertEq(router.nativeCredit(alice), output);
        vm.prank(alice);
        router.withdrawNative();
        assertEq(alice.balance - nativeBefore, output);
        assertEq(address(router).balance, 0);
        (uint256 f0,) = vault.collectFees();
        assertEq(fees.nativeClaim(payer), f0 * 4 / 5);
        assertEq(fees.nativeClaim(imd), f0 - f0 * 4 / 5);
        vm.prank(payer);
        fees.withdrawNative();
        assertEq(payer.balance, f0 * 4 / 5);
    }

    function testNativeExactOutputRefundToAuthenticatedCaller() public {
        vm.prank(alice);
        (uint256 input, uint256 output) =
            router.swap{value: 1 ether}(_request(true, int256(1000 ether), 1 ether));
        assertEq(output, 1000 ether);
        assertLt(input, 1 ether);
        assertEq(router.nativeCredit(alice), 1 ether - input);
        vm.prank(alice);
        router.withdrawNative();
        assertEq(alice.balance, 100 ether - input);
        assertEq(address(router).balance, 0);
    }

    function testNativeValueMismatchAndUnsolicitedSendRejected() public {
        vm.prank(alice);
        vm.expectRevert(UnlkSwapRouter.InvalidSwap.selector);
        router.swap{value: 1 wei}(_request(true, -int256(1 ether), 1 ether));
        vm.prank(alice);
        (bool ok,) = address(router).call{value: 1}("");
        assertFalse(ok);
    }

    function testNativeBatchSettlement() public {
        UnlkSwapRouter.SwapRequest[] memory steps = new UnlkSwapRouter.SwapRequest[](3);
        steps[0] = _request(true, int256(1000 ether), 1 ether);
        steps[1] = _request(true, int256(1000 ether), 1 ether);
        steps[2] = _request(false, -int256(500 ether), 500 ether);
        vm.prank(alice);
        router.swapBatch{value: 2 ether}(steps);
        assertEq(hook.eligible(alice), 2000 ether);
        assertEq(hook.sold(alice), 500 ether);
        assertEq(address(router).balance, router.totalNativeCredit());
        vm.prank(alice);
        router.withdrawNative();
        assertEq(address(router).balance, 0);
    }

    function testThinLaunchCannotUnlockFromInitialSpotOrTinyBuy() public {
        feed.set(300000e8);
        _confirm();
        assertFalse(hook.fullyUnlocked());
        _nativeBuy(0.001 ether);
        _confirm();
        assertFalse(hook.fullyUnlocked());
        vm.expectRevert(UnlkOracle.InvalidOracle.selector);
        oracle.fdvUsd();
    }

    function testDeepNativePoolWarmsUpAndCanUnlock() public {
        _nativeBuy(15 ether);
        feed.set(300000e8);
        _confirm();
        assertTrue(hook.fullyUnlocked());
        vm.prank(payer);
        token.transfer(bob, 1000 ether);
        assertEq(hook.eligible(bob), 0);
        _sell(bob, 1000 ether);
        assertEq(hook.sold(bob), 1000 ether);
    }
}

contract NativeWallet {
    UnlkSwapRouter immutable router;
    address immutable owner;
    bool public reject;
    bool public reenter;
    uint256 public received;

    constructor(UnlkSwapRouter router_, address owner_) {
        router = router_;
        owner = owner_;
    }

    function setMode(bool reject_, bool reenter_) external {
        require(msg.sender == owner);
        reject = reject_;
        reenter = reenter_;
    }

    function trade(UnlkSwapRouter.SwapRequest calldata request) external payable {
        require(msg.sender == owner);
        router.swap{value: msg.value}(request);
    }

    function approveToken(address currency, uint256 amount) external {
        require(msg.sender == owner);
        (bool ok, bytes memory result) =
            currency.call(abi.encodeWithSignature("approve(address,uint256)", address(router), amount));
        require(ok && abi.decode(result, (bool)));
    }

    function withdraw() external {
        require(msg.sender == owner);
        router.withdrawNative();
    }

    receive() external payable {
        require(!reject, "fixture rejects ETH");
        received += msg.value;
        if (reenter) router.withdrawNative();
    }
}

contract DirtySyncCaller {
    function buyAfterSync(
        IPoolManager manager,
        UnlkSwapRouter router,
        address dirtyCurrency,
        UnlkSwapRouter.SwapRequest calldata request
    ) external payable {
        manager.sync(Currency.wrap(dirtyCurrency));
        router.swap{value: msg.value}(request);
    }
}

contract NativeWithdrawalTest is NativeLaunchTest {
    function testNativeSettlementResetsPriorSyncCurrency() public {
        DirtySyncCaller caller = new DirtySyncCaller();
        vm.prank(alice);
        caller.buyAfterSync{value: 1 ether}(
            manager, router, address(weth), _request(true, -int256(1 ether), 1 ether)
        );
        assertGt(hook.eligible(address(caller)), 0);
        assertEq(token.balanceOf(address(caller)), hook.eligible(address(caller)));
    }

    function testNativeWithdrawalUsesCEIAndCannotDoubleWithdraw() public {
        NativeWallet wallet = new NativeWallet(router, alice);
        vm.startPrank(alice);
        wallet.trade{value: 1 ether}(_request(true, int256(1000 ether), 1 ether));
        uint256 credit = router.nativeCredit(address(wallet));
        assertGt(credit, 0);
        wallet.setMode(false, true);
        wallet.withdraw();
        vm.stopPrank();
        assertEq(wallet.received(), credit);
        assertEq(router.nativeCredit(address(wallet)), 0);
        assertEq(router.totalNativeCredit(), 0);
        assertEq(address(router).balance, 0);
    }

    function testRejectingNativeWalletCanTradeAndRetryWithdrawal() public {
        NativeWallet wallet = new NativeWallet(router, alice);
        vm.startPrank(alice);
        wallet.setMode(true, false);
        wallet.trade{value: 1 ether}(_request(true, int256(1000 ether), 1 ether));
        uint256 credit = router.nativeCredit(address(wallet));
        assertEq(hook.eligible(address(wallet)), 1000 ether);
        vm.expectRevert(UnlkSwapRouter.SettlementMismatch.selector);
        wallet.withdraw();
        assertEq(router.nativeCredit(address(wallet)), credit);
        wallet.setMode(false, false);
        wallet.withdraw();
        vm.stopPrank();
        assertEq(router.nativeCredit(address(wallet)), 0);
        assertEq(wallet.received(), credit);
    }

    function testOtherWalletCannotWithdrawNativeRefund() public {
        vm.prank(alice);
        router.swap{value: 1 ether}(_request(true, int256(1000 ether), 1 ether));
        uint256 credit = router.nativeCredit(alice);
        vm.prank(bob);
        router.withdrawNative();
        assertEq(router.nativeCredit(alice), credit);
        assertEq(router.totalNativeCredit(), credit);
        assertEq(address(router).balance, credit);
    }
}
