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
        X      https://x.com/hoodzdao
        Code   https://github.com/averageballer13/Hoodz

        UNAUDITED. This code has never been audited. Read it before you
        trust it with anything you would miss.
*/

/// @title  IStaking
/// @notice The Hoodz staking contract: HOODZ in, sHOODZ or gHOODZ out, rebasing every epoch.
/// @dev    UNAUDITED. Do not use in production without a full audit.
interface IStaking {
    /// @notice Stake HOODZ to receive sHOODZ or gHOODZ.
    /// @param to_      Recipient of the staked position (or of the warmup claim).
    /// @param amount_  HOODZ amount to stake, 9 decimals.
    /// @param rebasing_ True to receive rebasing sHOODZ, false to receive gHOODZ.
    /// @param claim_   True to bypass/settle warmup immediately when allowed.
    /// @return The amount of sHOODZ (rebasing) or gHOODZ (non-rebasing) credited.
    function stake(address to_, uint256 amount_, bool rebasing_, bool claim_) external returns (uint256);

    /// @notice Unstake sHOODZ or gHOODZ back into HOODZ.
    /// @param to_      Recipient of the HOODZ.
    /// @param amount_  Amount of sHOODZ (rebasing) or gHOODZ (non-rebasing) to burn.
    /// @param trigger_ True to trigger a rebase before unstaking.
    /// @param rebasing_ True if amount_ is denominated in sHOODZ, false for gHOODZ.
    /// @return The amount of HOODZ returned, 9 decimals.
    function unstake(address to_, uint256 amount_, bool trigger_, bool rebasing_) external returns (uint256);

    /// @notice Trigger the epoch rebase if the current epoch has ended.
    function rebase() external;

    /// @notice The current sHOODZ index.
    /// @return The index, 9 decimals.
    function index() external view returns (uint256);

    /// @notice Seconds remaining until the current epoch ends.
    /// @return The remaining seconds, zero if the epoch is already over.
    function secondsToNextEpoch() external view returns (uint256);
}
