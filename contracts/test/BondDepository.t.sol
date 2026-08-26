// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @dev UNAUDITED. Do not use in production without a full audit.

import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IHoodzAuthority} from "../src/interfaces/IHoodzAuthority.sol";
import {IHOODZ} from "../src/interfaces/IHOODZ.sol";
import {IgHOODZ} from "../src/interfaces/IgHOODZ.sol";
import {IStaking} from "../src/interfaces/IStaking.sol";
import {ITreasury} from "../src/interfaces/ITreasury.sol";
import {BondDepository} from "../src/policies/BondDepository.sol";
import {HoodzTreasury} from "../src/HoodzTreasury.sol";

import {HoodzStackSetup} from "./utils/HoodzStackSetup.sol";

/// @title  BondDepositoryTest
/// @notice The sequential dutch auction: create a market, deposit into it, watch debt decay the
///         price down and demand push it back up, then redeem the vested payout.
/// @dev    Market sizing here is deliberate rather than arbitrary, because the depository's own
///         formulas constrain it:
///           * price is in HOODZ decimals, so 1e9 means "one quote token buys one HOODZ"
///             (the quote token is the 18-decimal reserve);
///           * `controlVariable = price * baseSupply / targetDebt` is stored in a uint64, so the
///             base supply must not dwarf the capacity by too many orders of magnitude;
///           * `maxPayout = targetDebt * depositInterval / duration` caps a single deposit, so
///             the deposit interval has to be a real fraction of the market length.
///         The base supply is seeded two orders of magnitude above capacity so that a bond moves
///         the debt ratio (numerator) far more than it moves the base supply (denominator) -
///         otherwise a deposit that mints its own payout would leave the price unchanged.
contract BondDepositoryTest is HoodzStackSetup {
    BondDepository internal depo;

    uint256 internal marketId;

    /// @dev Capacity in HOODZ (`capacityInQuote == false`): 100k HOODZ.
    uint256 internal constant CAPACITY = 100_000e9;
    /// @dev Initial price in HOODZ decimals: parity, one reserve token per HOODZ.
    uint256 internal constant INITIAL_PRICE = 1e9;
    /// @dev Max-debt buffer above target, 1e5 denominator. 100_000 == +100%.
    uint256 internal constant DEBT_BUFFER = 100_000;
    /// @dev HOODZ supply seeded before the market opens, so the debt ratio is well defined.
    uint256 internal constant SEEDED_SUPPLY = 10_000_000e9;

    uint256 internal constant VESTING = 7 days;
    uint256 internal constant DURATION = 20 days;
    uint32 internal constant DEPOSIT_INTERVAL = 2 days;
    uint32 internal constant TUNE_INTERVAL = 2 days;

    /// @dev `targetDebt * DEPOSIT_INTERVAL / DURATION` == 10k HOODZ; every bond below stays under.
    uint256 internal constant MAX_PAYOUT = (CAPACITY * DEPOSIT_INTERVAL) / DURATION;

    function setUp() public {
        _deployHoodzStack();

        // Backing to mint bond payouts from, plus a live HOODZ supply: `debtRatio` divides by
        // `treasury.baseSupply()`, so it must be non-zero before any market is priced.
        _fundTreasury(50_000_000e18);
        _depositForHoodz(10_000_000e18, 0);
        assertEq(treasury.baseSupply(), SEEDED_SUPPLY, "seeded base supply");

        depo = new BondDepository(
            IHoodzAuthority(address(authority)),
            IHOODZ(address(hoodz)),
            IgHOODZ(address(gHoodz)),
            IStaking(address(staking)),
            ITreasury(address(treasury))
        );
        vm.label(address(depo), "BondDepository");

        treasury.enable(HoodzTreasury.STATUS.REWARDMANAGER, address(depo), address(0));

        // Front end and DAO rewards off: they mint extra HOODZ on every deposit and would only
        // add noise to the price and payout assertions below.
        depo.setRewards(0, 0);

        marketId = _createMarket();
    }

    /*//////////////////////////////////////////////////////////////
                                 CREATE
    //////////////////////////////////////////////////////////////*/

    function test_CreatedMarketIsLive() public view {
        assertTrue(depo.isLive(marketId), "the market must be live at creation");

        uint256[] memory live = depo.liveMarkets();
        assertEq(live.length, 1, "exactly one live market");
        assertEq(live[0], marketId);
        assertEq(depo.marketCount(), 1);
    }

    /// @dev A freshly created market quotes exactly the price it was created at: initial debt is
    ///      set to capacity and the control variable is solved backwards from the price.
    function test_MarketOpensAtTheRequestedPrice() public view {
        assertEq(depo.marketPrice(marketId), INITIAL_PRICE, "market must open at its initial price");
        assertEq(depo.currentDebt(marketId), CAPACITY, "initial debt equals capacity");
    }

    function test_PayoutForIsLinearInSize() public view {
        assertEq(depo.payoutFor(1_000e18, marketId), 1_000e9, "1 reserve buys 1 HOODZ at parity");
        assertEq(depo.payoutFor(100e18, marketId) * 10, depo.payoutFor(1_000e18, marketId), "linear in size");
    }

    function test_RevertWhen_NonPolicyCreatesMarket() public {
        vm.prank(alice);
        vm.expectRevert(); // create() is onlyPolicy
        _createMarket();
    }

    /*//////////////////////////////////////////////////////////////
                                 DEPOSIT
    //////////////////////////////////////////////////////////////*/

    function test_DepositMintsAndStakesThePayout() public {
        uint256 amount = 1_000e18;
        uint256 quoted = depo.payoutFor(amount, marketId);
        uint256 gBefore = gHoodz.balanceOf(address(depo));

        (uint256 payout, uint256 expiry, uint256 index) = _bond(alice, amount);

        assertEq(payout, quoted, "payout must match the quote");
        assertEq(payout, 1_000e9);
        assertEq(expiry, block.timestamp + VESTING, "fixed-term vesting");
        assertEq(index, 0, "alice's first note");

        // The payout is minted, staked, and held as gHOODZ until the note is redeemed.
        assertEq(gHoodz.balanceOf(address(depo)) - gBefore, gHoodz.balanceTo(payout), "payout must be staked");
        assertEq(hoodz.balanceOf(alice), 0, "the bonder receives a note, not loose HOODZ");
        assertEq(hoodz.balanceOf(address(depo)), 0, "no HOODZ should be left idle in the depository");
    }

    function test_DepositSendsTheQuoteTokenToTheTreasury() public {
        uint256 treasuryBefore = reserve.balanceOf(address(treasury));

        _bond(alice, 1_000e18);

        assertEq(reserve.balanceOf(address(treasury)) - treasuryBefore, 1_000e18, "payment goes to the treasury");
        assertEq(reserve.balanceOf(address(depo)), 0, "the depository must not hold quote tokens");
    }

    function test_DepositConsumesCapacityAndBooksDebt() public {
        uint256 debtBefore = depo.currentDebt(marketId);

        (uint256 payout,,) = _bond(alice, 5_000e18);

        assertEq(depo.currentDebt(marketId) - debtBefore, payout, "the payout is booked as debt");
    }

    function test_RevertWhen_PriceExceedsMaxPrice() public {
        reserve.mint(alice, 1_000e18);

        vm.startPrank(alice);
        reserve.approve(address(depo), 1_000e18);
        vm.expectRevert(); // Depository_MoreThanMaxPrice
        depo.deposit(marketId, 1_000e18, 1, alice, address(0));
        vm.stopPrank();
    }

    /// @dev A single deposit may not exceed `maxPayout`; the market is sized by interval, not by
    ///      slippage, so oversized bonds are rejected rather than repriced.
    function test_RevertWhen_DepositExceedsMaxPayout() public {
        uint256 tooBig = (MAX_PAYOUT * 2) / 1e9 * 1e18; // twice the interval cap, in quote terms

        reserve.mint(alice, tooBig);
        vm.startPrank(alice);
        reserve.approve(address(depo), tooBig);
        vm.expectRevert(); // Depository_MaxSizeExceeded
        depo.deposit(marketId, tooBig, type(uint256).max, alice, address(0));
        vm.stopPrank();
    }

    function test_RevertWhen_DepositingIntoAClosedMarket() public {
        depo.close(marketId);
        assertFalse(depo.isLive(marketId));

        reserve.mint(alice, 100e18);
        vm.startPrank(alice);
        reserve.approve(address(depo), 100e18);
        vm.expectRevert(); // capacity is zero, the deposit cannot be filled
        depo.deposit(marketId, 100e18, type(uint256).max, alice, address(0));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                              PRICE & DEBT
    //////////////////////////////////////////////////////////////*/

    /// @dev With no demand, debt decays linearly over the market length and the price follows it
    ///      down. That is the entire auction.
    function test_PriceDecaysWhileTheMarketIsIdle() public {
        uint256 priceStart = depo.marketPrice(marketId);
        uint256 debtStart = depo.currentDebt(marketId);

        vm.warp(block.timestamp + DURATION / 4); // a quarter of the way through

        assertApproxEqRel(depo.currentDebt(marketId), (debtStart * 3) / 4, 1e14, "a quarter of the debt decayed");
        assertLt(depo.marketPrice(marketId), priceStart, "price must fall with debt");
    }

    /// @dev Demand raises debt, and debt raises the price of the next bond.
    function test_DepositRaisesTheMarketPrice() public {
        uint256 priceBefore = depo.marketPrice(marketId);

        _bond(alice, 5_000e18); // +5% debt against a base supply that barely moves

        assertGt(depo.marketPrice(marketId), priceBefore, "a bond must raise the price");
        assertGt(depo.debtRatio(marketId), 0, "the bond must show up in the debt ratio");
    }

    /// @dev A cheaper price buys more HOODZ per quote token - the incentive to wait.
    function test_PayoutImprovesAsThePriceDecays() public {
        uint256 payoutNow = depo.payoutFor(1_000e18, marketId);

        vm.warp(block.timestamp + 4 days);

        assertGt(depo.payoutFor(1_000e18, marketId), payoutNow, "a decayed price must pay out more");
    }

    /// @dev Tuning re-targets the control variable when a market is running behind its capacity
    ///      schedule. An idle market that is poked after its tune interval must end up cheaper
    ///      than it was at its peak.
    function test_TuneLowersThePriceOfAnUndersoldMarket() public {
        _bond(alice, 5_000e18);
        uint256 pricePeak = depo.marketPrice(marketId);

        // Sit idle past the tune interval, then poke the market so `_decay` and `_tune` both run.
        vm.warp(block.timestamp + TUNE_INTERVAL + 2 days);
        _bond(bob, 1e18); // dust, just enough to trigger the internal bookkeeping

        assertLt(depo.marketPrice(marketId), pricePeak, "an undersold market must tune down");
    }

    function test_DebtDecayIsCappedAtTotalDebt() public {
        vm.warp(block.timestamp + DURATION * 2);

        assertLe(depo.debtDecay(marketId), CAPACITY, "decay can never exceed the debt it applies to");
        assertEq(depo.currentDebt(marketId), 0, "a fully elapsed market has no debt left");
    }

    /*//////////////////////////////////////////////////////////////
                             VESTING & REDEEM
    //////////////////////////////////////////////////////////////*/

    function test_NoteMaturesOnlyAfterVesting() public {
        (uint256 payout,, uint256 index) = _bond(alice, 1_000e18);

        (uint256 pending, bool matured) = depo.pendingFor(alice, index);
        assertEq(pending, gHoodz.balanceTo(payout), "the note is denominated in gHOODZ");
        assertFalse(matured, "not matured before vesting");

        vm.warp(block.timestamp + VESTING);

        (, matured) = depo.pendingFor(alice, index);
        assertTrue(matured, "matured once vesting has elapsed");
    }

    function test_RedeemPaysTheBonderInGHoodz() public {
        (,, uint256 index) = _bond(alice, 1_000e18);

        vm.warp(block.timestamp + VESTING);

        uint256[] memory indexes = new uint256[](1);
        indexes[0] = index;

        vm.prank(alice);
        uint256 redeemed = depo.redeem(alice, indexes, true);

        assertGt(redeemed, 0, "redeem must pay out");
        assertEq(gHoodz.balanceOf(alice), redeemed, "alice holds the gHOODZ");

        (uint256 pending,) = depo.pendingFor(alice, index);
        assertEq(pending, 0, "the note is spent");
    }

    function test_RedeemBeforeVestingPaysNothing() public {
        (,, uint256 index) = _bond(alice, 1_000e18);

        uint256[] memory indexes = new uint256[](1);
        indexes[0] = index;

        vm.prank(alice);
        uint256 redeemed = depo.redeem(alice, indexes, false);

        assertEq(redeemed, 0, "an unmatured note pays nothing and does not revert");
        assertEq(gHoodz.balanceOf(alice), 0);
    }

    /// @dev The payout is staked the moment it is minted, so a note that vests across several
    ///      epochs is worth more HOODZ when it is redeemed than it was when it was bought.
    function test_BondAccruesRebasesWhileVesting() public {
        (uint256 payout,, uint256 index) = _bond(alice, 1_000e18);

        _rollEpochs(8);
        vm.warp(block.timestamp + VESTING);

        uint256[] memory indexes = new uint256[](1);
        indexes[0] = index;

        vm.prank(alice);
        uint256 redeemed = depo.redeem(alice, indexes, true);

        assertGt(gHoodz.balanceFrom(redeemed), payout, "a vesting bond must earn the rebase");
        console2.log("payout at purchase:", payout);
        console2.log("value at redemption:", gHoodz.balanceFrom(redeemed));
    }

    /*//////////////////////////////////////////////////////////////
                               CONCLUSION
    //////////////////////////////////////////////////////////////*/

    function test_MarketStopsAtConclusion() public {
        vm.warp(block.timestamp + DURATION + 1);

        assertFalse(depo.isLive(marketId), "a concluded market is not live");
        assertEq(depo.liveMarkets().length, 0, "and is delisted");
    }

    function test_PolicyCanCloseEarly() public {
        depo.close(marketId);

        assertFalse(depo.isLive(marketId));
        assertEq(depo.liveMarkets().length, 0);
    }

    function test_RevertWhen_NonPolicyCloses() public {
        vm.prank(alice);
        vm.expectRevert();
        depo.close(marketId);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Opens the market described by the constants at the top of this file.
    function _createMarket() internal returns (uint256) {
        uint256[3] memory market = [CAPACITY, INITIAL_PRICE, DEBT_BUFFER];
        bool[2] memory booleans = [false, true]; // [capacityInQuote, fixedTerm]
        uint256[2] memory terms = [VESTING, block.timestamp + DURATION];
        uint32[2] memory intervals = [DEPOSIT_INTERVAL, TUNE_INTERVAL];

        return depo.create(IERC20(address(reserve)), market, booleans, terms, intervals);
    }

    /// @dev Buys a bond for `user_` with `amount_` of the quote token and no slippage limit.
    /// @return payout HOODZ owed by the new note.
    /// @return expiry Timestamp the note matures.
    /// @return index Index of the note in the user's note array.
    function _bond(address user_, uint256 amount_)
        internal
        returns (uint256 payout, uint256 expiry, uint256 index)
    {
        reserve.mint(user_, amount_);
        vm.startPrank(user_);
        reserve.approve(address(depo), amount_);
        (payout, expiry, index) = depo.deposit(marketId, amount_, type(uint256).max, user_, address(0));
        vm.stopPrank();
    }
}
