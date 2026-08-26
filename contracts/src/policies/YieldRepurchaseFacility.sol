// SPDX-License-Identifier: AGPL-3.0-or-later
// UNAUDITED. Do not use in production without a full audit.
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {HoodzAccessControlled} from "../types/HoodzAccessControlled.sol";
import {IHoodzAuthority} from "../interfaces/IHoodzAuthority.sol";
import {IHOODZ} from "../interfaces/IHOODZ.sol";
import {ITreasury} from "../interfaces/ITreasury.sol";
import {IPriceFeed} from "../interfaces/IPriceFeed.sol";
import {IHoodzBondAuctioneer} from "../interfaces/IHoodzBondAuctioneer.sol";
import {IYieldRepurchaseFacility} from "../interfaces/IYieldRepurchaseFacility.sol";

/// @title  YieldRepurchaseFacility
/// @notice The Hoodz Yield Repurchase Facility (YRF), a port of the Olympus YRF. The
///         treasury parks its reserves in a yield bearing ERC4626 vault; once a week this
///         policy measures what that yield was worth and spends exactly that much, and never
///         more, buying HOODZ back off the market through seven daily bond markets. Every HOODZ
///         it buys is burned, so the facility converts reserve yield into a permanent
///         reduction of supply without ever touching principal.
/// @dev    UNAUDITED. Do not use in production without a full audit.
///
///         EPOCH ARITHMETIC. One staking epoch is 8 hours, so 3 epochs is a day and 21 epochs
///         is a week. `endEpoch()` is called by the heart on every epoch, acts on every third
///         one (7 markets per week, each sized `nextYield / 7`) and recomputes the weekly
///         budget when the counter reaches 21 and wraps to zero.
///
///         SCALING. Reserve amounts are raw 1e18 units and HOODZ amounts raw 1e9 units.
///         `lastConversionRate` is `sReserve.previewRedeem(1e18)`, i.e. reserve assets per 1e18
///         vault shares in 1e18 fixed point; the week's yield is derived from its growth.
///         Bond prices follow the auctioneer convention: whole quote tokens per whole payout
///         token, 1e18. Here the payout is the reserve and the quote is HOODZ, so the market
///         price is HOODZ per reserve and a HIGHER price is better for the DAO.
contract YieldRepurchaseFacility is IYieldRepurchaseFacility, HoodzAccessControlled {
    using SafeERC20 for IERC20;

    /* ======================================== CONSTANTS ======================================= */

    /// @notice Fixed point unit for every ratio in this contract (1.0).
    uint256 internal constant ONE = 1e18;
    /// @notice Raw unit of the HOODZ token, which carries 9 decimals.
    uint256 internal constant HOODZ_SCALE = 1e9;
    /// @notice Epochs in a day. The heart beats once per 8 hour epoch.
    uint256 internal constant EPOCHS_PER_DAY = 3;
    /// @notice Epochs in a week; the budget is recomputed when the counter reaches it.
    uint256 internal constant EPOCHS_PER_WEEK = 21;
    /// @notice Markets opened per week, one per day, each spending `nextYield / 7`.
    uint256 internal constant MARKETS_PER_WEEK = 7;
    /// @notice Lifetime of each daily repurchase market.
    uint48 internal constant MARKET_DURATION = 1 days;
    /// @notice Target seconds between bids; the auctioneer sizes its tuning interval from it.
    uint32 internal constant DEPOSIT_INTERVAL = 4 hours;
    /// @notice Markets open at twice the oracle rate and decay toward it, 1e18 scale.
    uint256 internal constant INITIAL_PRICE_MULTIPLIER = 2e18;
    /// @notice Governance may at most double the weekly budget in a single adjustment.
    uint256 internal constant MAX_YIELD_INCREASE = 2e18;
    /// @notice Sentinel meaning "no market of ours is outstanding".
    uint256 internal constant NO_MARKET = type(uint256).max;

    /* ======================================= IMMUTABLES ======================================= */

    /// @notice The HOODZ token bought back and burned by this facility.
    IHOODZ public immutable hoodz;
    /// @notice Reserve asset spent on repurchases, assumed to carry 18 decimals.
    IERC20 public immutable reserve;
    /// @notice Yield bearing ERC4626 wrapper of `reserve` held by the treasury.
    IERC4626 public immutable sReserve;
    /// @notice Hoodz Treasury, source of the reserves and sink for anything left over.
    ITreasury public immutable treasury;
    /// @notice Auctioneer running the repurchase bond markets.
    IHoodzBondAuctioneer public immutable auctioneer;
    /// @notice Oracle quoting one whole HOODZ in whole reserve tokens.
    IPriceFeed public immutable priceFeed;
    /// @notice Normalises the feed answer to 1e18: `10 ** (18 - priceFeed.decimals())`.
    uint256 public immutable priceFeedScalar;
    /// @notice Maximum age of an oracle answer before this policy refuses to act on it.
    uint48 public immutable maxPriceAge;

    /* ========================================== STATE ========================================= */

    /// @inheritdoc IYieldRepurchaseFacility
    uint256 public epoch;
    /// @inheritdoc IYieldRepurchaseFacility
    uint256 public nextYield;
    /// @notice Reserve denominated treasury balance recorded at the last weekly measurement.
    uint256 public lastReserveBalance;
    /// @notice `sReserve.previewRedeem(1e18)` recorded at the last weekly measurement.
    uint256 public lastConversionRate;
    /// @inheritdoc IYieldRepurchaseFacility
    bool public isShutdown;
    /// @notice True once the facility has been bootstrapped at least once.
    bool public initialized;
    /// @inheritdoc IYieldRepurchaseFacility
    uint256 public activeMarketId;

    /* ======================================= CONSTRUCTOR ====================================== */

    /// @notice Wire the facility into the protocol.
    /// @param authority_   Hoodz authority holding the governor / guardian / policy / vault roles.
    /// @param hoodz_        HOODZ token, 9 decimals.
    /// @param reserve_     Reserve asset, 18 decimals.
    /// @param sReserve_    ERC4626 vault wrapping `reserve_`, held by the treasury.
    /// @param treasury_    Hoodz Treasury.
    /// @param auctioneer_  Bond auctioneer that runs the repurchase markets.
    /// @param priceFeed_   HOODZ price oracle, at most 18 decimals.
    /// @param maxPriceAge_ Maximum accepted age of an oracle answer, in seconds.
    constructor(
        IHoodzAuthority authority_,
        IHOODZ hoodz_,
        IERC20 reserve_,
        IERC4626 sReserve_,
        ITreasury treasury_,
        IHoodzBondAuctioneer auctioneer_,
        IPriceFeed priceFeed_,
        uint48 maxPriceAge_
    ) HoodzAccessControlled(authority_) {
        if (
            address(hoodz_) == address(0) || address(reserve_) == address(0) || address(sReserve_) == address(0)
                || address(treasury_) == address(0) || address(auctioneer_) == address(0)
                || address(priceFeed_) == address(0)
        ) revert YRF_ZeroAddress();
        if (maxPriceAge_ == 0) revert YRF_InvalidParam();
        if (sReserve_.asset() != address(reserve_)) revert YRF_InvalidParam();

        uint8 feedDecimals = priceFeed_.decimals();
        if (feedDecimals > 18) revert YRF_UnsupportedFeedDecimals(feedDecimals);

        hoodz = hoodz_;
        reserve = reserve_;
        sReserve = sReserve_;
        treasury = treasury_;
        auctioneer = auctioneer_;
        priceFeed = priceFeed_;
        priceFeedScalar = 10 ** (18 - uint256(feedDecimals));
        maxPriceAge = maxPriceAge_;
        activeMarketId = NO_MARKET;
    }

    /* ======================================== HEARTBEAT ======================================= */

    /// @inheritdoc IYieldRepurchaseFacility
    /// @dev Returns instead of reverting while shut down: the heart calls this on every epoch
    ///      and must never be bricked by monetary policy. The order inside a market day matters
    ///      - the previous market is settled (HOODZ burned, dust returned) before the next one is
    ///      funded, so the facility never holds two markets' worth of reserves at once.
    function endEpoch() external onlyPolicy {
        if (isShutdown) return;

        uint256 epoch_ = epoch + 1;

        // Only act once per day.
        if (epoch_ % EPOCHS_PER_DAY != 0) {
            epoch = epoch_;
            emit EpochEnded(epoch_);
            return;
        }

        // Start of a new week: measure the yield the reserves earned and reset the budget.
        if (epoch_ >= EPOCHS_PER_WEEK) {
            epoch_ = 0;
            uint256 measured = getNextYield();
            nextYield = measured;
            lastReserveBalance = getReserveBalance();
            lastConversionRate = sReserve.previewRedeem(ONE);
            emit YieldRecalculated(measured, lastReserveBalance, lastConversionRate);
        }
        epoch = epoch_;

        // Close out yesterday's market: burn the HOODZ it bought, return anything unspent.
        _settleMarket();

        uint256 bidAmount = nextYield / MARKETS_PER_WEEK;
        if (bidAmount == 0) return;

        // Never ask the treasury for more than it holds: the heart must not revert here.
        uint256 treasuryBalance = getReserveBalance();
        if (bidAmount > treasuryBalance) bidAmount = treasuryBalance;
        if (bidAmount == 0) return;

        _withdraw(bidAmount);
        // Withdrawals may round down by a wei; never try to sell more than we actually hold.
        uint256 available = reserve.balanceOf(address(this));
        if (available < bidAmount) bidAmount = available;
        if (bidAmount == 0) return;

        (uint256 marketId, uint256 minimumPrice) = _createMarket(bidAmount);
        activeMarketId = marketId;

        emit MarketOpened(marketId, bidAmount, minimumPrice);
    }

    /* ====================================== CONFIGURATION ===================================== */

    /// @inheritdoc IYieldRepurchaseFacility
    /// @dev Callable once, and again after a shutdown to restart the facility with a fresh
    ///      measurement of the treasury's position.
    function initialize(uint256 initialReserveBalance, uint256 initialConversionRate, uint256 initialYield)
        external
        onlyGovernor
    {
        if (initialized && !isShutdown) revert YRF_AlreadyInitialized();
        if (initialReserveBalance == 0 || initialConversionRate == 0) revert YRF_InvalidParam();

        epoch = 0;
        nextYield = initialYield;
        lastReserveBalance = initialReserveBalance;
        lastConversionRate = initialConversionRate;
        initialized = true;
        isShutdown = false;

        emit Initialized(initialReserveBalance, initialConversionRate, initialYield);
    }

    /// @inheritdoc IYieldRepurchaseFacility
    /// @dev Lowering the budget is always allowed; raising it is capped at 2x so a mistaken or
    ///      compromised governance call cannot drain reserves into repurchases.
    function adjustNextYield(uint256 newNextYield) external onlyGovernor {
        uint256 current = nextYield;
        if (newNextYield > (current * MAX_YIELD_INCREASE) / ONE) {
            revert YRF_YieldAdjustmentTooLarge(current, newNextYield);
        }
        nextYield = newNextYield;
        emit NextYieldAdjusted(current, newNextYield);
    }

    /// @inheritdoc IYieldRepurchaseFacility
    /// @dev Leaves this contract holding nothing: the live market is closed, the HOODZ bought so
    ///      far is burned and every unspent reserve token goes back to the treasury.
    function shutdown() external onlyGovernor {
        if (isShutdown) revert YRF_IsShutdown();

        isShutdown = true;
        nextYield = 0;

        uint256 marketId = activeMarketId;
        if (marketId != NO_MARKET && auctioneer.isLive(marketId)) auctioneer.closeMarket(marketId);
        _settleMarket();

        emit FacilityShutdown(uint48(block.timestamp));
    }

    /* ========================================== VIEWS ========================================= */

    /// @inheritdoc IYieldRepurchaseFacility
    /// @dev The vault's share price only moves up, so the yield earned on a balance is
    ///      `balance * (rateNow - rateThen) / rateNow`: the fraction of today's balance that is
    ///      pure appreciation. Returns 0 before the first measurement or if the rate is flat.
    function getNextYield() public view returns (uint256 yield) {
        uint256 lastRate = lastConversionRate;
        if (lastRate == 0) return 0;

        uint256 currentRate = sReserve.previewRedeem(ONE);
        if (currentRate <= lastRate) return 0;

        yield = (getReserveBalance() * (currentRate - lastRate)) / currentRate;
    }

    /// @inheritdoc IYieldRepurchaseFacility
    function getReserveBalance() public view returns (uint256 balance) {
        uint256 shares = sReserve.balanceOf(address(treasury));
        balance = sReserve.previewRedeem(shares) + reserve.balanceOf(address(treasury));
    }

    /// @notice Reserve amount the next daily market would be funded with.
    /// @return bidAmount One seventh of the weekly budget, raw 1e18 reserve units.
    function getNextBidAmount() external view returns (uint256 bidAmount) {
        bidAmount = nextYield / MARKETS_PER_WEEK;
    }

    /// @notice Price the oracle currently reports for one whole HOODZ.
    /// @return price Whole reserve tokens per whole HOODZ, 1e18 fixed point.
    function currentPrice() external view returns (uint256 price) {
        price = _currentPrice();
    }

    /* ========================================= INTERNAL ======================================= */

    /// @dev Oracle read normalised to 1e18 reserve per HOODZ, with zero and staleness checks.
    function _currentPrice() internal view returns (uint256 price) {
        int256 answer = priceFeed.latestAnswer();
        if (answer <= 0) revert YRF_InvalidPrice(answer);

        uint256 updatedAt = priceFeed.updatedAt();
        if (updatedAt == 0 || block.timestamp > updatedAt + maxPriceAge) revert YRF_StalePrice(updatedAt, maxPriceAge);

        // 1e18 = raw answer * 10 ** (18 - feed decimals).
        price = uint256(answer) * priceFeedScalar;
    }

    /// @dev Pull `amount` of reserve out of the treasury. Preference is to unwrap vault shares,
    ///      which is what the treasury actually holds; if it is short on shares the loose
    ///      reserve balance is used instead. Best effort by design: when neither leg alone
    ///      covers the request this is a no-op and the caller sizes the market off whatever it
    ///      actually received, so a thin treasury slows repurchases down instead of reverting
    ///      inside the heart's beat.
    /// @param amount Reserve to obtain, raw 1e18 units.
    function _withdraw(uint256 amount) internal {
        uint256 shares = sReserve.previewWithdraw(amount);
        if (shares != 0 && sReserve.balanceOf(address(treasury)) >= shares) {
            treasury.manage(address(sReserve), shares);
            sReserve.withdraw(amount, address(this), address(this));
        } else if (reserve.balanceOf(address(treasury)) >= amount) {
            treasury.manage(address(reserve), amount);
        }
    }

    /// @dev Open the daily repurchase market: the reserve is the payout and HOODZ is the quote,
    ///      so bidders sell HOODZ to this facility. Price is HOODZ per reserve in 1e18, the
    ///      inverse of the oracle's reserve-per-HOODZ quote. The market opens at twice the
    ///      oracle rate (a deep discount for the DAO) and decays down to it, so the facility
    ///      never pays more than spot for the HOODZ it burns.
    /// @param bidAmount Reserve to spend, raw 1e18 units.
    /// @return marketId     Identifier returned by the auctioneer.
    /// @return minimumPrice Floor price handed to the auctioneer, 1e18.
    function _createMarket(uint256 bidAmount) internal returns (uint256 marketId, uint256 minimumPrice) {
        // marketRate = 1 / price, both sides expressed per whole token in 1e18.
        uint256 marketRate = (ONE * ONE) / _currentPrice();
        minimumPrice = marketRate;
        uint256 initialPrice = (marketRate * INITIAL_PRICE_MULTIPLIER) / ONE;

        // Approve the whole reserve balance rather than just this bid: if a previous market is
        // somehow still live its unspent reserve is owed to the same teller.
        address teller = auctioneer.getTeller();
        reserve.forceApprove(teller, reserve.balanceOf(address(this)));

        marketId = auctioneer.createMarket(
            IHoodzBondAuctioneer.MarketParams({
                payoutToken: address(reserve),
                quoteToken: address(hoodz),
                owner: address(this),
                capacity: bidAmount,
                initialPrice: initialPrice,
                minimumPrice: minimumPrice,
                vesting: 0,
                conclusion: uint48(block.timestamp) + MARKET_DURATION,
                depositInterval: DEPOSIT_INTERVAL
            })
        );
    }

    /// @dev Settle a concluded market: drop the teller allowance, burn every HOODZ the market
    ///      bought and hand any reserve that went unspent back to the treasury.
    function _settleMarket() internal {
        uint256 marketId = activeMarketId;
        if (marketId != NO_MARKET && !auctioneer.isLive(marketId)) {
            reserve.forceApprove(auctioneer.getTeller(), 0);
            activeMarketId = NO_MARKET;
        }

        uint256 hoodzBalance = IERC20(address(hoodz)).balanceOf(address(this));
        if (hoodzBalance != 0) {
            hoodz.burn(hoodzBalance);
            emit HoodzBurned(hoodzBalance);
        }

        if (activeMarketId == NO_MARKET) {
            uint256 unspent = reserve.balanceOf(address(this));
            if (unspent != 0) _returnToTreasury(unspent);
        }
    }

    /// @dev Book reserves back into the treasury without minting: `ITreasury.deposit` mints
    ///      `value - profit` HOODZ to the caller, so passing `profit == value` (both 9 decimal
    ///      HOODZ terms, as returned by `tokenValue`) credits the full amount and mints nothing.
    /// @param amount Reserve to return, raw 1e18 units.
    function _returnToTreasury(uint256 amount) internal {
        uint256 value = treasury.tokenValue(address(reserve), amount);
        reserve.forceApprove(address(treasury), amount);
        treasury.deposit(amount, address(reserve), value);

        emit ReservesReturned(amount);
    }
}
