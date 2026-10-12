// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IUnlkHookView} from "./interfaces/IIntegration.sol";
import {OperationHash} from "./libraries/OperationHash.sol";

/// @notice Direct-call route with exact caller sourcing and delivery. No relayed/signed intentions. Native ETH uses the canonical v4 zero-currency sentinel.
contract UnlkSwapRouter is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    IPoolManager public immutable poolManager;
    address public immutable setupAuthority;
    IUnlkHookView public hook;
    uint256 public nonce;
    mapping(address => uint256) public nativeCredit;
    uint256 public totalNativeCredit;
    address private activeTrader;
    bytes32 private activeOperation;
    bool private callbackExpected;

    struct SwapRequest {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
        uint256 maxInput;
        uint256 minOutput;
        uint256 deadline;
    }

    struct Settlement {
        IERC20 inputToken;
        IERC20 outputToken;
        uint256 baseInput;
        uint256 baseOutput;
        bool nativeInput;
        bool nativeOutput;
    }

    error Unauthorized();
    error InvalidConfig();
    error InvalidSwap();
    error Slippage();
    error SettlementMismatch();
    event NativeCredit(address indexed recipient, uint256 amount);
    event NativeWithdrawn(address indexed recipient, uint256 amount);
    event HookConfigured(address indexed hook);
    event Executed(address indexed trader, uint256 indexed nonce, uint256 input, uint256 output);

    constructor(IPoolManager manager_, address setupAuthority_) {
        if (address(manager_) == address(0) || setupAuthority_ == address(0)) revert InvalidConfig();
        poolManager = manager_;
        setupAuthority = setupAuthority_;
    }

    function configureHook(IUnlkHookView hook_) external {
        if (msg.sender != setupAuthority || address(hook) != address(0)) revert Unauthorized();
        // Predicted CREATE2 address: the factory deploys the hook later in its launch transaction, and the
        // hook verifies `router.hook() == this` before binding the pool. Reads fail closed until then.
        if (address(hook_) == address(0)) revert InvalidConfig();
        hook = hook_;
        emit HookConfigured(address(hook_));
    }

    function context() external view returns (address trader, bytes32 operation) {
        return (activeTrader, activeOperation);
    }

    function swap(SwapRequest calldata request)
        external
        payable
        nonReentrant
        returns (uint256 input, uint256 output)
    {
        return _swap(request, msg.value);
    }

    /// @notice Sequential official-pool trades, each fully settled and delivered before the next.
    /// Generic multihop and caller-selected recipients/pools are intentionally unsupported.
    function swapBatch(SwapRequest[] calldata requests)
        external
        payable
        nonReentrant
        returns (uint256[] memory inputs, uint256[] memory outputs)
    {
        if (requests.length == 0 || requests.length > 16) revert InvalidSwap();
        if (address(hook) == address(0) || !hook.bound()) revert InvalidSwap();
        PoolKey memory key = hook.poolKey();
        uint256 requiredValue = 0;
        for (uint256 i = 0; i < requests.length; ++i) {
            if (Currency.unwrap(requests[i].zeroForOne ? key.currency0 : key.currency1) == address(0)) {
                requiredValue += requests[i].maxInput;
            }
        }
        if (msg.value != requiredValue) revert InvalidSwap();
        inputs = new uint256[](requests.length);
        outputs = new uint256[](requests.length);
        for (uint256 i = 0; i < requests.length; ++i) {
            uint256 value = Currency.unwrap(requests[i].zeroForOne ? key.currency0 : key.currency1)
                == address(0)
                ? requests[i].maxInput
                : 0;
            (inputs[i], outputs[i]) = _swap(requests[i], value);
        }
    }

    function _swap(SwapRequest calldata request, uint256 nativeValue)
        private
        returns (uint256 input, uint256 output)
    {
        if (
            address(hook) == address(0) || !hook.bound() || block.timestamp > request.deadline
                || request.amountSpecified == 0 || request.amountSpecified == type(int256).min
                || request.maxInput == 0 || request.maxInput > uint256(uint128(type(int128).max))
                || request.minOutput == 0
        ) revert InvalidSwap();
        PoolKey memory key = hook.poolKey();
        Settlement memory state;
        state.inputToken = IERC20(Currency.unwrap(request.zeroForOne ? key.currency0 : key.currency1));
        state.outputToken = IERC20(Currency.unwrap(request.zeroForOne ? key.currency1 : key.currency0));
        state.nativeInput = address(state.inputToken) == address(0);
        state.nativeOutput = address(state.outputToken) == address(0);
        if (state.nativeInput ? nativeValue != request.maxInput : nativeValue != 0) revert InvalidSwap();
        state.baseInput = state.nativeInput
            ? address(this).balance - nativeValue
            : state.inputToken.balanceOf(address(this));
        state.baseOutput =
            state.nativeOutput ? address(this).balance : state.outputToken.balanceOf(address(this));
        // Critical: the only transferFrom is sourced literally from msg.sender at the public entry.
        // Callback parameters can NEVER select another wallet, even if it granted an allowance.
        if (!state.nativeInput) {
            state.inputToken.safeTransferFrom(msg.sender, address(this), request.maxInput);
            if (state.inputToken.balanceOf(address(this)) != state.baseInput + request.maxInput) {
                revert SettlementMismatch();
            }
        }
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams(request.zeroForOne, request.amountSpecified, request.sqrtPriceLimitX96);
        uint256 operationNonce = ++nonce;
        activeTrader = msg.sender;
        activeOperation = OperationHash.hash(key, params, msg.sender, operationNonce);
        callbackExpected = true;
        bytes memory result = poolManager.unlock(abi.encode(key, params, operationNonce, request.maxInput));
        if (callbackExpected) revert SettlementMismatch();
        (input, output) = abi.decode(result, (uint256, uint256));
        delete activeTrader;
        delete activeOperation;
        if (input > request.maxInput || output < request.minOutput) revert Slippage();
        // Exact output must be completely filled. Exact input may partially fill at the price limit;
        // only actual input is sold/charged and the unused prefund is returned.
        if (request.amountSpecified > 0 && output != uint256(request.amountSpecified)) revert Slippage();
        if (
            _balance(state.inputToken) != state.baseInput + request.maxInput - input
                || _balance(state.outputToken) != state.baseOutput + output
        ) revert SettlementMismatch();
        if (state.nativeOutput) {
            _creditNative(output);
        } else {
            uint256 outputBefore = state.outputToken.balanceOf(msg.sender);
            state.outputToken.safeTransfer(msg.sender, output);
            if (state.outputToken.balanceOf(msg.sender) != outputBefore + output) {
                revert SettlementMismatch();
            }
        }
        if (request.maxInput > input) {
            if (state.nativeInput) _creditNative(request.maxInput - input);
            else state.inputToken.safeTransfer(msg.sender, request.maxInput - input);
        }
        emit Executed(msg.sender, operationNonce, input, output);
    }

    receive() external payable {
        if (msg.sender != address(poolManager)) revert Unauthorized();
    }

    function _balance(IERC20 currency) private view returns (uint256) {
        return address(currency) == address(0) ? address(this).balance : currency.balanceOf(address(this));
    }

    function _creditNative(uint256 amount) private {
        nativeCredit[msg.sender] += amount;
        totalNativeCredit += amount;
        emit NativeCredit(msg.sender, amount);
    }

    /// @notice Withdraw only your settled native proceeds/refunds. Effects precede the sole ETH call.
    /// No recipient argument, arbitrary payer, or cross-wallet withdrawal exists. A rejecting wallet can retry.
    function withdrawNative() external {
        uint256 amount = nativeCredit[msg.sender];
        if (amount == 0) return;
        nativeCredit[msg.sender] = 0;
        totalNativeCredit -= amount;
        emit NativeWithdrawn(msg.sender, amount);
        (bool success,) = payable(msg.sender).call{value: amount}("");
        if (!success) revert SettlementMismatch();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || !callbackExpected || activeTrader == address(0)) {
            revert Unauthorized();
        }
        callbackExpected = false;
        (
            PoolKey memory key,
            IPoolManager.SwapParams memory params,
            uint256 operationNonce,
            uint256 maxInput
        ) = abi.decode(data, (PoolKey, IPoolManager.SwapParams, uint256, uint256));
        if (activeOperation != OperationHash.hash(key, params, activeTrader, operationNonce)) {
            revert Unauthorized();
        }
        BalanceDelta delta = poolManager.swap(key, params, abi.encode(operationNonce));
        int128 inDelta = params.zeroForOne ? delta.amount0() : delta.amount1();
        int128 outDelta = params.zeroForOne ? delta.amount1() : delta.amount0();
        if (inDelta >= 0 || outDelta <= 0) revert InvalidSwap();
        uint256 input = uint256(-int256(inDelta));
        uint256 output = uint256(uint128(outDelta));
        if (input > maxInput) revert Slippage();
        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        Currency outputCurrency = params.zeroForOne ? key.currency1 : key.currency0;
        if (Currency.unwrap(inputCurrency) == address(0)) {
            // Reset transient reserves left by any earlier sync in this transaction.
            poolManager.sync(inputCurrency);
            if (poolManager.settle{value: input}() != input) revert SettlementMismatch();
        } else {
            poolManager.sync(inputCurrency);
            IERC20(Currency.unwrap(inputCurrency)).safeTransfer(address(poolManager), input);
            if (poolManager.settle() != input) revert SettlementMismatch();
        }
        poolManager.take(outputCurrency, address(this), output);
        return abi.encode(input, output);
    }
}
