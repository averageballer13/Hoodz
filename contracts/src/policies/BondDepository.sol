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

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IHoodzAuthority} from "../interfaces/IHoodzAuthority.sol";
import {IHOOD} from "../interfaces/IHOOD.sol";
import {IgHOOD} from "../interfaces/IgHOOD.sol";
import {IStaking} from "../interfaces/IStaking.sol";
import {ITreasury} from "../interfaces/ITreasury.sol";
import {NoteKeeper} from "../types/NoteKeeper.sol";

/**
 * @title  BondDepository
 * @author Hoodz
 * @notice Sells HOOD at a dynamically priced discount in exchange for reserve assets.
 * @dev    Port of the Olympus V2 BondDepository (BondDepositoryV2).
 *
 *         Pricing model, unchanged from Olympus:
 *
 *           price      = controlVariable * debtRatio
 *           debtRatio  = totalDebt / treasury.baseSupply()
 *           payout     = amount / price
 *
 *         Debt decays linearly over the length of the market, so price falls when nobody
 *         bonds and rises with every deposit. The control variable is re-tuned on a fixed
 *         interval so that the remaining capacity is sold out exactly at conclusion;
 *         downward tunes are amortised over the tune interval via an Adjustment.
 *
 *         Every market is a self-contained struct set indexed by its market ID. The IDs
 *         are stable forever: closing a market zeroes its capacity but never removes it.
 *
 *         Prices carry 9 decimals (HOOD decimals), matching Olympus. Quote token decimals
 *         are normalised out of the payout and debt-ratio maths via Metadata.quoteDecimals.
 *
 *         Note: this contract deliberately does not inherit IBondDepository (owned by the
 *         tokens agent) so that it compiles standalone; the market types below are the
 *         canonical Olympus V2 layouts.
 */
