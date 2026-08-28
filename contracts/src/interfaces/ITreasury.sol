// SPDX-License-Identifier: AGPL-3.0-or-later
// UNAUDITED. Do not use in production without a full audit.
pragma solidity ^0.8.24;

/*
        ██╗  ██╗ ██████╗  ██████╗ ██████╗ ███████╗
        ██║  ██║██╔═══██╗██╔═══██╗██╔══██╗╚══███╔╝
        ███████║██║   ██║██║   ██║██║  ██║  ███╔╝
        ██╔══██║██║   ██║██║   ██║██║  ██║ ███╔╝
        ██║  ██║╚██████╔╝╚██████╔╝██████╔╝███████╗
        ╚═╝  ╚═╝ ╚═════╝  ╚═════╝ ╚═════╝ ╚══════╝

        A treasury-backed reserve currency for Robinhood Chain.
        Fixed supply, launched on PONS. Staking is paid out of real
        trading fees, never out of new supply - there is no mint.

        Web    https://hoodz.finance
        X      https://x.com/Hoodzfinance
        Code   https://github.com/averageballer13/Hoodz

        UNAUDITED. This code has never been audited. Read it before you
        trust it with anything you would miss.
*/

/// @title  ITreasury
/// @notice The Hoodz Treasury: holds the reserve assets that back HOOD and mints against them.
/// @dev    UNAUDITED. Do not use in production without a full audit.
interface ITreasury {
    /// @notice Deposit a reserve or liquidity token and mint HOOD against its value.
    /// @param amount_   Amount of token_ deposited, in the token own decimals.
    /// @param token_    Address of the deposited reserve/liquidity token.
    /// @param profit_   Value (9 decimals) retained by the treasury instead of being minted.
    /// @return The amount of HOOD minted to the depositor, 9 decimals.
    function deposit(uint256 amount_, address token_, uint256 profit_) external returns (uint256);

    /// @notice Burn HOOD from the caller and withdraw the matching amount of a reserve token.
    /// @param amount_ Amount of token_ to withdraw, in the token own decimals.
    /// @param token_  Address of the reserve token to withdraw.
    function withdraw(uint256 amount_, address token_) external;

    /// @notice Mint HOOD from treasury excess reserves. Restricted to approved minters.
    /// @param recipient_ Recipient of the newly minted HOOD.
    /// @param amount_    Amount of HOOD to mint, 9 decimals.
    function payout(address recipient_, uint256 amount_) external;

    /// @notice HOOD held by the treasury and available to pay out.
    /// @return The treasury's HOOD balance, 9 decimals.
    function inventory() external view returns (uint256);

    /// @notice Borrow a reserve token out of the treasury against the caller debt allowance.
    /// @param token_  Address of the managed token.
    /// @param amount_ Amount to withdraw, in the token own decimals.
    function manage(address token_, uint256 amount_) external;

    /// @notice Value of an amount of a reserve/liquidity token, expressed in HOOD terms.
    /// @param token_  Address of the token to price.
    /// @param amount_ Amount of token_, in the token own decimals.
    /// @return The value in HOOD, 9 decimals.
    function tokenValue(address token_, uint256 amount_) external view returns (uint256);

    /// @notice HOOD supply used as the base for backing calculations.
    /// @return The base supply, 9 decimals.
    function baseSupply() external view returns (uint256);

    /// @notice Reserves held above the amount required to back the circulating HOOD supply.
    /// @return The excess reserves, 9 decimals.
    function excessReserves() external view returns (uint256);
}
