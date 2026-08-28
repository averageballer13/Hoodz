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
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {HoodzAccessControlled} from "../types/HoodzAccessControlled.sol";
import {IHoodzAuthority} from "../interfaces/IHoodzAuthority.sol";
import {IHOOD} from "../interfaces/IHOOD.sol";
import {IgHOOD} from "../interfaces/IgHOOD.sol";
import {IStaking} from "../interfaces/IStaking.sol";
import {ITreasury} from "../interfaces/ITreasury.sol";
import {IClearinghouse} from "../interfaces/IClearinghouse.sol";
import {ICooler} from "../interfaces/ICooler.sol";
import {ICoolerCallback} from "../interfaces/ICoolerCallback.sol";
import {ICoolerFactory} from "../interfaces/ICoolerFactory.sol";
import {HoodzBurn} from "../types/HoodzBurn.sol";

/// @title  Clearinghouse
/// @notice The Hoodz side of Hoodz Loans: the policy that lends treasury reserves against
///         gHOOD at a fixed 0.5% annualised rate, with no liquidations and rollable terms.
/// @dev    UNAUDITED. Do not use in production without a full audit.
///
///         ## What the borrower gets
///         A 121-day loan against gHOOD at a hard-coded 0.5% annualised rate. Interest is
///         prepaid per term. There is no liquidation and no margin call: if the loan is not
///         repaid or rolled by expiry, the DAO simply keeps the collateral. Because the loan
///         can be rolled indefinitely, the practical term is perpetual.
///
///         ## What the DAO gets
///         A floor bid on gHOOD. Every loan is written strictly below the liquid backing per
///         gHOOD, so any default hands the treasury collateral worth more than the reserves
///         it lent. Seized gHOOD is unstaked and burned via {burn}, which is accretive to the
///         remaining holders.
///
///         ## The oLTC drip
///         `LOAN_TO_COLLATERAL` is not a constant. It is an "origination loan-to-collateral"
///         that drips upward on a pre-committed, immutable schedule, tracking the fact that
///         liquid backing per gHOOD grows as the treasury earns yield:
///
///             elapsed  = block.timestamp - oltcEpoch
///             drip     = OLTC_BASE * OLTC_GROWTH_PER_YEAR * elapsed / (1e18 * 365 days)
///             oLTC(t)  = min(OLTC_BASE + drip, OLTC_MAX)
///
///         In words: the amount of reserve lent per 1e18 gHOOD starts at `OLTC_BASE` and
///         grows linearly by `OLTC_GROWTH_PER_YEAR` (a 1e18 fraction of the base) per year,
///         until it is frozen at `OLTC_MAX`. The schedule is fixed at deployment and cannot
///         be tuned by governance, so a borrower can price a perpetual position today. It is
///         deliberately conservative: it is expected to lag real backing growth, which keeps
///         every outstanding loan over-collateralised even if the treasury underperforms.
///
///         A rising oLTC means {ICooler.newCollateralFor} returns zero at every roll, so
///         rolls are collateral-free; the surplus collateral stays locked and is released as
///         principal is repaid.
///
///         ## Funding
///         Idle reserves sit in an ERC-4626 savings vault so they keep earning while they
///         wait to be lent. {rebalance} tops the policy up to `FUND_AMOUNT` once per
///         `FUND_CADENCE`, pulling from or pushing back to the Hoodz Treasury.
contract Clearinghouse is IClearinghouse, ICoolerCallback, HoodzAccessControlled {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------------------------
    //                                      CONSTANTS
    // ---------------------------------------------------------------------------------------

    /// @notice Fixed point scalar for rates and loan-to-collateral values.
    uint256 public constant DECIMALS = 1e18;

    /// @dev Denominator of the annualised interest formula.
    uint256 private constant ONE_YEAR = 365 days;

    /// @notice Annualised interest rate charged on every loan: 0.5%, 1e18 fixed point.
    uint256 public constant INTEREST_RATE = 5e15;

    /// @notice Length of a single loan term.
    uint256 public constant DURATION = 121 days;

    /// @notice Minimum time between two {rebalance} executions.
    uint256 public constant FUND_CADENCE = 7 days;

    /// @notice Reserve balance the policy targets after every {rebalance}.
    uint256 public constant FUND_AMOUNT = 5_000_000e18;

    /// @notice Starting origination loan-to-collateral: reserve lent per 1e18 gHOOD.
    uint256 public constant OLTC_BASE = 3_000e18;

    /// @notice Linear growth of the oLTC per year, as a 1e18 fraction of `OLTC_BASE`.
    uint256 public constant OLTC_GROWTH_PER_YEAR = 5e16;

    /// @notice Hard ceiling the oLTC drip freezes at.
    uint256 public constant OLTC_MAX = 9_000e18;

    /// @notice Absolute cap on the gHOOD paid to a keeper for claiming one defaulted loan.
    uint256 public constant MAX_REWARD = 1e17;

    /// @dev Share of seized collateral a keeper may earn, 1e18 fixed point (5%).
    uint256 private constant KEEPER_SHARE = 5e16;

    /// @dev Time over which the keeper reward ramps from zero to its cap after expiry.
    uint256 private constant KEEPER_RAMP = 7 days;

    // ---------------------------------------------------------------------------------------
    //                                     IMMUTABLES
    // ---------------------------------------------------------------------------------------

    /// @notice Collateral accepted by this policy.
    IgHOOD public immutable gHOOD;

    /// @notice Governance token burned when collateral is seized.
    IHOOD public immutable hoodz;

    /// @notice Staking contract used to unwind gHOOD into HOOD before burning.
    IStaking public immutable staking;

    /// @notice Reserve asset lent to borrowers.
    IERC20 public immutable reserve;

    /// @notice ERC-4626 savings vault idle reserves are parked in.
    IERC4626 public immutable sReserve;

    /// @notice Hoodz Treasury this policy draws from and returns to.
    ITreasury public immutable treasury;

    /// @notice The only factory whose escrows this policy will lend to.
    ICoolerFactory public immutable factory;

    /// @notice Timestamp the oLTC drip is measured from.
    uint256 public immutable oltcEpoch;

    // ---------------------------------------------------------------------------------------
    //                                        STATE
    // ---------------------------------------------------------------------------------------

    /// @inheritdoc IClearinghouse
    bool public override active;

    /// @inheritdoc IClearinghouse
    uint256 public override fundTime;

    /// @inheritdoc IClearinghouse
    uint256 public override principalReceivables;

    /// @inheritdoc IClearinghouse
    uint256 public override interestReceivables;

    // ---------------------------------------------------------------------------------------
    //                                     CONSTRUCTOR
    // ---------------------------------------------------------------------------------------

    /// @notice Wires the policy to the token stack, the treasury and the escrow factory.
    /// @param  gHOOD_     Collateral token accepted by this policy.
    /// @param  hoodz_      HOOD token, burned when seized collateral is unwound.
    /// @param  staking_   Staking contract used to unstake gHOOD into HOOD.
    /// @param  reserve_   Reserve asset lent to borrowers.
    /// @param  sReserve_  ERC-4626 vault holding the reserve asset.
    /// @param  treasury_  Hoodz Treasury.
    /// @param  factory_   Trusted escrow factory.
    /// @param  authority_ HoodzAuthority granting the governor/guardian/policy roles.
    constructor(
        address gHOOD_,
        address hoodz_,
        address staking_,
        address reserve_,
        address sReserve_,
        address treasury_,
        address factory_,
        IHoodzAuthority authority_
    ) HoodzAccessControlled(authority_) {
        if (
            gHOOD_ == address(0) || hoodz_ == address(0) || staking_ == address(0) || reserve_ == address(0)
                || sReserve_ == address(0) || treasury_ == address(0) || factory_ == address(0)
        ) revert ZeroAddress();
        if (IERC4626(sReserve_).asset() != reserve_) revert BadSavingsVault();

        gHOOD = IgHOOD(gHOOD_);
        hoodz = IHOOD(hoodz_);
        staking = IStaking(staking_);
        reserve = IERC20(reserve_);
        sReserve = IERC4626(sReserve_);
        treasury = ITreasury(treasury_);
        factory = ICoolerFactory(factory_);

        oltcEpoch = block.timestamp;
        fundTime = block.timestamp;
        active = true;

        emit Activated();
    }

    // ---------------------------------------------------------------------------------------
    //                                       LENDING
    // ---------------------------------------------------------------------------------------

    /// @inheritdoc IClearinghouse
    /// @dev The borrower must have approved this policy for the gHOOD collateral. The whole
    ///      request/clear cycle happens atomically inside this call, so the escrow is never
    ///      left holding an unfilled request that a third party could interfere with.
    function lendToCooler(ICooler cooler_, uint256 amount_) external override returns (uint256 loanID) {
        if (!active) revert NotActive();
        if (amount_ == 0) revert ZeroAmount();
        _validateCooler(cooler_);
        if (cooler_.owner() != msg.sender) revert OnlyBorrower();

        // Opportunistically keep the policy funded before drawing it down.
        rebalance();

        uint256 ltc = loanToCollateral();
        uint256 collateralAmount = cooler_.collateralFor(amount_, ltc);
        uint256 interest = interestForLoan(amount_, DURATION);

        principalReceivables += amount_;
        interestReceivables += interest;

        // Escrow the collateral on behalf of the borrower.
        SafeERC20.safeTransferFrom(gHOOD, msg.sender, address(this), collateralAmount);
        SafeERC20.forceApprove(gHOOD, address(cooler_), collateralAmount);
        uint256 reqID = cooler_.requestLoan(amount_, INTEREST_RATE, ltc, DURATION);

        // Fill it with reserves, which the escrow forwards to the borrower.
        _withdrawFromSavings(amount_);
        reserve.forceApprove(address(cooler_), amount_);
        loanID = cooler_.clearRequest(reqID, true, true);

        emit Lend(address(cooler_), loanID, amount_, interest);
    }

    /// @inheritdoc IClearinghouse
    /// @dev Sets fresh terms at the current oLTC and immediately executes the roll. Any
    ///      collateral top-up is pulled from the escrow owner, so the borrower must have
    ///      approved the escrow (not this policy) for gHOOD. While the oLTC drips upward the
    ///      top-up is zero and rolling costs one term of interest and nothing else.
    function rollLoan(ICooler cooler_, uint256 loanID_) external override {
        if (!active) revert NotActive();
        _validateCooler(cooler_);
        if (cooler_.owner() != msg.sender) revert OnlyBorrower();
        if (cooler_.getLoan(loanID_).lender != address(this)) revert NotLender();

        cooler_.provideNewTermsForRoll(loanID_, INTEREST_RATE, loanToCollateral(), DURATION);
        (uint256 newCollateral, uint256 newInterest) = cooler_.rollLoan(loanID_);

        interestReceivables += newInterest;

        emit Roll(address(cooler_), loanID_, newCollateral, newInterest);
    }

    /// @inheritdoc IClearinghouse
    /// @dev Permissionless. Receivables are written down by the {onDefault} callback the
    ///      escrow fires, so this function only aggregates and pays the keeper. The seized
    ///      gHOOD stays here until someone calls {burn}.
    function claimDefaulted(address[] calldata coolers_, uint256[] calldata loans_) external override {
        uint256 length = coolers_.length;
        if (length != loans_.length) revert LengthDiscrepancy();

        uint256 totalPrincipal;
        uint256 totalInterest;
        uint256 totalCollateral;
        uint256 keeperReward;

        for (uint256 i; i < length; ++i) {
            if (!factory.created(coolers_[i])) revert OnlyFromFactory();
            // The escrow being factory-made is not enough: it says nothing about WHO funded this
            // particular loan. Without the lender check a keeper could point us at defaults on
            // loans funded by some other lender and collect a gHOOD reward out of our balance for
            // seizures we never receive.
            if (ICooler(coolers_[i]).getLoan(loans_[i]).lender != address(this)) revert NotLender();

            (uint256 seized, uint256 principal, uint256 interest, uint256 elapsed) =
                ICooler(coolers_[i]).claimDefaulted(loans_[i]);

            totalPrincipal += principal;
            totalInterest += interest;
            totalCollateral += seized;
            keeperReward += _keeperReward(seized, elapsed);
        }

        if (keeperReward != 0) SafeERC20.safeTransfer(gHOOD, msg.sender, keeperReward);

        emit Defaulted(totalPrincipal, totalInterest, totalCollateral, keeperReward);
    }

    // ---------------------------------------------------------------------------------------
    //                                      CALLBACKS
    // ---------------------------------------------------------------------------------------

    /// @inheritdoc ICoolerCallback
    function isCoolerCallback() external pure override returns (bool) {
        return true;
    }

    /// @inheritdoc ICoolerCallback
    /// @dev Repaid reserves have already landed here when this runs, so they are swept
    ///      straight into the savings vault to keep earning.
    function onRepay(uint256, uint256 principalPaid_, uint256 interestPaid_) external override {
        if (!factory.created(msg.sender)) revert OnlyFromFactory();

        principalReceivables = principalReceivables > principalPaid_ ? principalReceivables - principalPaid_ : 0;
        interestReceivables = interestReceivables > interestPaid_ ? interestReceivables - interestPaid_ : 0;

        _sweepIntoSavingsVault();
    }

    /// @inheritdoc ICoolerCallback
    /// @dev Writes the loan off. The DAO keeps collateral worth more than the written-off
    ///      principal, which is the whole point of lending below liquid backing.
    function onDefault(uint256, uint256 principal_, uint256 interestDue_, uint256) external override {
        if (!factory.created(msg.sender)) revert OnlyFromFactory();

        principalReceivables = principalReceivables > principal_ ? principalReceivables - principal_ : 0;
        interestReceivables = interestReceivables > interestDue_ ? interestReceivables - interestDue_ : 0;
    }

    // ---------------------------------------------------------------------------------------
    //                                       TREASURY
    // ---------------------------------------------------------------------------------------

    /// @inheritdoc IClearinghouse
    /// @dev Permissionless and cadence-gated. When inactive the target is zero, so repeated
    ///      calls drain the policy back into the treasury one tranche at a time.
    function rebalance() public override returns (bool) {
        if (fundTime > block.timestamp) return false;
        fundTime += FUND_CADENCE;

        uint256 target = active ? FUND_AMOUNT : 0;
        uint256 balance = reserveBalance();

        if (balance < target) {
            uint256 amount = target - balance;
            treasury.manage(address(reserve), amount);
            _sweepIntoSavingsVault();
            emit Rebalanced(amount, true);
        } else if (balance > target) {
            uint256 amount = balance - target;
            _withdrawFromSavings(amount);
            _returnToTreasury(amount);
            emit Rebalanced(amount, false);
        }

        return true;
    }

    /// @inheritdoc IClearinghouse
    function sweepIntoSavingsVault() external override returns (uint256 shares) {
        return _sweepIntoSavingsVault();
    }

    /// @inheritdoc IClearinghouse
    /// @dev gHOOD is rejected: seized collateral leaves this contract only through {burn}.
    ///      Savings vault shares are redeemed first so the treasury always books the
    ///      underlying reserve rather than a wrapper it may not price.
    function defund(IERC20 token_, uint256 amount_) external override onlyGovernor {
        if (amount_ == 0) revert ZeroAmount();
        if (address(token_) == address(gHOOD)) revert OnlyBurnable();

        if (address(token_) == address(sReserve)) {
            amount_ = sReserve.redeem(amount_, address(this), address(this));
            token_ = reserve;
        }

        if (address(token_) == address(reserve)) {
            _returnToTreasury(amount_);
        } else {
            token_.safeTransfer(address(treasury), amount_);
        }

        emit Defunded(address(token_), amount_);
    }

    /// @inheritdoc IClearinghouse
    /// @dev Stops origination and returns every reserve asset immediately. Live loans are
    ///      untouched: they keep their terms, can still be repaid, and still default to the
    ///      DAO at expiry. Rolling is disabled, so outstanding loans wind down naturally.
    function emergencyShutdown() external override onlyGuardian {
        if (!active) revert NotActive();
        active = false;

        uint256 shares = sReserve.balanceOf(address(this));
        if (shares != 0) sReserve.redeem(shares, address(this), address(this));

        uint256 balance = reserve.balanceOf(address(this));
        if (balance != 0) _returnToTreasury(balance);

        emit Deactivated();
    }

    /// @inheritdoc IClearinghouse
    function reactivate() external override onlyGovernor {
        if (active) revert AlreadyActive();
        active = true;
        fundTime = block.timestamp;
        emit Activated();
    }

    /// @inheritdoc IClearinghouse
    /// @dev Permissionless: burning seized collateral only ever benefits HOOD holders.
    function burn() external override returns (uint256 hoodzBurned) {
        uint256 balance = gHOOD.balanceOf(address(this));
        if (balance == 0) revert NothingToBurn();

        SafeERC20.forceApprove(gHOOD, address(staking), balance);
        hoodzBurned = staking.unstake(address(this), balance, false, false);
        HoodzBurn.burn(IERC20(address(hoodz)), hoodzBurned);

        emit Burned(balance, hoodzBurned);
    }

    // ---------------------------------------------------------------------------------------
    //                                         VIEWS
    // ---------------------------------------------------------------------------------------

    /// @inheritdoc IClearinghouse
    /// @dev oLTC(t) = min(OLTC_BASE + OLTC_BASE * OLTC_GROWTH_PER_YEAR * elapsed
    ///                    / (1e18 * 365 days), OLTC_MAX). See the contract NatSpec.
    function loanToCollateral() public view override returns (uint256) {
        uint256 elapsed = block.timestamp - oltcEpoch;
        uint256 drip = (OLTC_BASE * OLTC_GROWTH_PER_YEAR * elapsed) / (DECIMALS * ONE_YEAR);
        uint256 ltc = OLTC_BASE + drip;
        return ltc > OLTC_MAX ? OLTC_MAX : ltc;
    }

    /// @inheritdoc IClearinghouse
    function interestForLoan(uint256 principal_, uint256 duration_) public pure override returns (uint256) {
        uint256 periodRate = (INTEREST_RATE * duration_) / ONE_YEAR;
        return (principal_ * periodRate) / DECIMALS;
    }

    /// @inheritdoc IClearinghouse
    function debtForCollateral(uint256 collateral_) external view override returns (uint256) {
        return (collateral_ * loanToCollateral()) / DECIMALS;
    }

    /// @inheritdoc IClearinghouse
    function reserveBalance() public view override returns (uint256) {
        return reserve.balanceOf(address(this)) + sReserve.previewRedeem(sReserve.balanceOf(address(this)));
    }

    /// @inheritdoc IClearinghouse
    function totalReceivables() external view override returns (uint256) {
        return principalReceivables + interestReceivables;
    }

    // ---------------------------------------------------------------------------------------
    //                                       INTERNAL
    // ---------------------------------------------------------------------------------------

    /// @dev An escrow is only trustworthy when the trusted factory minted it AND it is pinned
    ///      to exactly the gHOOD/reserve pair this policy underwrites.
    function _validateCooler(ICooler cooler_) internal view {
        if (!factory.created(address(cooler_))) revert OnlyFromFactory();
        if (address(cooler_.collateral()) != address(gHOOD) || address(cooler_.debt()) != address(reserve)) {
            revert BadEscrow();
        }
    }

    /// @dev Park every idle reserve token in the savings vault.
    function _sweepIntoSavingsVault() internal returns (uint256 shares) {
        uint256 idle = reserve.balanceOf(address(this));
        if (idle == 0) return 0;

        reserve.forceApprove(address(sReserve), idle);
        shares = sReserve.deposit(idle, address(this));

        emit Swept(idle, shares);
    }

    /// @dev Make sure at least `amount_` reserve sits here, redeeming vault shares if needed.
    function _withdrawFromSavings(uint256 amount_) internal {
        uint256 idle = reserve.balanceOf(address(this));
        if (idle >= amount_) return;
        sReserve.withdraw(amount_ - idle, address(this), address(this));
    }

    /// @dev Push reserves back to the treasury without minting HOOD: the deposit is booked
    ///      entirely as profit, so `deposit` returns zero HOOD to this policy.
    function _returnToTreasury(uint256 amount_) internal {
        reserve.forceApprove(address(treasury), amount_);
        treasury.deposit(amount_, address(reserve), treasury.tokenValue(address(reserve), amount_));
    }

    /// @dev Keeper incentive for claiming a default: 5% of the seized collateral, capped at
    ///      `MAX_REWARD`, ramped linearly over the first week after expiry so that a keeper
    ///      cannot profitably race the borrower at the exact expiry block.
    function _keeperReward(uint256 collateral_, uint256 elapsed_) internal pure returns (uint256) {
        uint256 share = (collateral_ * KEEPER_SHARE) / DECIMALS;
        uint256 capped = share < MAX_REWARD ? share : MAX_REWARD;
        return elapsed_ < KEEPER_RAMP ? (capped * elapsed_) / KEEPER_RAMP : capped;
    }
}
