// SPDX-License-Identifier: AGPL-3.0-or-later
// UNAUDITED. Do not use in production without a full audit.
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title  IHOODZ
/// @notice The HOODZ reserve currency: a clean, permissionless ERC20 (9 decimals) whose supply is
///         minted exclusively by the Hoodz Treasury, i.e. authority.vault().
/// @dev    UNAUDITED. Do not use in production without a full audit.
interface IHOODZ is IERC20 {
    /// @notice Mint new HOODZ. Restricted to authority.vault().
    /// @param account_ Recipient of the newly minted HOODZ.
    /// @param amount_  Amount to mint, in HOODZ wei (9 decimals).
    function mint(address account_, uint256 amount_) external;

    /// @notice Burn HOODZ held by the caller.
    /// @param amount_ Amount to burn, in HOODZ wei (9 decimals).
    function burn(uint256 amount_) external;

    /// @notice Burn HOODZ held by account_, debiting the caller allowance.
    /// @param account_ Account whose HOODZ is burned.
    /// @param amount_  Amount to burn, in HOODZ wei (9 decimals).
    function burnFrom(address account_, uint256 amount_) external;
}