contract BondDepository is NoteKeeper {
    using SafeERC20 for IERC20;

    /* ========== ERRORS ========== */

    /// @notice Thrown when depositing into a market whose conclusion has passed.
    error Depository_MarketConcluded(uint256 id, uint48 conclusion);

    /// @notice Thrown when the live market price exceeds the caller slippage bound.
    error Depository_MoreThanMaxPrice(uint256 price, uint256 maxPrice);

    /// @notice Thrown when a single deposit would exceed the market max payout.
    error Depository_MaxSizeExceeded(uint256 payout, uint256 maxPayout);

    /// @notice Thrown when a market is created with a conclusion at or before now.
    error Depository_InvalidConclusion(uint256 conclusion);

    /// @notice Thrown when a market is created with a zero capacity or zero initial price.
    error Depository_InvalidParams();

    /// @notice Thrown when deposit/tune intervals are zero or inconsistent.
    error Depository_InvalidInterval(uint32 depositInterval, uint32 tuneInterval);

    /// @notice Thrown when a market ID does not exist.
    error Depository_InvalidMarket(uint256 id);

    /// @notice Thrown when the referenced token has more decimals than the model supports.
    error Depository_UnsupportedDecimals(uint8 decimals);

    /* ========== EVENTS ========== */

    /// @notice Emitted when a new bond market is opened.
    event CreateMarket(uint256 indexed id, address indexed baseToken, address indexed quoteToken, uint256 initialPrice);

    /// @notice Emitted when a market is closed, either manually or by the max-debt circuit breaker.
    event CloseMarket(uint256 indexed id);

    /// @notice Emitted on every successful deposit.
    event Bond(uint256 indexed id, uint256 amount, uint256 price);

    /// @notice Emitted whenever the control variable target is recomputed.
    event Tuned(uint256 indexed id, uint64 oldControlVariable, uint64 newControlVariable);

    /* ========== TYPES ========== */

    /// @notice Live accounting for one bond market.
    /// @param capacity        Remaining capacity, in quote tokens or HOOD per capacityInQuote.
    /// @param quoteToken      Token accepted as payment.
    /// @param capacityInQuote True when capacity is denominated in the quote token.
    /// @param totalDebt       Outstanding, decaying debt in HOOD (9 decimals).
    /// @param maxPayout       Largest payout a single deposit may take, in HOOD.
    /// @param sold            Cumulative HOOD sold by this market.
    /// @param purchased       Cumulative quote tokens taken in by this market.
    struct Market {
        uint256 capacity;
        IERC20 quoteToken;
        bool capacityInQuote;
        uint64 totalDebt;
        uint64 maxPayout;
        uint64 sold;
        uint256 purchased;
    }

    /// @notice Immutable-ish configuration of one bond market.
    /// @param fixedTerm       True for a fixed vesting length, false for a fixed expiry date.
    /// @param controlVariable Scaling factor that turns debt ratio into price.
    /// @param vesting         Vesting length (fixed-term) or absolute expiry (fixed-expiry).
    /// @param conclusion      Timestamp the market stops accepting deposits.
    /// @param maxDebt         Circuit breaker: market closes if totalDebt exceeds this.
    struct Terms {
        bool fixedTerm;
        uint64 controlVariable;
        uint48 vesting;
        uint48 conclusion;
        uint64 maxDebt;
    }

    /// @notice Bookkeeping used by the decay and tuning maths.
    /// @param lastTune        Timestamp of the last tune.
    /// @param lastDecay       Timestamp of the last debt decay.
    /// @param length          Total market duration, used as the debt decay speed.
    /// @param depositInterval Target spacing between deposits, sets max payout.
    /// @param tuneInterval    Minimum spacing between tunes.
    /// @param quoteDecimals   Decimals of the quote token.
    struct Metadata {
        uint48 lastTune;
        uint48 lastDecay;
        uint48 length;
        uint48 depositInterval;
        uint48 tuneInterval;
        uint8 quoteDecimals;
    }

    /// @notice A pending downward control-variable adjustment, amortised over time.
    /// @param change          Total remaining decrease.
    /// @param lastAdjustment  Timestamp the adjustment was last applied.
    /// @param timeToAdjusted  Seconds remaining until the change is fully applied.
    /// @param active          True while the adjustment is running.
    struct Adjustment {
        uint64 change;
        uint48 lastAdjustment;
        uint48 timeToAdjusted;
        bool active;
    }

    /* ========== CONSTANTS ========== */

    /// @notice HOOD decimals (9) + price decimals (9). Used to normalise payout maths.
    uint256 internal constant PAYOUT_SCALE = 1e18;

    /// @notice Denominator of the debt buffer passed to create(). 1e5 == 100%, 1000 == 1%.
    uint256 internal constant DEBT_BUFFER_DENOMINATOR = 1e5;

    /// @notice Upper bound on quote token decimals supported by the fixed-point model.
    uint8 internal constant MAX_QUOTE_DECIMALS = 30;

    /* ========== STATE ========== */

    /// @notice Every market ever created, indexed by market ID.
    Market[] public markets;

    /// @notice Terms of every market, indexed by market ID.
    Terms[] public terms;

    /// @notice Metadata of every market, indexed by market ID.
    Metadata[] public metadata;

    /// @notice Pending control-variable adjustment per market ID.
    mapping(uint256 => Adjustment) public adjustments;

    /// @notice Market IDs that accept a given quote token.
    mapping(address => uint256[]) public marketsForQuote;

    /* ========== CONSTRUCTOR ========== */

    /**
     * @param _authority Hoodz authority contract.
     * @param _hoodz      HOOD token.
     * @param _gHOOD     gHOOD token.
     * @param _staking   Hoodz staking contract.
     * @param _treasury  Hoodz treasury.
     */
    constructor(IHoodzAuthority _authority, IHOOD _hoodz, IgHOOD _gHOOD, IStaking _staking, ITreasury _treasury)
        NoteKeeper(_authority, IERC20(address(_hoodz)), _gHOOD, _staking, _treasury)
    {
        // bulk approve so users never pay for an approval inside stake()
        IERC20(address(_hoodz)).forceApprove(address(_staking), type(uint256).max);
    }

    /* ========== DEPOSIT ========== */

    /**
     * @notice Deposit quote tokens into a bond market in exchange for a vesting HOOD note.
     * @dev    Decays debt, prices the deposit, mints and stakes the payout, then re-tunes.
     *         Payment is pulled from msg.sender straight into the treasury.
     * @param _id       Market ID to deposit into.
     * @param _amount   Amount of quote tokens to spend.
     * @param _maxPrice Slippage bound: highest acceptable price, in HOOD decimals.
     * @param _user     Recipient of the vesting note.
     * @param _referral Front end operator credited for the deposit.
     * @return payout_  HOOD owed to the user (delivered as gHOOD once matured).
     * @return expiry_  Timestamp the note matures.
     * @return index_   Index of the note in the user note array.
     */
    function deposit(uint256 _id, uint256 _amount, uint256 _maxPrice, address _user, address _referral)
        external
        returns (uint256 payout_, uint256 expiry_, uint256 index_)
    {
        if (_id >= markets.length) revert Depository_InvalidMarket(_id);

        Market storage market = markets[_id];
        Terms memory term = terms[_id];
        uint48 currentTime = uint48(block.timestamp);

        // markets end at a defined timestamp
        if (currentTime >= term.conclusion) revert Depository_MarketConcluded(_id, term.conclusion);

        // debt decays in reverse of time, lowering price
        _decay(_id, currentTime);

        // users pass a maximum price, protecting them from price moves after signing
        uint256 price = _marketPrice(_id);
        if (price > _maxPrice) revert Depository_MoreThanMaxPrice(price, _maxPrice);

        // payout = amount / price, normalised out of quote decimals
        payout_ = ((_amount * PAYOUT_SCALE) / price) / (10 ** metadata[_id].quoteDecimals);

        // deposits do not experience slippage, so size is capped instead
        if (payout_ > market.maxPayout) revert Depository_MaxSizeExceeded(payout_, market.maxPayout);

        // capacity is either HOOD out or quote tokens in
        market.capacity -= market.capacityInQuote ? _amount : payout_;

        // fixed-term bonds mature a set duration after deposit; fixed-expiry bonds
        // all mature at the same absolute timestamp
        expiry_ = term.fixedTerm ? uint256(term.vesting) + currentTime : uint256(term.vesting);

        market.purchased += _amount;
        market.sold += uint64(payout_);

        // raising debt raises the price of the next bond
        market.totalDebt += uint64(payout_);

        emit Bond(_id, _amount, price);

        // the note mints, stakes and books the payout plus front end rewards
        index_ = addNote(_user, payout_, uint48(expiry_), uint48(_id), _referral);

        // payment goes straight to the treasury
        market.quoteToken.safeTransferFrom(msg.sender, address(treasury), _amount);

        if (term.maxDebt < market.totalDebt) {
            // circuit breaker: debt ran away, close the market
            market.capacity = 0;
            emit CloseMarket(_id);
        } else {
            // otherwise steer the control variable back onto the capacity schedule
            _tune(_id, currentTime);
        }
    }

    /* ========== INTERNAL DEPOSIT HELPERS ========== */

    /**
     * @notice Decay outstanding debt and apply any pending control-variable adjustment.
     * @param _id   Market ID.
     * @param _time Current timestamp.
     */
    function _decay(uint256 _id, uint48 _time) internal {
        // debt decay
        markets[_id].totalDebt -= debtDecay(_id);
        metadata[_id].lastDecay = _time;

        // control variable decay: downward tunes are applied gradually
        if (adjustments[_id].active) {
            Adjustment storage adjustment = adjustments[_id];

            (uint64 adjustBy, uint48 secondsSince, bool stillActive) = _controlDecay(_id);
            terms[_id].controlVariable -= adjustBy;

            if (stillActive) {
                adjustment.change -= adjustBy;
                adjustment.timeToAdjusted -= secondsSince;
                adjustment.lastAdjustment = _time;
            } else {
                adjustment.active = false;
            }
        }
    }

    /**
     * @notice Recompute max payout and the target control variable for a market.
     * @dev    No-op until a full tune interval has elapsed since the last tune.
     * @param _id   Market ID.
     * @param _time Current timestamp.
     */
    function _tune(uint256 _id, uint48 _time) internal {
        Metadata memory meta = metadata[_id];

        if (_time < meta.lastTune + meta.tuneInterval) return;

        Market memory market = markets[_id];

        uint256 timeRemaining = uint256(terms[_id].conclusion) - _time;
        uint256 price = _marketPrice(_id);
        if (price == 0) return;

        // standardise capacity into a base (HOOD) amount
        uint256 capacity = market.capacityInQuote
            ? ((market.capacity * PAYOUT_SCALE) / price) / (10 ** meta.quoteDecimals)
            : market.capacity;

        // the payout that a single deposit interval should be able to absorb
        markets[_id].maxPayout = uint64((capacity * meta.depositInterval) / timeRemaining);

        // ideal total debt to clear the remaining capacity on schedule
        uint256 targetDebt = (capacity * meta.length) / timeRemaining;
        if (targetDebt == 0) return;

        uint64 newControlVariable = uint64((price * treasury.baseSupply()) / targetDebt);
        uint64 oldControlVariable = terms[_id].controlVariable;

        emit Tuned(_id, oldControlVariable, newControlVariable);

        if (newControlVariable >= oldControlVariable) {
            terms[_id].controlVariable = newControlVariable;
        } else {
            // price is being lowered, so amortise the decrease over the tune interval
            uint64 change = oldControlVariable - newControlVariable;
            adjustments[_id] = Adjustment(change, _time, meta.tuneInterval, true);
        }

        metadata[_id].lastTune = _time;
    }

    /* ========== CREATE / CLOSE ========== */

    /**
     * @notice Open a new bond market.
     * @dev    Policy only. Initial debt is set equal to capacity, and the control variable
     *         is solved backwards from the requested initial price.
     * @param _quoteToken Token accepted as payment.
     * @param _market     [capacity, initial price (9 decimals), debt buffer (1e5 = 100%)].
     * @param _booleans   [capacity is in quote token, fixed term].
     * @param _terms      [vesting length or absolute expiry, conclusion timestamp].
     * @param _intervals  [deposit interval seconds, tune interval seconds].
     * @return id_ ID of the new market.
     */
    function create(
        IERC20 _quoteToken,
        uint256[3] memory _market,
        bool[2] memory _booleans,
        uint256[2] memory _terms,
        uint32[2] memory _intervals
    ) external onlyPolicy returns (uint256 id_) {
        if (_terms[1] <= block.timestamp) revert Depository_InvalidConclusion(_terms[1]);
        if (_market[0] == 0 || _market[1] == 0) revert Depository_InvalidParams();
        if (_intervals[0] == 0 || _intervals[1] == 0 || _intervals[0] > _intervals[1]) {
            revert Depository_InvalidInterval(_intervals[0], _intervals[1]);
        }

        // the length of the program, in seconds
        uint256 secondsToConclusion = _terms[1] - block.timestamp;

        uint8 decimals = IERC20Metadata(address(_quoteToken)).decimals();
        if (decimals > MAX_QUOTE_DECIMALS) revert Depository_UnsupportedDecimals(decimals);

        // initial target debt equals capacity: it decays away over the market length
        uint64 targetDebt = uint64(
            _booleans[0] ? ((_market[0] * PAYOUT_SCALE) / _market[1]) / (10 ** decimals) : _market[0]
        );
        if (targetDebt == 0) revert Depository_InvalidParams();

        // capacity that should be absorbed within one deposit interval
        uint64 maxPayout = uint64((uint256(targetDebt) * _intervals[0]) / secondsToConclusion);

        // circuit breaker, expressed as a buffer above the initial debt (1000 = 1%)
        uint256 maxDebt = targetDebt + ((uint256(targetDebt) * _market[2]) / DEBT_BUFFER_DENOMINATOR);

        // price = controlVariable * debtRatio, so controlVariable = price / debtRatio
        uint256 controlVariable = (_market[1] * treasury.baseSupply()) / targetDebt;

        id_ = markets.length;

        markets.push(
            Market({
                capacity: _market[0],
                quoteToken: _quoteToken,
                capacityInQuote: _booleans[0],
                totalDebt: targetDebt,
                maxPayout: maxPayout,
                sold: 0,
                purchased: 0
            })
        );

        terms.push(
            Terms({
                fixedTerm: _booleans[1],
                controlVariable: uint64(controlVariable),
                vesting: uint48(_terms[0]),
                conclusion: uint48(_terms[1]),
                maxDebt: uint64(maxDebt)
            })
        );

        metadata.push(
            Metadata({
                lastTune: uint48(block.timestamp),
                lastDecay: uint48(block.timestamp),
                length: uint48(secondsToConclusion),
                depositInterval: uint48(_intervals[0]),
                tuneInterval: uint48(_intervals[1]),
                quoteDecimals: decimals
            })
        );

        marketsForQuote[address(_quoteToken)].push(id_);

        emit CreateMarket(id_, address(hoodz), address(_quoteToken), _market[1]);
    }

    /**
     * @notice Disable a market, immediately and permanently.
     * @dev    Policy only. The market ID stays valid; outstanding notes are unaffected.
     * @param _id Market ID to close.
     */
    function close(uint256 _id) external onlyPolicy {
        if (_id >= markets.length) revert Depository_InvalidMarket(_id);

        terms[_id].conclusion = uint48(block.timestamp);
        markets[_id].capacity = 0;

        emit CloseMarket(_id);
    }

    /* ========== VIEW ========== */

    /**
     * @notice Current price of the quote token in HOOD, including pending decay.
     * @dev    price = currentControlVariable * debtRatio, normalised by quote decimals.
     * @param _id Market ID.
     * @return Price in HOOD decimals (9).
     */
    function marketPrice(uint256 _id) public view returns (uint256) {
        return (currentControlVariable(_id) * debtRatio(_id)) / (10 ** metadata[_id].quoteDecimals);
    }

    /**
     * @notice HOOD payout a given amount of quote tokens would buy right now.
     * @param _amount Quote tokens to spend.
     * @param _id     Market ID.
     * @return HOOD payout, 9 decimals.
     */
    function payoutFor(uint256 _amount, uint256 _id) external view returns (uint256) {
        return ((_amount * PAYOUT_SCALE) / marketPrice(_id)) / (10 ** metadata[_id].quoteDecimals);
    }

    /**
     * @notice Control variable with any pending downward adjustment already applied.
     * @param _id Market ID.
     * @return The effective control variable.
     */
    function currentControlVariable(uint256 _id) public view returns (uint256) {
        (uint64 decay,,) = _controlDecay(_id);
        return terms[_id].controlVariable - decay;
    }

    /**
     * @notice Ratio of outstanding debt to HOOD base supply, in quote decimals.
     * @param _id Market ID.
     * @return Debt ratio.
     */
    function debtRatio(uint256 _id) public view returns (uint256) {
        return (currentDebt(_id) * (10 ** metadata[_id].quoteDecimals)) / treasury.baseSupply();
    }

    /**
     * @notice Outstanding debt of a market after applying pending decay.
     * @param _id Market ID.
     * @return Current debt, in HOOD decimals.
     */
    function currentDebt(uint256 _id) public view returns (uint256) {
        return markets[_id].totalDebt - debtDecay(_id);
    }

    /**
     * @notice Debt that has decayed away since the last decay checkpoint.
     * @param _id Market ID.
     * @return decay_ Amount of debt to subtract, in HOOD decimals.
     */
    function debtDecay(uint256 _id) public view returns (uint64 decay_) {
        Metadata memory meta = metadata[_id];

        uint256 secondsSince = block.timestamp - meta.lastDecay;
        decay_ = uint64((uint256(markets[_id].totalDebt) * secondsSince) / meta.length);

        uint64 total = markets[_id].totalDebt;
        if (decay_ > total) decay_ = total;
    }

    /**
     * @notice Whether a market is currently accepting deposits.
     * @param _id Market ID.
     * @return True when capacity remains and the conclusion is in the future.
     */
    function isLive(uint256 _id) public view returns (bool) {
        if (_id >= markets.length) return false;
        return markets[_id].capacity != 0 && terms[_id].conclusion > block.timestamp;
    }

    /**
     * @notice IDs of every market that is currently live.
     * @return Array of live market IDs.
     */
    function liveMarkets() external view returns (uint256[] memory) {
        uint256 total = markets.length;

        uint256 num;
        for (uint256 i; i < total; ++i) {
            if (isLive(i)) ++num;
        }

        uint256[] memory ids = new uint256[](num);
        uint256 nonce;
        for (uint256 i; i < total; ++i) {
            if (isLive(i)) {
                ids[nonce] = i;
                ++nonce;
            }
        }

        return ids;
    }

    /**
     * @notice IDs of every live market that accepts a given quote token.
     * @param _token Quote token address.
     * @return Array of live market IDs for that token.
     */
    function liveMarketsFor(address _token) external view returns (uint256[] memory) {
        uint256[] memory mkts = marketsForQuote[_token];
        uint256 total = mkts.length;

        uint256 num;
        for (uint256 i; i < total; ++i) {
            if (isLive(mkts[i])) ++num;
        }

        uint256[] memory ids = new uint256[](num);
        uint256 nonce;
        for (uint256 i; i < total; ++i) {
            if (isLive(mkts[i])) {
                ids[nonce] = mkts[i];
                ++nonce;
            }
        }

        return ids;
    }

    /**
     * @notice Number of markets ever created.
     * @return Length of the market array; also the ID of the next market.
     */
    function marketCount() external view returns (uint256) {
        return markets.length;
    }

    /* ========== INTERNAL VIEW ========== */

    /**
     * @notice Market price using storage values, for use after a decay has been applied.
     * @param _id Market ID.
     * @return Price in HOOD decimals.
     */
    function _marketPrice(uint256 _id) internal view returns (uint256) {
        return (uint256(terms[_id].controlVariable) * _debtRatio(_id)) / (10 ** metadata[_id].quoteDecimals);
    }

    /**
     * @notice Debt ratio using storage values, for use after a decay has been applied.
     * @param _id Market ID.
     * @return Debt ratio.
     */
    function _debtRatio(uint256 _id) internal view returns (uint256) {
        return (uint256(markets[_id].totalDebt) * (10 ** metadata[_id].quoteDecimals)) / treasury.baseSupply();
    }

    /**
     * @notice Amount of a pending control-variable adjustment that has come due.
     * @param _id Market ID.
     * @return decay_        Control variable decrease to apply now.
     * @return secondsSince_ Seconds since the adjustment was last applied.
     * @return active_       True when the adjustment still has time left to run.
     */
    function _controlDecay(uint256 _id)
        internal
        view
        returns (uint64 decay_, uint48 secondsSince_, bool active_)
    {
        Adjustment memory info = adjustments[_id];
        if (!info.active) return (0, 0, false);

        secondsSince_ = uint48(block.timestamp) - info.lastAdjustment;

        active_ = secondsSince_ < info.timeToAdjusted;
        decay_ = active_ ? uint64((uint256(info.change) * secondsSince_) / info.timeToAdjusted) : info.change;
    }
}
