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

import {IHoodzAuthority} from "../interfaces/IHoodzAuthority.sol";

/// @title  HoodzAccessControlled
/// @notice Base contract every Hoodz module inherits to read its roles from a single
///         HoodzAuthority instance. Mirrors OlympusAccessControlled.
/// @dev    UNAUDITED. Do not use in production without a full audit.
///         Roles are resolved at call time, so rotating a role in HoodzAuthority instantly
///         re-permissions every module in the protocol.
abstract contract HoodzAccessControlled {
    /* ========================================= ERRORS ========================================= */

    /// @notice Caller is not authority.governor().
    error HoodzAccessControlled_OnlyGovernor(address caller);
    /// @notice Caller is not authority.guardian().
    error HoodzAccessControlled_OnlyGuardian(address caller);
    /// @notice Caller is not authority.policy().
    error HoodzAccessControlled_OnlyPolicy(address caller);
    /// @notice Caller is not authority.vault().
    error HoodzAccessControlled_OnlyVault(address caller);
    /// @notice A zero address was supplied where an authority is required.
    error HoodzAccessControlled_ZeroAuthority();

    /* ========================================= EVENTS ========================================= */

    /// @notice Emitted whenever this module is pointed at a (new) authority.
    event AuthorityUpdated(IHoodzAuthority indexed authority);

    /* ========================================== STATE ========================================= */

    /// @notice The authority contract this module reads its four roles from.
    IHoodzAuthority public authority;

    /* ======================================== MODIFIERS ======================================= */

    /// @dev Restricts to authority.governor().
    modifier onlyGovernor() {
        if (msg.sender != authority.governor()) revert HoodzAccessControlled_OnlyGovernor(msg.sender);
        _;
    }

    /// @dev Restricts to authority.guardian().
    modifier onlyGuardian() {
        if (msg.sender != authority.guardian()) revert HoodzAccessControlled_OnlyGuardian(msg.sender);
        _;
    }

    /// @dev Restricts to authority.policy().
    modifier onlyPolicy() {
        if (msg.sender != authority.policy()) revert HoodzAccessControlled_OnlyPolicy(msg.sender);
        _;
    }

    /// @dev Restricts to authority.vault().
    modifier onlyVault() {
        if (msg.sender != authority.vault()) revert HoodzAccessControlled_OnlyVault(msg.sender);
        _;
    }

    /* ======================================= CONSTRUCTOR ====================================== */

    /// @param _authority Address of the HoodzAuthority this module obeys.
    constructor(IHoodzAuthority _authority) {
        if (address(_authority) == address(0)) revert HoodzAccessControlled_ZeroAuthority();
        authority = _authority;
        emit AuthorityUpdated(_authority);
    }

    /* ======================================== GOVERNANCE ====================================== */

    /// @notice Point this module at a new authority contract.
    /// @dev    Restricted to the current governor. Irreversible from this module point of view:
    ///         the new authority governs every subsequent call.
    /// @param _newAuthority Address of the replacement HoodzAuthority.
    function setAuthority(IHoodzAuthority _newAuthority) external onlyGovernor {
        if (address(_newAuthority) == address(0)) revert HoodzAccessControlled_ZeroAuthority();
        authority = _newAuthority;
        emit AuthorityUpdated(_newAuthority);
    }
}
