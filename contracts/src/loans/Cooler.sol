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
        X      https://x.com/hoodzdao
        Code   https://github.com/averageballer13/Hoodz

        UNAUDITED. This code has never been audited. Read it before you
        trust it with anything you would miss.
*/

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICooler} from "../interfaces/ICooler.sol";
import {ICoolerFactory} from "../interfaces/ICoolerFactory.sol";
import {ICoolerCallback} from "../interfaces/ICoolerCallback.sol";

/// @title  Cooler
/// @notice Per-borrower escrow for Hoodz Loans, the Hoodz implementation of Cooler Loans.
/// @dev    UNAUDITED. Do not use in production without a full audit.
///
///         A Cooler is a dumb, permissionless vault. It holds one collateral token, books
///         loans denominated in one debt token, and belongs to one owner. It never prices
///         anything, never liquidates and never touches an oracle: every loan carries the
///         exact terms it was written on, and the worst case for a borrower is that the
///         collateral is kept by the lender at expiry. That is the whole point of the design.
///
///         Interest is charged up front for each term:
///             interest = principal * rate * duration / 365 days / 1e18
///         with `rate` an annualised 1e18 fixed point number (5e15 == 0.5%).
///
///         Collateral is sized from the loan-to-collateral ("oLTC") of the request:
///             collateral = principal * 1e18 / loanToCollateral
///
///         Clone-friendly: this contract has no constructor. `CoolerFactory` deploys minimal
///         proxies with `Clones.cloneDeterministic` and calls {initialize} exactly once.
contract Cooler is ICooler {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------------------------
    //                                      CONSTANTS
    // ---------------------------------------------------------------------------------------

    /// @notice Fixed point scalar shared by rates and loan-to-collateral values.
    uint256 public constant DECIMALS = 1e18;

    /// @dev Denominator of the annualised interest formula.
    uint256 private constant ONE_YEAR = 365 days;

    // ---------------------------------------------------------------------------------------
    //                                        STATE
    // ---------------------------------------------------------------------------------------

    /// @inheritdoc ICooler
    address public override owner;

    /// @inheritdoc ICooler
    IERC20 public override collateral;

    /// @inheritdoc ICooler
    IERC20 public override debt;

    /// @inheritdoc ICooler
    ICoolerFactory public override factory;

    /// @inheritdoc ICooler
    mapping(uint256 => address) public override requestProvider;

    /// @inheritdoc ICooler
    mapping(uint256 => uint256) public override unclaimed;

    /// @dev Every request ever published by this escrow.
    Request[] internal _requests;

    /// @dev Every loan ever booked by this escrow.
    Loan[] internal _loans;

    // ---------------------------------------------------------------------------------------
    //                                        CONFIG
    // ---------------------------------------------------------------------------------------

    /// @inheritdoc ICooler
    /// @dev Callable once. `factory` doubles as the initialisation flag, so the implementation
    ///      contract behind the clones can be griefed into an initialised state at worst,
    ///      which is inert because the factory never registers it in `created`.
    function initialize(address owner_, IERC20 collateral_, IERC20 debt_, ICoolerFactory factory_)
        external
        override
    {
        if (address(factory) != address(0)) revert AlreadyInitialized();
        if (
            owner_ == address(0) || address(collateral_) == address(0) || address(debt_) == address(0)
                || address(factory_) == address(0)
        ) revert ZeroAddress();

        owner = owner_;
        collateral = collateral_;
        debt = debt_;
        factory = factory_;
    }

    // ---------------------------------------------------------------------------------------
    //                                       BORROWER
    // ---------------------------------------------------------------------------------------

    /// @inheritdoc ICooler
    /// @dev Permissionless on purpose: a lender policy such as `Clearinghouse` posts the
    ///      collateral it just pulled from the borrower and clears the request atomically in
    ///      the same transaction. The collateral provider is recorded per request so that a
    ///      later {rescindRequest} refunds whoever actually paid, not the escrow owner.
    function requestLoan(uint256 amount_, uint256 interest_, uint256 loanToCollateral_, uint256 duration_)
        external
        override
        returns (uint256 reqID)
    {
        if (amount_ == 0 || loanToCollateral_ == 0 || duration_ == 0) revert ZeroAmount();

        reqID = _requests.length;
        _requests.push(
            Request({
                amount: amount_,
                interest: interest_,
                loanToCollateral: loanToCollateral_,
                duration: duration_,
                active: true
            })
        );
        requestProvider[reqID] = msg.sender;

        factory.newEvent(reqID, ICoolerFactory.Events.RequestLoan, amount_);

        collateral.safeTransferFrom(msg.sender, address(this), collateralFor(amount_, loanToCollateral_));
    }

    /// @inheritdoc ICooler
    /// @dev Callable by the escrow owner or by whoever posted the collateral. The refund
    ///      always goes to the collateral provider.
    function rescindRequest(uint256 reqID_) external override {
        Request storage req = _requests[reqID_];
        address provider = requestProvider[reqID_];
        if (msg.sender != owner && msg.sender != provider) revert OnlyApproved();
        if (!req.active) revert Deactivated();

        req.active = false;

        factory.newEvent(reqID_, ICoolerFactory.Events.RescindRequest, 0);

        collateral.safeTransfer(provider, collateralFor(req.amount, req.loanToCollateral));
    }

    /// @inheritdoc ICooler
    /// @dev Repayment is applied to interest first, then principal, and releases collateral
    ///      pro rata to the principal retired. Anyone may repay on behalf of the borrower;
    ///      the freed collateral always goes to the escrow owner. Reverts once expired: an
    ///      expired loan can only be defaulted, which is what removes liquidation risk.
    function repayLoan(uint256 loanID_, uint256 repayment_) external override returns (uint256 collateralReturned) {
        Loan memory loan = _loans[loanID_];
        if (block.timestamp > loan.expiry) revert Defaulted();

        uint256 owed = loan.principal + loan.interestDue;
        if (owed == 0) revert NotActive();
        if (repayment_ > owed) repayment_ = owed;
        if (repayment_ == 0) revert ZeroAmount();

        uint256 interestPaid = repayment_ > loan.interestDue ? loan.interestDue : repayment_;
        uint256 principalPaid = repayment_ - interestPaid;
        collateralReturned = loan.principal == 0 ? 0 : (loan.collateral * principalPaid) / loan.principal;

        _loans[loanID_].interestDue = loan.interestDue - interestPaid;
        _loans[loanID_].principal = loan.principal - principalPaid;
        _loans[loanID_].collateral = loan.collateral - collateralReturned;

        address recipient = loan.recipient;
        if (recipient == address(this)) unclaimed[loanID_] += repayment_;

        factory.newEvent(loanID_, ICoolerFactory.Events.RepayLoan, repayment_);

        debt.safeTransferFrom(msg.sender, recipient, repayment_);
        if (collateralReturned != 0) collateral.safeTransfer(owner, collateralReturned);

        if (loan.callback) ICoolerCallback(loan.lender).onRepay(loanID_, principalPaid, interestPaid);
    }

    /// @inheritdoc ICooler
    /// @dev Buys `times_` more terms by prepaying `times_` more terms of interest at the rate
    ///      the loan was written on. Collateral is untouched, so this is the cheap way to keep
    ///      a loan perpetual when the offered oLTC has not moved. No callback is fired: the
    ///      payment is new interest income, not a reduction of the lender receivable.
    function extendLoan(uint256 loanID_, uint8 times_) external override returns (uint256 extraInterest) {
        Loan memory loan = _loans[loanID_];
        if (times_ == 0) revert ZeroAmount();
        if (block.timestamp > loan.expiry) revert Defaulted();
        if (loan.principal == 0) revert NotActive();

        extraInterest = interestFor(loan.principal, loan.request.interest, loan.request.duration) * times_;

        _loans[loanID_].expiry = loan.expiry + (loan.request.duration * times_);

        address recipient = loan.recipient;
        if (recipient == address(this)) unclaimed[loanID_] += extraInterest;

        factory.newEvent(loanID_, ICoolerFactory.Events.ExtendLoan, times_);

        if (extraInterest != 0) debt.safeTransferFrom(msg.sender, recipient, extraInterest);
    }

    /// @inheritdoc ICooler
    /// @dev Consumes the terms the lender pre-authorised with {provideNewTermsForRoll}: adds
    ///      one more term of interest, tops the collateral up to the new oLTC and pushes the
    ///      expiry out by one duration. Any top-up is pulled from the escrow owner, who must
    ///      have approved this escrow for the collateral token. When the offered oLTC has
    ///      grown (backing per gHOODZ rose) the top-up is zero and the roll is free.
    function rollLoan(uint256 loanID_) external override returns (uint256 newCollateral, uint256 newInterest) {
        Loan memory loan = _loans[loanID_];
        if (block.timestamp > loan.expiry) revert Defaulted();
        if (loan.principal == 0) revert NotActive();
        if (!loan.request.active) revert NotRollable();

        newCollateral = newCollateralFor(loanID_);
        newInterest = interestFor(loan.principal, loan.request.interest, loan.request.duration);

        _loans[loanID_].request.active = false;
        _loans[loanID_].interestDue = loan.interestDue + newInterest;
        _loans[loanID_].collateral = loan.collateral + newCollateral;
        _loans[loanID_].expiry = loan.expiry + loan.request.duration;

        factory.newEvent(loanID_, ICoolerFactory.Events.RollLoan, newCollateral);

        if (newCollateral != 0) collateral.safeTransferFrom(owner, address(this), newCollateral);
    }

    // ---------------------------------------------------------------------------------------
    //                                        LENDER
    // ---------------------------------------------------------------------------------------

    /// @inheritdoc ICooler
    /// @dev The lender funds the escrow owner directly. `repayDirect_ == false` routes
    ///      repayments into this escrow instead, where the lender pulls them with
    ///      {claimRepaid}; useful for lenders that cannot accept push transfers.
    function clearRequest(uint256 reqID_, bool repayDirect_, bool isCallback_)
        external
        override
        returns (uint256 loanID)
    {
        Request memory req = _requests[reqID_];
        if (!req.active) revert Deactivated();

        // Deactivate BEFORE the callback probe. `isCoolerCallback()` is a call into lender-supplied
        // code, and a malicious lender that re-enters clearRequest during it would otherwise clear
        // the same request twice - two loans, one lot of collateral.
        _requests[reqID_].active = false;
        req.active = false;

        if (isCallback_ && !ICoolerCallback(msg.sender).isCoolerCallback()) revert NotCoolerCallback();

        loanID = _loans.length;
        _loans.push(
            Loan({
                request: req,
                principal: req.amount,
                interestDue: interestFor(req.amount, req.interest, req.duration),
                collateral: collateralFor(req.amount, req.loanToCollateral),
                expiry: block.timestamp + req.duration,
                lender: msg.sender,
                recipient: repayDirect_ ? msg.sender : address(this),
                callback: isCallback_
            })
        );

        factory.newEvent(loanID, ICoolerFactory.Events.ClearRequest, req.amount);

        debt.safeTransferFrom(msg.sender, owner, req.amount);
    }

    /// @inheritdoc ICooler
    /// @dev Only the lender of the loan may set the terms of its next roll. Setting terms does
    ///      not move any value; the borrower opts in by calling {rollLoan}.
    function provideNewTermsForRoll(
        uint256 loanID_,
        uint256 interest_,
        uint256 loanToCollateral_,
        uint256 duration_
    ) external override {
        Loan storage loan = _loans[loanID_];
        if (msg.sender != loan.lender) revert OnlyApproved();
        if (loan.principal == 0) revert NotActive();
        if (loanToCollateral_ == 0 || duration_ == 0) revert ZeroAmount();

        loan.request = Request({
            amount: loan.principal,
            interest: interest_,
            loanToCollateral: loanToCollateral_,
            duration: duration_,
            active: true
        });

        emit NewTermsProvided(loanID_, interest_, loanToCollateral_, duration_);
    }

    /// @inheritdoc ICooler
    /// @dev Permissionless; the proceeds always go to the recorded lender.
    function claimRepaid(uint256 loanID_) external override returns (uint256 amount) {
        amount = unclaimed[loanID_];
        if (amount == 0) revert NothingToClaim();

        address lender = _loans[loanID_].lender;
        unclaimed[loanID_] = 0;

        emit ClaimRepaid(loanID_, lender, amount);

        debt.safeTransfer(lender, amount);
    }

    /// @inheritdoc ICooler
    /// @dev Permissionless; the collateral always goes to the recorded lender. This is the
    ///      only settlement path for an expired loan. There is no liquidation, no auction and
    ///      no partial seizure: the lender takes the collateral and writes off the debt.
    function claimDefaulted(uint256 loanID_)
        external
        override
        returns (uint256 defaultedCollateral, uint256 unpaidPrincipal, uint256 unpaidInterest, uint256 elapsed)
    {
        Loan memory loan = _loans[loanID_];
        if (block.timestamp <= loan.expiry) revert NoDefault();
        if (loan.principal == 0 && loan.collateral == 0) revert NotActive();

        _loans[loanID_].principal = 0;
        _loans[loanID_].interestDue = 0;
        _loans[loanID_].collateral = 0;
        _loans[loanID_].request.active = false;

        defaultedCollateral = loan.collateral;
        unpaidPrincipal = loan.principal;
        unpaidInterest = loan.interestDue;
        elapsed = block.timestamp - loan.expiry;

        factory.newEvent(loanID_, ICoolerFactory.Events.DefaultLoan, defaultedCollateral);

        if (defaultedCollateral != 0) collateral.safeTransfer(loan.lender, defaultedCollateral);

        if (loan.callback) {
            ICoolerCallback(loan.lender).onDefault(loanID_, unpaidPrincipal, unpaidInterest, defaultedCollateral);
        }
    }

    // ---------------------------------------------------------------------------------------
    //                                         VIEWS
    // ---------------------------------------------------------------------------------------

    /// @inheritdoc ICooler
    /// @dev collateral = principal * 1e18 / loanToCollateral. Rounds down, which is why the
    ///      lender policy, not the escrow, decides the oLTC it is willing to write.
    function collateralFor(uint256 principal_, uint256 loanToCollateral_) public pure override returns (uint256) {
        return (principal_ * DECIMALS) / loanToCollateral_;
    }

    /// @inheritdoc ICooler
    /// @dev interest = principal * (rate * duration / 365 days) / 1e18. Simple, not compound:
    ///      each term is priced on the outstanding principal at the moment the term starts.
    function interestFor(uint256 principal_, uint256 rate_, uint256 duration_) public pure override returns (uint256) {
        uint256 periodRate = (rate_ * duration_) / ONE_YEAR;
        return (principal_ * periodRate) / DECIMALS;
    }

    /// @inheritdoc ICooler
    /// @dev Zero when the currently offered oLTC is at least as generous as the one the loan
    ///      already carries, which is the steady state while the Clearinghouse oLTC drips up.
    function newCollateralFor(uint256 loanID_) public view override returns (uint256) {
        Loan memory loan = _loans[loanID_];
        uint256 neededCollateral = collateralFor(loan.principal, loan.request.loanToCollateral);
        return neededCollateral > loan.collateral ? neededCollateral - loan.collateral : 0;
    }

    /// @inheritdoc ICooler
    function annualisedInterest(uint256 loanID_) external view override returns (uint256) {
        Loan memory loan = _loans[loanID_];
        return interestFor(loan.principal, loan.request.interest, ONE_YEAR);
    }

    /// @inheritdoc ICooler
    function getLoan(uint256 loanID_) external view override returns (Loan memory) {
        return _loans[loanID_];
    }

    /// @inheritdoc ICooler
    function getRequest(uint256 reqID_) external view override returns (Request memory) {
        return _requests[reqID_];
    }

    /// @inheritdoc ICooler
    function loanCount() external view override returns (uint256) {
        return _loans.length;
    }

    /// @inheritdoc ICooler
    function requestCount() external view override returns (uint256) {
        return _requests.length;
    }

    /// @inheritdoc ICooler
    function hasExpired(uint256 loanID_) external view override returns (bool) {
        return block.timestamp > _loans[loanID_].expiry;
    }
}
