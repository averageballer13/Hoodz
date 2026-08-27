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
        X      https://x.com/Hoodzfinancial
        Code   https://github.com/averageballer13/Hoodz

        UNAUDITED. This code has never been audited. Read it before you
        trust it with anything you would miss.
*/

/// @title  IHoodzBondAuctioneer
/// @notice Sequential-dutch-auction bond auctioneer that Hoodz's automated monetary
///         policies drive. It is the Hoodz equivalent of the Bond Protocol SDA auctioneer
///         used by Olympus: policies open a market, bidders pay `quoteToken` and receive
///         `payoutToken`, and the market price decays over time until bids arrive.
/// @dev    UNAUDITED. Do not use in production without a full audit.
///
///         PRICE SCALING (single, decimals-agnostic convention used by every Hoodz policy):
///         `price` is the number of WHOLE quote tokens paid for ONE WHOLE payout token,
///         expressed as an 18-decimal fixed point number (1e18 == "1 quote per payout").
///         The auctioneer is responsible for converting that into raw token units using
///         the two tokens' `decimals()`. Capacity is always denominated in RAW payout-token
///         units (1e9 for HOODZ, 1e18 for the reserve).
///
///         A market owner must approve `getTeller()` for `capacity` payout tokens before
///         calling `createMarket`; the teller pulls the payout as bids settle.
interface IHoodzBondAuctioneer {
    /// @notice Parameters for a new bond market.
    /// @param payoutToken     Token sold by the market owner.
    /// @param quoteToken      Token paid in by bidders.
    /// @param owner           Address that supplies the payout and receives the quote tokens.
    /// @param capacity        Market size in raw `payoutToken` units.
    /// @param initialPrice    Starting price, 1e18 = one whole quote token per whole payout token.
    /// @param minimumPrice    Price floor in the same 1e18 scale; the auction never settles below it.
    /// @param vesting         Seconds a bidder must wait before claiming the payout (0 = instant).
    /// @param conclusion      Unix timestamp after which the market stops accepting bids.
    /// @param depositInterval Target seconds between bids, used to size the tuning intervals.
    struct MarketParams {
        address payoutToken;
        address quoteToken;
        address owner;
        uint256 capacity;
        uint256 initialPrice;
        uint256 minimumPrice;
        uint48 vesting;
        uint48 conclusion;
        uint32 depositInterval;
    }

    /// @notice Open a new bond market.
    /// @param params Market configuration, see {MarketParams}.
    /// @return id Identifier of the created market.
    function createMarket(MarketParams memory params) external returns (uint256 id);

    /// @notice Close a market early. Only callable by the market owner.
    /// @param id Identifier of the market to close.
    function closeMarket(uint256 id) external;

    /// @notice Whether a market is still accepting bids.
    /// @param id Identifier of the market.
    /// @return live True while the market is open and has remaining capacity.
    function isLive(uint256 id) external view returns (bool live);

    /// @notice Teller contract that settles bids and must be approved for the payout token.
    /// @return teller Address of the teller.
    function getTeller() external view returns (address teller);

    /// @notice Current market price.
    /// @param id Identifier of the market.
    /// @return price Whole quote tokens per whole payout token, 18-decimal fixed point.
    function marketPrice(uint256 id) external view returns (uint256 price);
}
