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

/// @title  IStaking
/// @notice The Hoodz staking contract: HOOD in, sHOOD or gHOOD out, rebasing every epoch.
/// @dev    UNAUDITED. Do not use in production without a full audit.
interface IStaking {
    /// @notice Stake HOOD to receive sHOOD or gHOOD.
    /// @param to_      Recipient of the staked position (or of the warmup claim).
    /// @param amount_  HOOD amount to stake, 9 decimals.
    /// @param rebasing_ True to receive rebasing sHOOD, false to receive gHOOD.
    /// @param claim_   True to bypass/settle warmup immediately when allowed.
    /// @return The amount of sHOOD (rebasing) or gHOOD (non-rebasing) credited.
    function stake(address to_, uint256 amount_, bool rebasing_, bool claim_) external returns (uint256);

    /// @notice Unstake sHOOD or gHOOD back into HOOD.
    /// @param to_      Recipient of the HOOD.
    /// @param amount_  Amount of sHOOD (rebasing) or gHOOD (non-rebasing) to burn.
    /// @param trigger_ True to trigger a rebase before unstaking.
    /// @param rebasing_ True if amount_ is denominated in sHOOD, false for gHOOD.
    /// @return The amount of HOOD returned, 9 decimals.
    function unstake(address to_, uint256 amount_, bool trigger_, bool rebasing_) external returns (uint256);

    /// @notice Trigger the epoch rebase if the current epoch has ended.
    function rebase() external;

    /// @notice The current sHOOD index.
    /// @return The index, 9 decimals.
    function index() external view returns (uint256);

    /// @notice Seconds remaining until the current epoch ends.
    /// @return The remaining seconds, zero if the epoch is already over.
    function secondsToNextEpoch() external view returns (uint256);
}
