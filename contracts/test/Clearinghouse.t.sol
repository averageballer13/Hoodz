// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @dev UNAUDITED. Do not use in production without a full audit.

import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HoodzTreasury} from "../src/HoodzTreasury.sol";
import {IHoodzAuthority} from "../src/interfaces/IHoodzAuthority.sol";
import {ICooler} from "../src/interfaces/ICooler.sol";
import {CoolerFactory} from "../src/loans/CoolerFactory.sol";
import {Clearinghouse} from "../src/loans/Clearinghouse.sol";

import {HoodzStackSetup} from "./utils/HoodzStackSetup.sol";

/// @title  ClearinghouseTest
/// @notice Hoodz Loans end to end: lend reserve against gHOODZ, roll a loan forward, let one
///         default, burn the seized collateral, and keep the policy's funding in step with the
///         treasury.
/// @dev    Amounts are derived from the clearinghouse's own terms (`FUND_AMOUNT`,
///         `loanToCollateral()`, `DURATION`, `INTEREST_RATE`) rather than hard-coded, so the
///         suite keeps meaning the same thing if the DAO picks different numbers. Loan state is
///         asserted through balances and receivables rather than through the `Cooler.Loan`
///         struct, which keeps the tests independent of that struct's layout.
contract ClearinghouseTest is HoodzStackSetup {
    CoolerFactory internal factory;
    Clearinghouse internal clearinghouse;
    ICooler internal cooler;

    uint256 internal loanAmount;

    function setUp() public {
        _deployHoodzStack();

        // Deep excess reserves: the clearinghouse funds itself out of them via `rebalance`.
        _fundTreasury(200_000_000e18);

        factory = new CoolerFactory();
        clearinghouse = new Clearinghouse(
            address(gHoodz),
            address(hoodz),
            address(staking),
            address(reserve),
            address(savings),
            address(treasury),
            address(factory),
            IHoodzAuthority(address(authority))
        );
        vm.label(address(factory), "CoolerFactory");
        vm.label(address(clearinghouse), "Clearinghouse");

        // `rebalance` pulls with `manage` and pushes back with `deposit`, so both are needed.
        treasury.enable(HoodzTreasury.STATUS.RESERVEMANAGER, address(clearinghouse), address(0));
        treasury.enable(HoodzTreasury.STATUS.RESERVEDEPOSITOR, address(clearinghouse), address(0));
        treasury.enable(HoodzTreasury.STATUS.RESERVEDEBTOR, address(clearinghouse), address(0));

        // Draw the first tranche of funding.
        clearinghouse.rebalance();

        loanAmount = clearinghouse.FUND_AMOUNT() / 10;

        // Alice stakes three times the HOODZ she needs as collateral, leaving room for a roll.
        _stakeToG(alice, gHoodz.balanceFrom(_collateralFor(loanAmount)) * 3);

        vm.prank(alice);
        cooler = ICooler(factory.generateCooler(IERC20(address(gHoodz)), IERC20(address(reserve))));
        vm.label(address(cooler), "AliceCooler");
    }

    /*//////////////////////////////////////////////////////////////
                                  TERMS
    //////////////////////////////////////////////////////////////*/

    function test_TermsAreSane() public view {
        assertGt(clearinghouse.loanToCollateral(), 0, "a loan must be collateralised");
        assertGt(clearinghouse.DURATION(), 0, "a loan must expire");
        assertLt(clearinghouse.INTEREST_RATE(), 1e18, "interest must be a fraction, not a multiple");
        assertGt(clearinghouse.FUND_AMOUNT(), 0);
        assertGt(clearinghouse.FUND_CADENCE(), 0);
        assertTrue(clearinghouse.active(), "a fresh clearinghouse is open for business");
    }

    /// @dev The offered loan-to-collateral drips upward over time - backing per gHOODZ grows -
    ///      and is capped so a single term can never lever past the DAO's risk budget.
    function test_LoanToCollateralDripsUpwardAndIsCapped() public {
        uint256 atLaunch = clearinghouse.loanToCollateral();
        assertEq(atLaunch, clearinghouse.OLTC_BASE(), "starts at the base rate");

        vm.warp(block.timestamp + 365 days);
        uint256 afterAYear = clearinghouse.loanToCollateral();

        uint256 expectedDrip = (clearinghouse.OLTC_BASE() * clearinghouse.OLTC_GROWTH_PER_YEAR()) / 1e18;
        assertApproxEqRel(afterAYear, atLaunch + expectedDrip, 1e14, "one year of drip");

        vm.warp(block.timestamp + 100 * 365 days);
        assertEq(clearinghouse.loanToCollateral(), clearinghouse.OLTC_MAX(), "capped at OLTC_MAX");
    }

    function test_InterestForLoanIsLinearInPrincipalAndDuration() public view {
        uint256 duration = clearinghouse.DURATION();
        uint256 base = clearinghouse.interestForLoan(loanAmount, duration);

        assertGt(base, 0, "a loan must charge interest");
        assertEq(clearinghouse.interestForLoan(2 * loanAmount, duration), 2 * base, "linear in principal");
        assertEq(clearinghouse.interestForLoan(loanAmount, 2 * duration), 2 * base, "linear in duration");
    }

    /*//////////////////////////////////////////////////////////////
                                 FACTORY
    //////////////////////////////////////////////////////////////*/

    function test_FactoryTracksTheCoolersItCreated() public view {
        assertTrue(factory.created(address(cooler)), "the factory must recognise its own escrow");
        assertEq(
            factory.getCoolerFor(alice, address(gHoodz), address(reserve)),
            address(cooler),
            "one escrow per owner/collateral/debt triple"
        );
        assertEq(cooler.owner(), alice, "alice owns her escrow");
        assertEq(address(cooler.collateral()), address(gHoodz));
        assertEq(address(cooler.debt()), address(reserve));
    }

    /// @dev An escrow this factory never created must be rejected before any value moves.
    function test_RevertWhen_LendingToAForeignCooler() public {
        ICooler rogue = ICooler(makeAddr("rogueCooler"));

        vm.prank(alice);
        vm.expectRevert(); // OnlyFromFactory
        clearinghouse.lendToCooler(rogue, 1e18);
    }

    /// @dev Only the escrow owner may draw against it - otherwise a third party could post
    ///      collateral and send the borrowed reserve to someone else's address.
    function test_RevertWhen_LendingAgainstSomeoneElsesCooler() public {
        vm.prank(bob);
        vm.expectRevert(); // OnlyBorrower
        clearinghouse.lendToCooler(cooler, loanAmount);
    }

    /*//////////////////////////////////////////////////////////////
                                  LEND
    //////////////////////////////////////////////////////////////*/

    function test_LendPaysTheBorrowerAndEscrowsTheCollateral() public {
        uint256 collateral = _collateralFor(loanAmount);
        uint256 gBefore = gHoodz.balanceOf(alice);

        _lend(loanAmount);

        assertEq(reserve.balanceOf(alice), loanAmount, "the borrower receives the debt token");
        assertEq(gBefore - gHoodz.balanceOf(alice), collateral, "collateral left the borrower");
        assertEq(gHoodz.balanceOf(address(cooler)), collateral, "collateral is escrowed in the cooler");
        assertEq(gHoodz.balanceOf(address(clearinghouse)), 0, "the policy holds no collateral itself");
    }

    function test_LendBooksReceivables() public {
        uint256 expectedInterest = clearinghouse.interestForLoan(loanAmount, clearinghouse.DURATION());

        _lend(loanAmount);

        assertEq(clearinghouse.principalReceivables(), loanAmount, "principal booked");
        assertEq(clearinghouse.interestReceivables(), expectedInterest, "interest booked");
        assertEq(clearinghouse.totalReceivables(), loanAmount + expectedInterest);
    }

    function test_LendDrawsDownTheFundedBalance() public {
        uint256 before_ = clearinghouse.reserveBalance();

        _lend(loanAmount);

        assertApproxEqRel(before_ - clearinghouse.reserveBalance(), loanAmount, 1e14, "lending spends the funding");
    }

    function test_DebtForCollateralMatchesTheOfferedTerms() public view {
        uint256 collateral = 1e18; // one gHOODZ
        assertEq(clearinghouse.debtForCollateral(collateral), clearinghouse.loanToCollateral(), "one gHOODZ of debt");
    }

    /*//////////////////////////////////////////////////////////////
                                  REPAY
    //////////////////////////////////////////////////////////////*/

    function test_RepayInFullReleasesTheCollateral() public {
        uint256 collateral = _collateralFor(loanAmount);
        uint256 loanID = _lend(loanAmount);

        uint256 interest = clearinghouse.interestForLoan(loanAmount, clearinghouse.DURATION());
        uint256 owed = loanAmount + interest;

        reserve.mint(alice, interest); // alice must service the interest on top of the principal
        uint256 gBefore = gHoodz.balanceOf(alice);

        vm.startPrank(alice);
        reserve.approve(address(cooler), owed);
        cooler.repayLoan(loanID, owed);
        vm.stopPrank();

        assertEq(gHoodz.balanceOf(alice) - gBefore, collateral, "all collateral returned");
        assertEq(gHoodz.balanceOf(address(cooler)), 0, "escrow emptied");
        assertEq(reserve.balanceOf(alice), 0, "alice paid principal plus interest");
    }

    /// @dev Repayment settles interest first, then principal, and frees collateral strictly in
    ///      proportion to the principal retired - never ahead of it.
    function test_PartialRepaymentReleasesProRata() public {
        uint256 collateral = _collateralFor(loanAmount);
        uint256 loanID = _lend(loanAmount);

        uint256 interest = clearinghouse.interestForLoan(loanAmount, clearinghouse.DURATION());
        uint256 owed = loanAmount + interest;
        uint256 half = owed / 2;

        reserve.mint(alice, interest);
        uint256 gBefore = gHoodz.balanceOf(alice);

        vm.startPrank(alice);
        reserve.approve(address(cooler), half);
        cooler.repayLoan(loanID, half);
        vm.stopPrank();

        uint256 released = gHoodz.balanceOf(alice) - gBefore;
        assertLt(released, collateral, "a partial repayment must not free everything");
        assertApproxEqRel(released, collateral / 2, 1e16, "roughly half the debt frees half the collateral");
    }

    /// @dev The escrow calls back into the policy on repayment, which is what keeps the DAO's
    ///      receivables honest without an off-chain accountant.
    function test_RepaymentWritesDownReceivables() public {
        uint256 loanID = _lend(loanAmount);
        uint256 interest = clearinghouse.interestForLoan(loanAmount, clearinghouse.DURATION());

        reserve.mint(alice, interest);

        vm.startPrank(alice);
        reserve.approve(address(cooler), loanAmount + interest);
        cooler.repayLoan(loanID, loanAmount + interest);
        vm.stopPrank();

        assertEq(clearinghouse.principalReceivables(), 0, "principal written down");
        assertEq(clearinghouse.interestReceivables(), 0, "interest written down");
        assertGt(clearinghouse.reserveBalance(), 0, "the repayment landed back in the policy");
    }

    function test_RevertWhen_RepayingAfterExpiry() public {
        uint256 loanID = _lend(loanAmount);
        uint256 interest = clearinghouse.interestForLoan(loanAmount, clearinghouse.DURATION());

        vm.warp(block.timestamp + clearinghouse.DURATION() + 1);
        reserve.mint(alice, interest);

        vm.startPrank(alice);
        reserve.approve(address(cooler), loanAmount + interest);
        vm.expectRevert(); // Defaulted: an expired loan can only be claimed, never repaid
        cooler.repayLoan(loanID, loanAmount + interest);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                  ROLL
    //////////////////////////////////////////////////////////////*/

    /// @dev Rolling buys another full term for one term of interest. While the offered oLTC is
    ///      drifting upward the collateral top-up is zero, which is what makes a Hoodz Loan
    ///      perpetual for a borrower who keeps servicing it.
    function test_RollLoanExtendsTheTermWithoutMoreCollateral() public {
        uint256 collateral = _collateralFor(loanAmount);
        uint256 loanID = _lend(loanAmount);

        uint256 interestBefore = clearinghouse.interestReceivables();

        // Sit almost to expiry, then roll. The escrow pulls any top-up from the owner, so alice
        // approves the escrow rather than the policy.
        vm.warp(block.timestamp + clearinghouse.DURATION() - 1 days);

        vm.startPrank(alice);
        gHoodz.approve(address(cooler), type(uint256).max);
        clearinghouse.rollLoan(cooler, loanID);
        vm.stopPrank();

        assertGt(clearinghouse.interestReceivables(), interestBefore, "a roll books another term of interest");
        assertEq(gHoodz.balanceOf(address(cooler)), collateral, "no top-up while the oLTC drips up");

        // Past the original expiry the loan must no longer be claimable.
        vm.warp(block.timestamp + 2 days);
        assertFalse(cooler.hasExpired(loanID), "the roll pushed the expiry out");

        vm.expectRevert(); // NoDefault
        _claimDefault(loanID);
    }

    function test_RevertWhen_RollingSomeoneElsesLoan() public {
        uint256 loanID = _lend(loanAmount);

        vm.prank(bob);
        vm.expectRevert(); // OnlyBorrower
        clearinghouse.rollLoan(cooler, loanID);
    }

    /*//////////////////////////////////////////////////////////////
                                 DEFAULT
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_ClaimingBeforeExpiry() public {
        uint256 loanID = _lend(loanAmount);

        vm.prank(bob);
        vm.expectRevert(); // NoDefault
        _claimDefault(loanID);
    }

    /// @dev There is no liquidation and no auction: at expiry the DAO simply keeps the gHOODZ and
    ///      writes the loan off. The borrower keeps every reserve token they drew.
    function test_DefaultSeizesCollateralAndWritesOffTheLoan() public {
        uint256 collateral = _collateralFor(loanAmount);
        uint256 loanID = _lend(loanAmount);

        vm.warp(block.timestamp + clearinghouse.DURATION() + 8 days);

        vm.prank(bob); // defaults are permissionless to claim; bob is the keeper
        _claimDefault(loanID);

        assertEq(gHoodz.balanceOf(address(cooler)), 0, "collateral seized");
        assertEq(clearinghouse.principalReceivables(), 0, "principal written off");
        assertEq(clearinghouse.interestReceivables(), 0, "interest written off");
        assertEq(reserve.balanceOf(alice), loanAmount, "the borrower keeps the reserve they drew");

        uint256 keeperReward = gHoodz.balanceOf(bob);
        assertEq(gHoodz.balanceOf(address(clearinghouse)), collateral - keeperReward, "the DAO keeps the rest");
    }

    /// @dev The keeper bounty ramps from zero over the first week after expiry, so nobody can
    ///      profitably race the borrower at the exact expiry block.
    function test_KeeperRewardRampsAfterExpiry() public {
        uint256 loanID = _lend(loanAmount);

        vm.warp(block.timestamp + clearinghouse.DURATION() + 1);

        vm.prank(bob);
        _claimDefault(loanID);

        assertLt(gHoodz.balanceOf(bob), clearinghouse.MAX_REWARD() / 100, "almost nothing at the expiry block");
    }

    function test_KeeperRewardIsCappedAtMaxReward() public {
        uint256 loanID = _lend(loanAmount);

        vm.warp(block.timestamp + clearinghouse.DURATION() + 8 days);

        vm.prank(bob);
        _claimDefault(loanID);

        assertEq(gHoodz.balanceOf(bob), clearinghouse.MAX_REWARD(), "the full, capped bounty");
    }

    /// @dev Seized collateral leaves the policy only by being destroyed. That burn is what makes
    ///      a defaulted Hoodz Loan deflationary for everyone still holding HOODZ.
    function test_BurnDestroysSeizedCollateral() public {
        uint256 loanID = _lend(loanAmount);
        vm.warp(block.timestamp + clearinghouse.DURATION() + 8 days);

        vm.prank(bob);
        _claimDefault(loanID);

        uint256 supplyBefore = hoodz.totalSupply();
        uint256 seized = gHoodz.balanceOf(address(clearinghouse));

        uint256 burned = clearinghouse.burn();

        assertEq(gHoodz.balanceOf(address(clearinghouse)), 0, "all seized collateral unwound");
        assertEq(supplyBefore - hoodz.totalSupply(), burned, "and burned, one for one");
        assertApproxEqRel(burned, gHoodz.balanceFrom(seized), 1e12, "burned the HOODZ the gHOODZ was worth");
        console2.log("HOODZ burned on default:", burned);
    }

    function test_RevertWhen_DefundingCollateral() public {
        vm.expectRevert(); // OnlyBurnable: gHOODZ may never be swept out
        clearinghouse.defund(IERC20(address(gHoodz)), 1);
    }

    /*//////////////////////////////////////////////////////////////
                                REBALANCE
    //////////////////////////////////////////////////////////////*/

    function test_RebalanceFundsUpToFundAmount() public view {
        assertApproxEqRel(
            clearinghouse.reserveBalance(), clearinghouse.FUND_AMOUNT(), 1e14, "topped up to FUND_AMOUNT"
        );
    }

    function test_RebalanceIsRateLimited() public {
        _lend(loanAmount);
        uint256 heldAfterLend = clearinghouse.reserveBalance();
        assertLt(heldAfterLend, clearinghouse.FUND_AMOUNT(), "lending drew the balance down");

        assertFalse(clearinghouse.rebalance(), "a rebalance inside the cadence must be a no-op");
        assertEq(clearinghouse.reserveBalance(), heldAfterLend, "balance unchanged");
    }

    function test_RebalanceTopsUpAfterTheCadence() public {
        _lend(loanAmount);
        uint256 heldAfterLend = clearinghouse.reserveBalance();

        vm.warp(block.timestamp + clearinghouse.FUND_CADENCE());
        assertTrue(clearinghouse.rebalance(), "past the cadence the rebalance runs");

        assertGt(clearinghouse.reserveBalance(), heldAfterLend, "funding restored");
        assertApproxEqRel(clearinghouse.reserveBalance(), clearinghouse.FUND_AMOUNT(), 1e14);
    }

    /// @dev Idle reserve is parked in the savings vault, so the DAO earns on undrawn capacity.
    function test_IdleReserveIsParkedInTheSavingsVault() public view {
        assertEq(reserve.balanceOf(address(clearinghouse)), 0, "no idle reserve sitting loose");
        assertGt(savings.balanceOf(address(clearinghouse)), 0, "it is in the savings vault");
    }

    /*//////////////////////////////////////////////////////////////
                                SHUTDOWN
    //////////////////////////////////////////////////////////////*/

    /// @dev Shutdown stops origination and returns every reserve token immediately. Live loans
    ///      are untouched - they keep their terms and still default to the DAO at expiry.
    function test_EmergencyShutdownReturnsReservesToTheTreasury() public {
        uint256 treasuryBefore = reserve.balanceOf(address(treasury));

        vm.prank(guardian);
        clearinghouse.emergencyShutdown();

        assertFalse(clearinghouse.active(), "shutdown deactivates the policy");
        assertEq(clearinghouse.reserveBalance(), 0, "reserves returned");
        assertGt(reserve.balanceOf(address(treasury)), treasuryBefore, "the treasury got them back");
    }

    function test_RevertWhen_LendingWhileShutDown() public {
        vm.prank(guardian);
        clearinghouse.emergencyShutdown();

        vm.prank(alice);
        vm.expectRevert(); // NotActive
        clearinghouse.lendToCooler(cooler, loanAmount);
    }

    function test_RevertWhen_UnauthorisedShutdown() public {
        vm.prank(alice);
        vm.expectRevert(); // onlyGuardian
        clearinghouse.emergencyShutdown();
    }

    function test_GovernorCanReactivate() public {
        vm.prank(guardian);
        clearinghouse.emergencyShutdown();

        clearinghouse.reactivate(); // this contract is the governor
        assertTrue(clearinghouse.active());

        assertTrue(clearinghouse.rebalance(), "reactivation resets the funding clock");
        assertApproxEqRel(clearinghouse.reserveBalance(), clearinghouse.FUND_AMOUNT(), 1e14, "refunded");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev gHOODZ needed to back `principal_` at the currently offered loan-to-collateral.
    function _collateralFor(uint256 principal_) internal view returns (uint256) {
        return (principal_ * 1e18) / clearinghouse.loanToCollateral();
    }

    /// @dev Alice borrows `amount_` of reserve against gHOODZ through her escrow.
    function _lend(uint256 amount_) internal returns (uint256 loanID) {
        vm.startPrank(alice);
        gHoodz.approve(address(clearinghouse), _collateralFor(amount_));
        loanID = clearinghouse.lendToCooler(cooler, amount_);
        vm.stopPrank();
    }

    /// @dev Claims one defaulted loan through the policy, as a keeper would.
    function _claimDefault(uint256 loanID_) internal {
        address[] memory coolers = new address[](1);
        uint256[] memory loans = new uint256[](1);
        coolers[0] = address(cooler);
        loans[0] = loanID_;

        clearinghouse.claimDefaulted(coolers, loans);
    }
}
