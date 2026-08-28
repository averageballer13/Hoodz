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

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {HoodzAccessControlled} from "../types/HoodzAccessControlled.sol";
import {IHoodzAuthority} from "../interfaces/IHoodzAuthority.sol";
import {IHOOD} from "../interfaces/IHOOD.sol";
import {ITreasury} from "../interfaces/ITreasury.sol";
import {IPriceFeed} from "../interfaces/IPriceFeed.sol";
import {IHoodzBondAuctioneer} from "../interfaces/IHoodzBondAuctioneer.sol";
import {IEmissionsManager} from "../interfaces/IEmissionsManager.sol";
import {HoodzBurn} from "../types/HoodzBurn.sol";

/// @title  EmissionsManager
/// @notice Hoodz's automated supply-side monetary policy, a port of the Olympus Emissions
///         Manager. Once a day it asks the oracle what HOOD costs, compares that to the
///         treasury backing per HOOD, and if HOOD trades at a healthy premium it mints new
///         HOOD and sells it through a bond market. Every reserve token the market takes in is
///         pushed straight back into the treasury, so an emission can only raise backing per
///         HOOD, never dilute it.
/// @dev    UNAUDITED. Do not use in production without a full audit.
///
///         SCALING. Two units live in this file and they are never mixed silently:
///         - `ONE` (1e18) is the fixed point unit of every ratio: oracle price, backing,
///           premium and emission rate. `1e18` reads as "1.0", `5e16` reads as "5%".
///         - `HOOD_SCALE` (1e9) is the raw unit of the HOOD token. Supply and emission amounts
///           are raw 1e9 units and are never rescaled: the premium terms they are multiplied
///           by are dimensionless ratios of two 1e18 numbers.
///
///         EMISSION FORMULA (per day, only while `premium > minimumPremium`):
///             premium  = price / backing - 1
///             emission = supply * (premium - minimumPremium) / (1 + premium) * baseEmissionRate
///         The `(premium - minimumPremium) / (1 + premium)` term is self damping: it is zero at
///         the minimum premium and asymptotes to `supply * baseEmissionRate` as the premium
///         grows, so a violent price move cannot mint an unbounded amount of HOOD.
contract EmissionsManager is IEmissionsManager, HoodzAccessControlled {
    using SafeERC20 for IERC20;

    /* ======================================== CONSTANTS ======================================= */

    /// @notice Fixed point unit for every ratio in this contract (1.0).
    uint256 internal constant ONE = 1e18;
    /// @notice Raw unit of the HOOD token, which carries 9 decimals.
    uint256 internal constant HOOD_SCALE = 1e9;
    /// @notice Beats per emission. The heart beats once per 8 hour epoch, so 3 beats == 1 day.
    uint8 internal constant BEATS_PER_DAY = 3;
    /// @notice Lifetime of each daily emission market.
    uint48 internal constant MARKET_DURATION = 1 days;
    /// @notice Target seconds between bids; the auctioneer sizes its tuning interval from it.
    uint32 internal constant DEPOSIT_INTERVAL = 4 hours;
    /// @notice Upper bound on the bond vesting period governance may set.
    uint48 internal constant MAX_VESTING_PERIOD = 30 days;
    /// @notice Maximum relative move of `backing` per `setBacking` call: 10%, 1e18 scale.
    uint256 internal constant MAX_BACKING_CHANGE = 1e17;
    /// @notice Sentinel meaning "no market of ours is outstanding".
    uint256 internal constant NO_MARKET = type(uint256).max;

    /* ======================================= IMMUTABLES ======================================= */

    /// @notice The HOOD token minted by emissions.
    IHOOD public immutable hoodz;
    /// @notice Reserve asset bidders pay with, assumed to carry 18 decimals.
    IERC20 public immutable reserve;
    /// @notice Hoodz Treasury: mints the emission and receives the proceeds.
    ITreasury public immutable treasury;
    /// @notice Auctioneer running the emission bond markets.
    IHoodzBondAuctioneer public immutable auctioneer;
    /// @notice Oracle quoting one whole HOOD in whole reserve tokens.
    IPriceFeed public immutable priceFeed;
    /// @notice Normalises the feed answer to 1e18: `10 ** (18 - priceFeed.decimals())`.
    uint256 public immutable priceFeedScalar;
    /// @notice Maximum age of an oracle answer before this policy refuses to act on it.
    uint48 public immutable maxPriceAge;

    /* ========================================== STATE ========================================= */

    /// @inheritdoc IEmissionsManager
    uint256 public baseEmissionRate;
    /// @inheritdoc IEmissionsManager
    uint256 public minimumPremium;
    /// @inheritdoc IEmissionsManager
    uint256 public backing;
    /// @inheritdoc IEmissionsManager
    uint48 public vestingPeriod;
    /// @inheritdoc IEmissionsManager
    uint48 public restartTimeframe;
    /// @notice Timestamp of the most recent shutdown; anchors the restart window.
    uint48 public shutdownTimestamp;
    /// @inheritdoc IEmissionsManager
    bool public locallyActive;
    /// @notice Rolling beat counter. An emission is attempted when it wraps back to zero.
    uint8 public beatCounter;
    /// @inheritdoc IEmissionsManager
    uint256 public activeMarketId;

    /* ======================================= CONSTRUCTOR ====================================== */

    /// @notice Wire the emissions manager into the protocol.
    /// @param authority_   Hoodz authority holding the governor / guardian / policy / vault roles.
    /// @param hoodz_        HOOD token, 9 decimals.
    /// @param reserve_     Reserve asset accepted by emission markets, 18 decimals.
    /// @param treasury_    Hoodz Treasury.
    /// @param auctioneer_  Bond auctioneer that runs the emission markets.
    /// @param priceFeed_   HOOD price oracle, at most 18 decimals.
    /// @param maxPriceAge_ Maximum accepted age of an oracle answer, in seconds.
    constructor(
        IHoodzAuthority authority_,
        IHOOD hoodz_,
        IERC20 reserve_,
        ITreasury treasury_,
        IHoodzBondAuctioneer auctioneer_,
        IPriceFeed priceFeed_,
        uint48 maxPriceAge_
    ) HoodzAccessControlled(authority_) {
        if (
            address(hoodz_) == address(0) || address(reserve_) == address(0) || address(treasury_) == address(0)
                || address(auctioneer_) == address(0) || address(priceFeed_) == address(0)
        ) revert EM_ZeroAddress();
        if (maxPriceAge_ == 0) revert EM_InvalidTimeframe(maxPriceAge_);

        uint8 feedDecimals = priceFeed_.decimals();
        if (feedDecimals > 18) revert EM_UnsupportedFeedDecimals(feedDecimals);

        hoodz = hoodz_;
        reserve = reserve_;
        treasury = treasury_;
        auctioneer = auctioneer_;
        priceFeed = priceFeed_;
        priceFeedScalar = 10 ** (18 - uint256(feedDecimals));
        maxPriceAge = maxPriceAge_;
        activeMarketId = NO_MARKET;
    }

    /* ======================================== HEARTBEAT ======================================= */

    /// @inheritdoc IEmissionsManager
    /// @dev Returns instead of reverting when inactive or when there is nothing to emit: the
    ///      heart calls this on every epoch and must never be bricked by monetary policy.
    function beat() external onlyPolicy {
        if (!locallyActive) return;

        uint8 counter = beatCounter + 1;
        if (counter >= BEATS_PER_DAY) counter = 0;
        beatCounter = counter;
        if (counter != 0) return;

        // Wind up yesterday's market before opening today's.
        _settleMarket();

        (uint256 premium, uint256 emission) = getNextEmission();
        if (emission == 0) return;

        // The treasury mints the emission here; the auctioneer's teller pulls HOOD out of this
        // contract as bids settle and `_settleMarket` burns whatever never sold.
        treasury.payout(address(this), emission);
        (uint256 marketId, uint256 minimumPrice) = _createMarket(emission);
        activeMarketId = marketId;

        emit MarketOpened(marketId, emission, premium, minimumPrice);
    }

    /* ====================================== CONFIGURATION ===================================== */

    /// @inheritdoc IEmissionsManager
    /// @dev Callable while shut down only, so a live policy can never be silently reparametrised.
    function initialize(
        uint256 baseEmissionRate_,
        uint256 minimumPremium_,
        uint48 vestingPeriod_,
        uint256 backing_,
        uint48 restartTimeframe_
    ) external onlyGovernor {
        if (locallyActive) revert EM_AlreadyActive();
        if (baseEmissionRate_ == 0 || baseEmissionRate_ > ONE) revert EM_InvalidRate(baseEmissionRate_);
        if (minimumPremium_ == 0) revert EM_InvalidPremium(minimumPremium_);
        if (vestingPeriod_ > MAX_VESTING_PERIOD) revert EM_InvalidVestingPeriod(vestingPeriod_);
        if (backing_ == 0) revert EM_InvalidBacking(backing_);
        if (restartTimeframe_ == 0) revert EM_InvalidTimeframe(restartTimeframe_);

        baseEmissionRate = baseEmissionRate_;
        minimumPremium = minimumPremium_;
        vestingPeriod = vestingPeriod_;
        backing = backing_;
        restartTimeframe = restartTimeframe_;

        beatCounter = 0;
        shutdownTimestamp = 0;
        locallyActive = true;

        emit Initialized(baseEmissionRate_, minimumPremium_, vestingPeriod_, backing_, restartTimeframe_);
    }

    /// @inheritdoc IEmissionsManager
    function changeBaseEmissionRate(uint256 newRate) external onlyGovernor {
        if (newRate == 0 || newRate > ONE) revert EM_InvalidRate(newRate);
        baseEmissionRate = newRate;
        emit BaseEmissionRateChanged(newRate);
    }

    /// @inheritdoc IEmissionsManager
    function changeMinimumPremium(uint256 newMinimumPremium) external onlyGovernor {
        if (newMinimumPremium == 0) revert EM_InvalidPremium(newMinimumPremium);
        minimumPremium = newMinimumPremium;
        emit MinimumPremiumChanged(newMinimumPremium);
    }

    /// @inheritdoc IEmissionsManager
    function changeVestingPeriod(uint48 newVestingPeriod) external onlyGovernor {
        if (newVestingPeriod > MAX_VESTING_PERIOD) revert EM_InvalidVestingPeriod(newVestingPeriod);
        vestingPeriod = newVestingPeriod;
        emit VestingPeriodChanged(newVestingPeriod);
    }

    /// @inheritdoc IEmissionsManager
    /// @dev Backing is the most sensitive input to the emission formula, so one call may move it
    ///      by at most `MAX_BACKING_CHANGE` (10%) in either direction; larger revaluations have
    ///      to be walked in over several governance actions.
    function setBacking(uint256 newBacking) external onlyGovernor {
        uint256 current = backing;
        if (newBacking == 0) revert EM_InvalidBacking(newBacking);
        if (current != 0) {
            uint256 delta = (current * MAX_BACKING_CHANGE) / ONE;
            if (newBacking + delta < current || newBacking > current + delta) {
                revert EM_BackingChangeTooLarge(current, newBacking);
            }
        }
        backing = newBacking;
        emit BackingChanged(newBacking);
    }

    /// @inheritdoc IEmissionsManager
    /// @dev The window exists so an operational pause can be undone quickly, while a genuine
    ///      deprecation ages out and forces a fresh `initialize` with fresh parameters.
    function restart() external onlyGovernor {
        if (locallyActive) revert EM_AlreadyActive();
        uint48 deadline = shutdownTimestamp + restartTimeframe;
        if (uint48(block.timestamp) >= deadline) revert EM_RestartWindowClosed(deadline);

        beatCounter = 0;
        locallyActive = true;
        emit EmissionsRestarted(uint48(block.timestamp));
    }

    /// @inheritdoc IEmissionsManager
    /// @dev Leaves this contract holding nothing: the live market is closed, unsold HOOD burned
    ///      and bond proceeds returned to the treasury.
    function shutdown() external onlyGovernor {
        if (!locallyActive) revert EM_NotActive();

        locallyActive = false;
        beatCounter = 0;
        shutdownTimestamp = uint48(block.timestamp);

        uint256 marketId = activeMarketId;
        if (marketId != NO_MARKET && auctioneer.isLive(marketId)) auctioneer.closeMarket(marketId);
        _settleMarket();

        emit EmissionsShutdown(uint48(block.timestamp));
    }

    /* ========================================== VIEWS ========================================= */

    /// @inheritdoc IEmissionsManager
    function getPremium() public view returns (uint256 premium) {
        uint256 backing_ = backing;
        if (backing_ == 0) return 0;
        // price and backing are both 1e18 reserve-per-HOOD, so their ratio is a 1e18 scalar.
        uint256 priceToBacking = (_currentPrice() * ONE) / backing_;
        premium = priceToBacking > ONE ? priceToBacking - ONE : 0;
    }

    /// @inheritdoc IEmissionsManager
    function getNextEmission() public view returns (uint256 premium, uint256 emission) {
        premium = getPremium();
        uint256 floor = minimumPremium;
        if (premium <= floor) return (premium, 0);

        // `supply` is raw 1e9 HOOD. Both factors below are ratios of 1e18 numbers and therefore
        // dimensionless, so `emission` stays in raw 1e9 HOOD units.
        uint256 supply = getSupply();
        uint256 damped = (supply * (premium - floor)) / (ONE + premium);
        emission = (damped * baseEmissionRate) / ONE;
    }

    /// @inheritdoc IEmissionsManager
    function getSupply() public view returns (uint256 supply) {
        supply = treasury.baseSupply();
    }

    /// @notice Price the oracle currently reports for one whole HOOD.
    /// @return price Whole reserve tokens per whole HOOD, 1e18 fixed point.
    function currentPrice() external view returns (uint256 price) {
        price = _currentPrice();
    }

    /* ========================================= INTERNAL ======================================= */

    /// @dev Oracle read normalised to 1e18 reserve per HOOD, with zero and staleness checks.
    function _currentPrice() internal view returns (uint256 price) {
        int256 answer = priceFeed.latestAnswer();
        if (answer <= 0) revert EM_InvalidPrice(answer);

        uint256 updatedAt = priceFeed.updatedAt();
        if (updatedAt == 0 || block.timestamp > updatedAt + maxPriceAge) revert EM_StalePrice(updatedAt, maxPriceAge);

        // 1e18 = raw answer * 10 ** (18 - feed decimals).
        price = uint256(answer) * priceFeedScalar;
    }

    /// @dev Open the daily emission market: HOOD is the payout, the reserve is the quote.
    ///      Prices follow the auctioneer convention of whole quote per whole payout in 1e18, the
    ///      same scale the oracle and `backing` already use. The floor is
    ///      `backing * (1 + minimumPremium)`, so the auction can never sell HOOD for less reserve
    ///      than the DAO considers it worth; it opens at spot and decays toward that floor.
    /// @param emission HOOD to sell, raw 1e9 units.
    /// @return marketId     Identifier returned by the auctioneer.
    /// @return minimumPrice Floor price handed to the auctioneer, 1e18.
    function _createMarket(uint256 emission) internal returns (uint256 marketId, uint256 minimumPrice) {
        minimumPrice = (backing * (ONE + minimumPremium)) / ONE;
        uint256 initialPrice = _currentPrice();
        if (initialPrice < minimumPrice) initialPrice = minimumPrice;

        // Approve the whole HOOD balance rather than just this emission: if a previous market
        // is somehow still live its unsold HOOD is also owed to the same teller, and an
        // allowance of exactly `emission` would starve it.
        address teller = auctioneer.getTeller();
        IERC20(address(hoodz)).forceApprove(teller, IERC20(address(hoodz)).balanceOf(address(this)));

        marketId = auctioneer.createMarket(
            IHoodzBondAuctioneer.MarketParams({
                payoutToken: address(hoodz),
                quoteToken: address(reserve),
                owner: address(this),
                capacity: emission,
                initialPrice: initialPrice,
                minimumPrice: minimumPrice,
                vesting: vestingPeriod,
                conclusion: uint48(block.timestamp) + MARKET_DURATION,
                depositInterval: DEPOSIT_INTERVAL
            })
        );
    }

    /// @dev Settle a concluded market: drop the teller allowance, burn the HOOD that never sold
    ///      and push the reserve that was raised into the treasury. Nothing is burned while a
    ///      market is still live, because that HOOD is still committed to the teller.
    function _settleMarket() internal {
        uint256 marketId = activeMarketId;
        if (marketId != NO_MARKET && !auctioneer.isLive(marketId)) {
            IERC20(address(hoodz)).forceApprove(auctioneer.getTeller(), 0);
            activeMarketId = NO_MARKET;
        }

        if (activeMarketId == NO_MARKET) {
            uint256 unsold = IERC20(address(hoodz)).balanceOf(address(this));
            if (unsold != 0) {
                HoodzBurn.burn(IERC20(address(hoodz)), unsold);
                emit SurplusBurned(unsold);
            }
        }

        _sweepReserves();
    }

    /// @dev Book bond proceeds as treasury reserves without minting: `ITreasury.deposit` mints
    ///      `value - profit` HOOD to the caller, so passing `profit == value` (both 9 decimal
    ///      HOOD terms, as returned by `tokenValue`) credits the full amount and mints nothing.
    function _sweepReserves() internal {
        uint256 balance = reserve.balanceOf(address(this));
        if (balance == 0) return;

        uint256 value = treasury.tokenValue(address(reserve), balance);
        reserve.forceApprove(address(treasury), balance);
        treasury.deposit(balance, address(reserve), value);

        emit ReservesSwept(balance);
    }
}
