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

/// @title  IHoodzAuthority
/// @notice Four-role access authority for the Hoodz protocol (mirrors OlympusAuthority).
/// @dev    UNAUDITED. Do not use in production without a full audit.
///         Roles:
///          - governor: protocol owner, can rewire every module and reassign every role
///          - guardian: emergency multisig, can act on time-sensitive policy
///          - policy:   parameter setter (bond markets, staking warmup, distributor rates)
///          - vault:    the only address allowed to mint HOOD (the Hoodz Treasury)
interface IHoodzAuthority {
    /* ========================================= EVENTS ========================================= */

    /// @notice Emitted when a new governor is nominated (or installed immediately).
    event GovernorPushed(address indexed from, address indexed to, bool effectiveImmediately);
    /// @notice Emitted when a new guardian is nominated (or installed immediately).
    event GuardianPushed(address indexed from, address indexed to, bool effectiveImmediately);
    /// @notice Emitted when a new policy is nominated (or installed immediately).
    event PolicyPushed(address indexed from, address indexed to, bool effectiveImmediately);
    /// @notice Emitted when a new vault is nominated (or installed immediately).
    event VaultPushed(address indexed from, address indexed to, bool effectiveImmediately);

    /// @notice Emitted when a nominated governor claims the role.
    event GovernorPulled(address indexed from, address indexed to);
    /// @notice Emitted when a nominated guardian claims the role.
    event GuardianPulled(address indexed from, address indexed to);
    /// @notice Emitted when a nominated policy claims the role.
    event PolicyPulled(address indexed from, address indexed to);
    /// @notice Emitted when a nominated vault claims the role.
    event VaultPulled(address indexed from, address indexed to);

    /* ======================================== FUNCTIONS ======================================= */

    /// @notice Address currently holding the governor role.
    /// @return The governor address.
    function governor() external view returns (address);

    /// @notice Address currently holding the guardian role.
    /// @return The guardian address.
    function guardian() external view returns (address);

    /// @notice Address currently holding the policy role.
    /// @return The policy address.
    function policy() external view returns (address);

    /// @notice Address currently holding the vault role (the only HOOD minter).
    /// @return The vault address.
    function vault() external view returns (address);
}
