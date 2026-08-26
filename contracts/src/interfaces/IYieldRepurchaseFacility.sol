// SPDX-License-Identifier: AGPL-3.0-or-later
// UNAUDITED. Do not use in production without a full audit.
pragma solidity ^0.8.24;

/// @title  IYieldRepurchaseFacility
/// @notice Interface of the Hoodz Yield Repurchase Facility (YRF): every week the DAO
///         measures the yield its reserves earned and spends exactly that yield buying HOODZ
///         back off the market through daily bond markets. The HOODZ bought is burned.
/// @dev    UNAUDITED. Do not use in production without a full audit.
///
///         EPOCH ARITHMETIC
///         - One staking epoch is 8 hours, so 3 epochs == 1 day and 21 epochs == 1 week.
///         - `endEpoch()` is called by the heart every epoch; it opens a market every third
///           epoch, i.e. 7 markets per week, each spending `nextYield / 7`.
///
///         FIXED POINT CONVENTIONS
///         - Reserve amounts are raw 1e18 units, HOODZ amounts raw 1e9 units.
///         - `lastConversionRate` is `sReserve.previewRedeem(1e18)`: reserve assets per 1e18
///           vault shares, 1e18 fixed point. Yield is derived from its growth.
interface IYieldRepurchaseFacility {
    /* ------------------------------------------------------------------ events */

    /// @notice Emitted when the facility is bootstrapped or restarted.
    event Initialized(uint256 reserveBalance, uint256 conversionRate, uint256 nextYield);
    /// @notice Emitted on every epoch tick that is not a market day.
    event EpochEnded(uint256 epoch);
    /// @notice Emitted at the start of a new week when the yield budget is recomputed.
    event YieldRecalculated(uint256 nextYield, uint256 reserveBalance, uint256 conversionRate);
    /// @notice Emitted when governance overrides the weekly yield budget.
    event NextYieldAdjusted(uint256 oldNextYield, uint256 newNextYield);
    /// @notice Emitted when a daily repurchase market is opened.
    event MarketOpened(uint256 indexed marketId, uint256 bidAmount, uint256 minimumPrice);
    /// @notice Emitted when repurchased HOODZ is burned.
    event HoodzBurned(uint256 amount);
    /// @notice Emitted when unspent reserves are returned to the treasury.
    event ReservesReturned(uint256 amount);
    /// @notice Emitted when the facility is wound down.
    event FacilityShutdown(uint48 timestamp);

    /* ------------------------------------------------------------------ errors */

    error YRF_ZeroAddress();
    error YRF_IsShutdown();
    error YRF_AlreadyInitialized();
    error YRF_InvalidParam();
    error YRF_YieldAdjustmentTooLarge(uint256 current, uint256 proposed);
    error YRF_StalePrice(uint256 updatedAt, uint48 maxAge);
    error YRF_InvalidPrice(int256 answer);
    error YRF_UnsupportedFeedDecimals(uint8 feedDecimals);

    /* --------------------------------------------------------------- heartbeat */

    /// @notice Heartbeat hook, called once per 8 hour staking epoch by the heart policy.
    /// @dev    Silent no-op while shut down. On every third epoch it settles the previous
    ///         market, burns the HOODZ it bought and opens the next daily market.
    function endEpoch() external;

    /* ----------------------------------------------------------- configuration */

    /// @notice Bootstrap (or restart) the facility with the treasury's current position.
    /// @param initialReserveBalance Reserve-denominated treasury balance at bootstrap, 1e18.
    /// @param initialConversionRate `sReserve.previewRedeem(1e18)` at bootstrap, 1e18.
    /// @param initialYield          Yield budget for the first week, raw reserve units.
    function initialize(uint256 initialReserveBalance, uint256 initialConversionRate, uint256 initialYield) external;

    /// @notice Override the weekly yield budget.
    /// @dev    May lower the budget freely but may not more than double it.
    /// @param newNextYield New weekly budget in raw reserve units.
    function adjustNextYield(uint256 newNextYield) external;

    /// @notice Wind the facility down: close the live market, burn HOODZ, return reserves.
    function shutdown() external;

    /* ------------------------------------------------------------------- views */

    /// @notice Yield the reserves earned since the last weekly measurement.
    /// @return yield Raw reserve units, 0 while the vault rate has not grown.
    function getNextYield() external view returns (uint256 yield);

    /// @notice Reserve-denominated treasury balance backing the facility.
    /// @return balance Wrapped vault shares valued in reserve plus loose reserve, 1e18 units.
    function getReserveBalance() external view returns (uint256 balance);

    /// @notice Epoch counter, wrapping every 21 epochs (one week).
    function epoch() external view returns (uint256);

    /// @notice Yield budget for the current week, raw reserve units.
    function nextYield() external view returns (uint256);

    /// @notice Whether the facility has been wound down.
    function isShutdown() external view returns (bool);

    /// @notice Identifier of the live repurchase market, or `type(uint256).max`.
    function activeMarketId() external view returns (uint256);
}
