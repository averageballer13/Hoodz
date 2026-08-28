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

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title  IgHOOD
/// @notice The non-rebasing, index-adjusted governance wrapper around sHOOD (18 decimals).
/// @dev    UNAUDITED. Do not use in production without a full audit.
interface IgHOOD is IERC20 {
    /// @notice Mint gHOOD. Restricted to the staking contract.
    /// @param to_     Recipient.
    /// @param amount_ gHOOD amount, 18 decimals.
    function mint(address to_, uint256 amount_) external;

    /// @notice Burn gHOOD. Restricted to the staking contract.
    /// @param from_   Account to burn from.
    /// @param amount_ gHOOD amount, 18 decimals.
    function burn(address from_, uint256 amount_) external;

    /// @notice The current sHOOD index this wrapper is denominated against.
    /// @return The index, 9 decimals.
    function index() external view returns (uint256);

    /// @notice Convert gHOOD into the sHOOD amount it currently represents.
    /// @param amount_ gHOOD amount, 18 decimals.
    /// @return The equivalent sHOOD amount, 9 decimals.
    function balanceFrom(uint256 amount_) external view returns (uint256);

    /// @notice Convert sHOOD into the gHOOD amount it currently represents.
    /// @param amount_ sHOOD amount, 9 decimals.
    /// @return The equivalent gHOOD amount, 18 decimals.
    function balanceTo(uint256 amount_) external view returns (uint256);
}
