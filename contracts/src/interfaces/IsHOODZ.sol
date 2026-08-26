// SPDX-License-Identifier: AGPL-3.0-or-later
// UNAUDITED. Do not use in production without a full audit.
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title  IsHOODZ
/// @notice The rebasing staked-HOODZ receipt token (9 decimals). Balances are stored as "gons",
///         a fixed share of a constant total, so a rebase is a single division update.
/// @dev    UNAUDITED. Do not use in production without a full audit.
interface IsHOODZ is IERC20 {
    /// @notice Increase the total supply by profit_, distributing it pro-rata to every holder.
    /// @dev    Callable only by the staking contract, once per epoch.
    /// @param profit_ Amount of HOODZ (9 decimals) added to the staked pool this epoch.
    /// @param epoch_  Epoch number the rebase belongs to.
    /// @return The new total supply of sHOODZ.
    function rebase(uint256 profit_, uint256 epoch_) external returns (uint256);

    /// @notice Supply held outside the staking contract, including the sHOODZ wrapped as gHOODZ.
    /// @return The circulating sHOODZ supply, 9 decimals.
    function circulatingSupply() external view returns (uint256);

    /// @notice Convert an sHOODZ amount into gons at the current rate.
    /// @param amount_ sHOODZ amount, 9 decimals.
    /// @return The equivalent number of gons.
    function gonsForBalance(uint256 amount_) external view returns (uint256);

    /// @notice Convert gons into an sHOODZ amount at the current rate.
    /// @param gons_ Number of gons.
    /// @return The equivalent sHOODZ amount, 9 decimals.
    function balanceForGons(uint256 gons_) external view returns (uint256);

    /// @notice Growth-adjusted index: what one sHOODZ staked at genesis is worth today.
    /// @return The index, 9 decimals.
    function index() external view returns (uint256);

    /// @notice Convert an sHOODZ amount (9 decimals) into gHOODZ terms (18 decimals).
    /// @param amount_ sHOODZ amount.
    /// @return The equivalent gHOODZ amount.
    function toG(uint256 amount_) external view returns (uint256);

    /// @notice Convert a gHOODZ amount (18 decimals) into sHOODZ terms (9 decimals).
    /// @param amount_ gHOODZ amount.
    /// @return The equivalent sHOODZ amount.
    function fromG(uint256 amount_) external view returns (uint256);
}
