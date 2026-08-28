// SPDX-License-Identifier: AGPL-3.0-or-later
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

/// @title IPonsFeeRouter
/// @notice Minimal integration surface for the PONS fee router.
/// @dev Trading fees earned by a graduated PONS pool accrue to the router and are split between the
///      launchpad, the launch creator and the protocol. Hoodz's share is claimed in the reserve
///      token by {FeeRouterBuyback}, which swaps it for HOOD and burns it - mirroring PONS's own
///      buyback-and-burn. The router never has authority over HOOD supply.
interface IPonsFeeRouter {
    /// @notice Emitted when accrued fees are pushed to the recipient of a launch.
    event FeesClaimed(address indexed token, address indexed recipient, uint256 amount);

    /// @notice Emitted when the fee recipient of the caller's launch is changed.
    event FeeRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);

    /// @notice Claim the caller's accrued protocol fee share for a launched token.
    /// @dev Pays out in the launch's reserve token to {feeRecipient}. Implementations are expected to
    ///      be safe to call with nothing pending; {FeeRouterBuyback} additionally wraps the call so a
    ///      reverting router cannot brick a buyback that has reserve already on hand.
    /// @param token The launched token whose pool fees are being claimed.
    /// @return amount Reserve token amount transferred to the fee recipient.
    function claimFees(address token) external returns (uint256 amount);

    /// @notice Fee share accrued but not yet claimed for a launched token.
    /// @param token The launched token whose pool fees are being queried.
    /// @return amount Claimable reserve token amount.
    function claimableFees(address token) external view returns (uint256 amount);

    /// @notice Current destination of claimed fees.
    /// @return The fee recipient address.
    function feeRecipient() external view returns (address);

    /// @notice Point future fee claims at a new recipient.
    /// @dev Governed by the launch owner on the PONS side; Hoodz calls this exactly once, to aim
    ///      the protocol fee share at {FeeRouterBuyback}.
    /// @param newRecipient The new fee recipient.
    function setFeeRecipient(address newRecipient) external;
}
