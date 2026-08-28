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

/// @title  IsHOOD
/// @notice The rebasing staked-HOOD receipt token (9 decimals). Balances are stored as "gons",
///         a fixed share of a constant total, so a rebase is a single division update.
/// @dev    UNAUDITED. Do not use in production without a full audit.
interface IsHOOD is IERC20 {
    /// @notice Increase the total supply by profit_, distributing it pro-rata to every holder.
    /// @dev    Callable only by the staking contract, once per epoch.
    /// @param profit_ Amount of HOOD (9 decimals) added to the staked pool this epoch.
    /// @param epoch_  Epoch number the rebase belongs to.
    /// @return The new total supply of sHOOD.
    function rebase(uint256 profit_, uint256 epoch_) external returns (uint256);

    /// @notice Supply held outside the staking contract, including the sHOOD wrapped as gHOOD.
    /// @return The circulating sHOOD supply, 9 decimals.
    function circulatingSupply() external view returns (uint256);

    /// @notice Convert an sHOOD amount into gons at the current rate.
    /// @param amount_ sHOOD amount, 9 decimals.
    /// @return The equivalent number of gons.
    function gonsForBalance(uint256 amount_) external view returns (uint256);

    /// @notice Convert gons into an sHOOD amount at the current rate.
    /// @param gons_ Number of gons.
    /// @return The equivalent sHOOD amount, 9 decimals.
    function balanceForGons(uint256 gons_) external view returns (uint256);

    /// @notice Growth-adjusted index: what one sHOOD staked at genesis is worth today.
    /// @return The index, 9 decimals.
    function index() external view returns (uint256);

    /// @notice Convert an sHOOD amount (9 decimals) into gHOOD terms (18 decimals).
    /// @param amount_ sHOOD amount.
    /// @return The equivalent gHOOD amount.
    function toG(uint256 amount_) external view returns (uint256);

    /// @notice Convert a gHOOD amount (18 decimals) into sHOOD terms (9 decimals).
    /// @param amount_ gHOOD amount.
    /// @return The equivalent sHOOD amount.
    function fromG(uint256 amount_) external view returns (uint256);
}
