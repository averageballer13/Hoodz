// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @dev UNAUDITED. Do not use in production without a full audit.

/// @title IBondingCalculator
/// @notice Values liquidity-pool tokens held by the Hoodz Treasury in 9-decimal HOODZ terms.
/// @dev The Hoodz Treasury stores one calculator per registered `LIQUIDITYTOKEN`.
interface IBondingCalculator {
    /// @notice Risk-free value of `amount_` LP shares of `pair_`, denominated in HOODZ (9 decimals).
    /// @param pair_ Address of the constant-product LP token.
    /// @param amount_ Amount of LP shares to value.
    /// @return value_ Risk-free valuation in HOODZ terms.
    function valuation(address pair_, uint256 amount_) external view returns (uint256 value_);

    /// @notice Ratio of the non-HOODZ side of an LP position to its risk-free value.
    /// @dev Used to mark a liquidity position down to the value the protocol can actually defend.
    /// @param _LP Address of the constant-product LP token.
    /// @return The markdown factor, scaled to HOODZ's 9 decimals.
    function markdown(address _LP) external view returns (uint256);
}
