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

/// @title  IEmissionsManager
/// @notice Interface of the Hoodz Emissions Manager, the policy that sells newly minted
///         HOOD into the market whenever HOOD trades at a premium to its backing.
/// @dev    UNAUDITED. Do not use in production without a full audit.
///
///         FIXED POINT CONVENTIONS
///         - `ONE` (1e18) is the fixed point unit for every ratio: price, backing, premium,
///           emission rate.
///         - `price`   : whole reserve tokens per whole HOOD, 1e18.
///         - `backing` : whole reserve tokens of treasury backing per whole HOOD, 1e18.
///         - `premium` : `price / backing - 1`, 1e18 (0 when HOOD trades at or below backing).
///         - HOOD amounts are raw 1e9 units.
interface IEmissionsManager {
    /* ------------------------------------------------------------------ events */

    /// @notice Emitted when the manager is (re)configured and activated.
    event Initialized(
        uint256 baseEmissionRate, uint256 minimumPremium, uint48 vestingPeriod, uint256 backing, uint48 restartTimeframe
    );
    /// @notice Emitted when governance changes the base emission rate.
    event BaseEmissionRateChanged(uint256 newRate);
    /// @notice Emitted when governance changes the minimum premium.
    event MinimumPremiumChanged(uint256 newMinimumPremium);
    /// @notice Emitted when governance changes the bond vesting period.
    event VestingPeriodChanged(uint48 newVestingPeriod);
    /// @notice Emitted when governance updates the recorded backing per HOOD.
    event BackingChanged(uint256 newBacking);
    /// @notice Emitted when a daily emission market is opened.
    event MarketOpened(uint256 indexed marketId, uint256 emission, uint256 premium, uint256 minimumPrice);
    /// @notice Emitted when unsold emission is burned.
    event SurplusBurned(uint256 amount);
    /// @notice Emitted when bond proceeds are pushed back into the treasury.
    event ReservesSwept(uint256 amount);
    /// @notice Emitted when emissions are halted.
    event EmissionsShutdown(uint48 timestamp);
    /// @notice Emitted when emissions are resumed inside the restart window.
    event EmissionsRestarted(uint48 timestamp);

    /* ------------------------------------------------------------------ errors */

    error EM_ZeroAddress();
    error EM_NotActive();
    error EM_AlreadyActive();
    error EM_InvalidRate(uint256 rate);
    error EM_InvalidPremium(uint256 premium);
    error EM_InvalidVestingPeriod(uint48 vestingPeriod);
    error EM_InvalidBacking(uint256 backing);
    error EM_InvalidTimeframe(uint48 timeframe);
    error EM_BackingChangeTooLarge(uint256 current, uint256 proposed);
    error EM_RestartWindowClosed(uint48 deadline);
    error EM_StalePrice(uint256 updatedAt, uint48 maxAge);
    error EM_InvalidPrice(int256 answer);
    error EM_UnsupportedFeedDecimals(uint8 feedDecimals);

    /* --------------------------------------------------------------- heartbeat */

    /// @notice Heartbeat hook, called once per staking epoch by the protocol heart policy.
    /// @dev    Acts only on every third beat (three 8 hour epochs == one day) and is a silent
    ///         no-op while shut down so the heart can never be bricked by this policy.
    function beat() external;

    /* ----------------------------------------------------------- configuration */

    /// @notice Configure and activate the manager.
    /// @param baseEmissionRate_ Fraction of supply emitted per day at the minimum premium, 1e18.
    /// @param minimumPremium_   Premium below which nothing is emitted, 1e18.
    /// @param vestingPeriod_    Seconds a bond buyer waits for their HOOD.
    /// @param backing_          Reserve backing per whole HOOD, 1e18.
    /// @param restartTimeframe_ Seconds after a shutdown during which `restart()` is allowed.
    function initialize(
        uint256 baseEmissionRate_,
        uint256 minimumPremium_,
        uint48 vestingPeriod_,
        uint256 backing_,
        uint48 restartTimeframe_
    ) external;

    /// @notice Change the base emission rate.
    /// @param newRate New rate, 1e18 fixed point, in `(0, 1e18]`.
    function changeBaseEmissionRate(uint256 newRate) external;

    /// @notice Change the minimum premium required before HOOD is emitted.
    /// @param newMinimumPremium New premium, 1e18 fixed point, strictly positive.
    function changeMinimumPremium(uint256 newMinimumPremium) external;

    /// @notice Change the vesting period applied to newly opened emission markets.
    /// @param newVestingPeriod New vesting period in seconds.
    function changeVestingPeriod(uint48 newVestingPeriod) external;

    /// @notice Update the recorded treasury backing per HOOD.
    /// @param newBacking New backing, 1e18 fixed point; may move at most 10% per call.
    function setBacking(uint256 newBacking) external;

    /// @notice Resume emissions after a shutdown, inside the restart window.
    function restart() external;

    /// @notice Halt emissions, close the live market, burn unsold HOOD and return proceeds.
    function shutdown() external;

    /* ------------------------------------------------------------------- views */

    /// @notice Premium of the market price over backing.
    /// @return premium `price / backing - 1` as 1e18 fixed point, floored at 0.
    function getPremium() external view returns (uint256 premium);

    /// @notice Size of the next emission at the current oracle price.
    /// @dev    `emission = supply * (premium - minimumPremium) / (1 + premium) * baseEmissionRate`.
    /// @return premium  Current premium, 1e18.
    /// @return emission HOOD to mint and sell, raw 1e9 units; 0 while the premium is too low.
    function getNextEmission() external view returns (uint256 premium, uint256 emission);

    /// @notice Circulating HOOD supply used as the emission base.
    /// @return supply Raw 1e9 HOOD units, taken from the treasury's base supply.
    function getSupply() external view returns (uint256 supply);

    /// @notice Fraction of supply emitted per day at the minimum premium, 1e18.
    function baseEmissionRate() external view returns (uint256);

    /// @notice Premium below which no HOOD is emitted, 1e18.
    function minimumPremium() external view returns (uint256);

    /// @notice Vesting period applied to emission markets, in seconds.
    function vestingPeriod() external view returns (uint48);

    /// @notice Reserve backing per whole HOOD, 1e18.
    function backing() external view returns (uint256);

    /// @notice Seconds after a shutdown during which `restart()` is allowed.
    function restartTimeframe() external view returns (uint48);

    /// @notice Whether the manager is currently emitting.
    function locallyActive() external view returns (bool);

    /// @notice Identifier of the market opened by the last emission, or `type(uint256).max`.
    function activeMarketId() external view returns (uint256);
}
