// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @dev UNAUDITED. Do not use in production without a full audit.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISwapRouter} from "../../src/pons/FeeRouterBuyback.sol";

/// @title  MockSwapRouter
/// @notice Fixed-rate {ISwapRouter}: the router facade in front of the permanently locked
///         Uniswap v4 pool that `FeeRouterBuyback` buys HOOD on before burning it.
/// @dev    The rate is set per direction and normalised for the two tokens' decimals, so a
///         reserve/HOOD pair (18 vs 9 decimals) behaves the way the real pool would. Output
///         inventory must be funded up front by the test - the mock never mints. {setPayoutBps}
///         lets a test under-deliver so the buyback's slippage guard can be exercised.
contract MockSwapRouter is ISwapRouter {
    using SafeERC20 for IERC20;

    /// @dev Whole `tokenOut` per whole `tokenIn`, 1e18 fixed point. 1e18 == parity.
    mapping(address tokenIn => mapping(address tokenOut => uint256 rate)) public rate;

    /// @notice Fraction of the quoted output actually delivered, in bps. 10_000 == honest fill.
    uint256 public payoutBps = 10_000;

    /// @notice Emitted on every fill.
    event Swapped(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    /// @notice Thrown when no rate is configured for the requested pair.
    error NoRate(address tokenIn, address tokenOut);
    /// @notice Thrown when the fill would be worse than the caller's slippage bound.
    error InsufficientOutput(uint256 amountOut, uint256 minimum);
    /// @notice Thrown when the router does not hold enough output inventory.
    error InsufficientInventory(uint256 available, uint256 required);
    /// @notice Thrown when `block.timestamp` is past the caller's deadline.
    error Expired();

    /// @notice Sets the fixed rate for one direction of a pair.
    /// @param tokenIn_ Input token.
    /// @param tokenOut_ Output token.
    /// @param rate_ Whole output per whole input, 1e18 fixed point.
    function setRate(address tokenIn_, address tokenOut_, uint256 rate_) external {
        rate[tokenIn_][tokenOut_] = rate_;
    }

    /// @notice Makes the router deliver less than it quotes, to exercise slippage guards.
    /// @param payoutBps_ Fraction of the quote actually paid, in bps.
    function setPayoutBps(uint256 payoutBps_) external {
        payoutBps = payoutBps_;
    }

    /// @notice Quotes a fill without executing it.
    /// @param tokenIn_ Input token.
    /// @param tokenOut_ Output token.
    /// @param amountIn_ Input amount, in raw units.
    /// @return amountOut The output amount, in raw units, after {payoutBps}.
    function quote(address tokenIn_, address tokenOut_, uint256 amountIn_) public view returns (uint256 amountOut) {
        uint256 r = rate[tokenIn_][tokenOut_];
        if (r == 0) revert NoRate(tokenIn_, tokenOut_);

        uint256 decIn = IERC20Metadata(tokenIn_).decimals();
        uint256 decOut = IERC20Metadata(tokenOut_).decimals();

        amountOut = (amountIn_ * r * (10 ** decOut)) / (1e18 * (10 ** decIn));
        amountOut = (amountOut * payoutBps) / 10_000;
    }

    /// @inheritdoc ISwapRouter
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        override
        returns (uint256 amountOut)
    {
        if (params.deadline != 0 && block.timestamp > params.deadline) revert Expired();

        amountOut = quote(params.tokenIn, params.tokenOut, params.amountIn);
        if (amountOut < params.amountOutMinimum) revert InsufficientOutput(amountOut, params.amountOutMinimum);

        uint256 inventory = IERC20(params.tokenOut).balanceOf(address(this));
        if (inventory < amountOut) revert InsufficientInventory(inventory, amountOut);

        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
        IERC20(params.tokenOut).safeTransfer(params.recipient, amountOut);

        emit Swapped(params.tokenIn, params.tokenOut, params.amountIn, amountOut);
    }
}
