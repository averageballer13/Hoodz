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

/// @title  IPriceFeed
/// @notice Minimal Chainlink-compatible price feed consumed by Hoodz's automated
///         monetary policy. Every feed used by the protocol quotes ONE whole HOODZ in
///         whole units of the reserve asset (e.g. `12.34` reserve per HOODZ).
/// @dev    UNAUDITED. Do not use in production without a full audit.
///
///         Scaling contract: the raw `latestAnswer()` carries `decimals()` decimals and is
///         normalised by consumers to an 18-decimal fixed point number:
///         `price18 = uint256(latestAnswer()) * 10 ** (18 - decimals())`.
///         Feeds with more than 18 decimals are rejected at deployment time.
interface IPriceFeed {
    /// @notice Latest price of one whole HOODZ denominated in whole reserve tokens.
    /// @return answer Price carrying `decimals()` decimals. Consumers MUST reject `answer <= 0`.
    function latestAnswer() external view returns (int256 answer);

    /// @notice Number of decimals carried by `latestAnswer()`.
    /// @return decimals_ Decimal precision of the feed, expected to be <= 18.
    function decimals() external view returns (uint8 decimals_);

    /// @notice Unix timestamp of the block in which the latest answer was written.
    /// @return updatedAt_ Timestamp used by consumers for staleness checks.
    function updatedAt() external view returns (uint256 updatedAt_);
}
