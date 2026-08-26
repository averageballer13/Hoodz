// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @dev UNAUDITED. Do not use in production without a full audit.

/// @title IPonsBondingCurve
/// @notice Minimal integration surface for the PONS V2 bonding curve escrow.
/// @dev Every PONS launch trades on one of these until graduation. The curve is the only holder of
///      the sellable supply pre-graduation, quotes are deterministic in the reserve token, and there
///      is no LP to rug: reserves can only leave the curve through {IPonsBondingCurve-sell} or through
///      graduation into the permanently locked Uniswap v4 pool.
///
///      Hoodz does not trade on the curve from a contract - the launch is bootstrapped by wallets
///      signing their own transactions. This interface exists so the protocol (and the launch guard)
///      can *read* the curve state on-chain rather than trusting an off-chain claim.
interface IPonsBondingCurve {
    /// @notice Emitted on every curve purchase.
    event Buy(address indexed buyer, uint256 reserveIn, uint256 amountOut, uint256 newSpotPrice);

    /// @notice Emitted on every curve sale.
    event Sell(address indexed seller, uint256 amountIn, uint256 reserveOut, uint256 newSpotPrice);

    /// @notice Emitted once, when the curve is closed and its reserves migrate to the locked v4 pool.
    event Graduation(address indexed pool, uint256 reserveMigrated, uint256 supplyMigrated);

    /// @notice Buy the launched token from the curve.
    /// @dev The reserve amount in is `msg.value` when the reserve token is the chain's native asset,
    ///      otherwise the curve pulls the caller's pre-approved reserve allowance. Always pass a real
    ///      `minAmountOut`: the curve price moves with every trade in the same block.
    /// @param minAmountOut Minimum acceptable amount of launched token, slippage guard.
    /// @return amountOut Launched tokens delivered to the caller.
    function buy(uint256 minAmountOut) external payable returns (uint256 amountOut);

    /// @notice Sell the launched token back into the curve.
    /// @param amountIn Amount of launched token to sell.
    /// @param minAmountOut Minimum acceptable amount of reserve token, slippage guard.
    /// @return reserveOut Reserve tokens returned to the caller.
    function sell(uint256 amountIn, uint256 minAmountOut) external returns (uint256 reserveOut);

    /// @notice Reserve token currently escrowed by the curve.
    /// @return The curve's reserve balance, in reserve token decimals.
    function reserves() external view returns (uint256);

    /// @notice Launched tokens sold out of the curve so far.
    /// @return The cumulative net supply sold, in launched-token decimals.
    function supplySold() external view returns (uint256);

    /// @notice Reserve balance at which the curve becomes graduatable.
    /// @return The graduation threshold, in reserve token decimals.
    function graduationThreshold() external view returns (uint256);

    /// @notice Whether this curve has already migrated into the locked Uniswap v4 pool.
    /// @return True after graduation; the curve is closed to trading from that point on.
    function graduated() external view returns (bool);

    /// @notice Instantaneous marginal price of the launched token.
    /// @return Price of one whole launched token, expressed in reserve token units, scaled by 1e18.
    function spotPrice() external view returns (uint256);

    /// @notice The token being launched on this curve.
    /// @return The launched ERC20.
    function token() external view returns (address);

    /// @notice The quote asset collected by this curve.
    /// @return The reserve ERC20, or `address(0)` if the curve quotes in the native asset.
    function reserveToken() external view returns (address);
}
