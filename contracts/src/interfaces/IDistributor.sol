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

/// @title  IDistributor
/// @notice Mints the epoch reward out of the treasury and sends it to the staking contract.
/// @dev    UNAUDITED. Do not use in production without a full audit.
interface IDistributor {
    /// @notice Mint and distribute the reward for the epoch that just ended.
    /// @dev    Called by the staking contract inside rebase().
    function distribute() external;

    /// @notice Reward that would be minted for a recipient at the current rate.
    /// @param who_ Recipient to quote (normally the staking contract).
    /// @return The reward amount in HOODZ, 9 decimals.
    function nextRewardFor(address who_) external view returns (uint256);
}
