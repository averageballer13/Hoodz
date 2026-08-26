// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @dev UNAUDITED. Do not use in production without a full audit.

/// @title IUniswapV2ERC20
/// @notice Minimal view of the ERC20 surface exposed by a Uniswap V2 style LP share token.
/// @dev Declared locally (rather than imported) so Hoodz carries no Uniswap dependency.
///      Only the members the Hoodz bonding calculator and treasury need are declared.
interface IUniswapV2ERC20 {
    /// @notice Emitted on `approve`.
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @notice Emitted on `transfer` / `transferFrom` and on LP mint/burn.
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @notice Human readable name of the LP token.
    /// @return The token name.
    function name() external view returns (string memory);

    /// @notice Ticker of the LP token.
    /// @return The token symbol.
    function symbol() external view returns (string memory);

    /// @notice Fixed-point precision of the LP token (18 for Uniswap V2 pairs).
    /// @return The number of decimals.
    function decimals() external view returns (uint8);

    /// @notice Total LP shares in circulation.
    /// @dev Used as the denominator when valuing an LP position.
    /// @return The total supply.
    function totalSupply() external view returns (uint256);

    /// @notice LP share balance of an account.
    /// @param owner Account to query.
    /// @return The balance of `owner`.
    function balanceOf(address owner) external view returns (uint256);

    /// @notice Remaining allowance granted by `owner` to `spender`.
    /// @param owner Account that granted the allowance.
    /// @param spender Account allowed to spend.
    /// @return The remaining allowance.
    function allowance(address owner, address spender) external view returns (uint256);

    /// @notice Approve `spender` to move `value` LP shares.
    /// @param spender Account to approve.
    /// @param value Allowance to set.
    /// @return True on success.
    function approve(address spender, uint256 value) external returns (bool);

    /// @notice Move `value` LP shares to `to`.
    /// @param to Recipient.
    /// @param value Amount to move.
    /// @return True on success.
    function transfer(address to, uint256 value) external returns (bool);

    /// @notice Move `value` LP shares from `from` to `to` using the caller's allowance.
    /// @param from Owner of the shares.
    /// @param to Recipient.
    /// @param value Amount to move.
    /// @return True on success.
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}
