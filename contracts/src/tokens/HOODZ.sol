// SPDX-License-Identifier: AGPL-3.0-or-later
// UNAUDITED. Do not use in production without a full audit.
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

import {IHOODZ} from "../interfaces/IHOODZ.sol";
import {IHoodzAuthority} from "../interfaces/IHoodzAuthority.sol";
import {HoodzAccessControlled} from "../types/HoodzAccessControlled.sol";

/// @title  HOODZ
/// @notice The Hoodz reserve currency. 9 decimals, like OHM.
/// @dev    UNAUDITED. Do not use in production without a full audit.
///
///         PONS compatibility (BRIEF section 4): this token is deliberately minimal and
///         permissionless - no transfer tax, no blacklist, no pausable transfer, no hooks on
///         transfer. The only privileged action is minting, which is restricted to
///         `authority.vault()` (the Hoodz Treasury) and is expected to be handed over only after
///         the PONS bonding curve has graduated. Burning is fully permissionless.
contract HOODZ is IHOODZ, ERC20, ERC20Permit, HoodzAccessControlled {
    /* ======================================== CONSTANTS ======================================= */

    /// @dev HOODZ uses 9 decimals so that treasury accounting matches Olympus 1:1.
    uint8 private constant DECIMALS = 9;

    /* ======================================= CONSTRUCTOR ====================================== */

    /// @param _authority Address of the HoodzAuthority that names the minting vault.
    constructor(IHoodzAuthority _authority)
        ERC20("Hoodz", "HOODZ")
        ERC20Permit("Hoodz")
        HoodzAccessControlled(_authority)
    {}

    /* ========================================== VIEWS ========================================= */

    /// @notice Number of decimals used by HOODZ.
    /// @return Always 9.
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }

    /* ========================================= MUTATIVE ======================================= */

    /// @notice Mint new HOODZ. Restricted to the vault role (the Hoodz Treasury).
    /// @param account_ Recipient of the newly minted HOODZ.
    /// @param amount_  Amount to mint, 9 decimals.
    function mint(address account_, uint256 amount_) external override onlyVault {
        _mint(account_, amount_);
    }

    /// @notice Burn HOODZ held by the caller. Permissionless.
    /// @param amount_ Amount to burn, 9 decimals.
    function burn(uint256 amount_) external override {
        _burn(msg.sender, amount_);
    }

    /// @notice Burn HOODZ held by another account, debiting the caller allowance.
    /// @param account_ Account whose HOODZ is burned.
    /// @param amount_  Amount to burn, 9 decimals.
    function burnFrom(address account_, uint256 amount_) external override {
        _spendAllowance(account_, msg.sender, amount_);
        _burn(account_, amount_);
    }
}
