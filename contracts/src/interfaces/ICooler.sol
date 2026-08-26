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
import {ICoolerFactory} from "./ICoolerFactory.sol";

/// @title  ICooler
/// @notice Interface of a Hoodz Loans escrow: a per-borrower, per-token-pair vault that holds
///         collateral and books the loans written against it.
/// @dev    One escrow is owned by exactly one borrower and is pinned to exactly one
///         (collateral, debt) pair, so a lender that has verified those three facts knows
///         precisely what it is lending against. Escrows are minimal-proxy clones and are
///         therefore configured through `initialize`, never a constructor.
interface ICooler {
    // ---------------------------------------------------------------------------------------
    //                                        TYPES
    // ---------------------------------------------------------------------------------------

    /// @notice Terms a borrower (or a lender policy acting for one) offers to the market.
    /// @param  amount           Principal requested, in debt-token decimals.
    /// @param  interest         Annualised interest rate, 1e18 fixed point (5e15 == 0.5%).
    /// @param  loanToCollateral Debt tokens lent per 1e18 collateral tokens (oLTC).
    /// @param  duration         Loan term in seconds.
    /// @param  active           False once the request is cleared or rescinded.
    struct Request {
        uint256 amount;
        uint256 interest;
        uint256 loanToCollateral;
        uint256 duration;
        bool active;
    }

    /// @notice A live loan booked against this escrow.
    /// @param  request     Terms the loan was written on; also the terms of the next roll.
    /// @param  principal   Outstanding principal.
    /// @param  interestDue Outstanding interest, charged up front per term.
    /// @param  collateral  Collateral locked for this loan.
    /// @param  expiry      Timestamp after which the loan is in default.
    /// @param  lender      Who cleared the request and owns the repayments.
    /// @param  recipient   Where repayments are sent; `address(this)` means escrowed for
    ///                     later `claimRepaid`.
    /// @param  callback    Whether the lender receives `ICoolerCallback` hooks.
    struct Loan {
        Request request;
        uint256 principal;
        uint256 interestDue;
        uint256 collateral;
        uint256 expiry;
        address lender;
        address recipient;
        bool callback;
    }

    // ---------------------------------------------------------------------------------------
    //                                        EVENTS
    // ---------------------------------------------------------------------------------------

    /// @notice The lender pre-authorised the next roll with fresh terms.
    event NewTermsProvided(uint256 indexed loanID, uint256 interest, uint256 loanToCollateral, uint256 duration);
    /// @notice Escrowed repayments were pulled by the lender.
    event ClaimRepaid(uint256 indexed loanID, address indexed lender, uint256 amount);

    // ---------------------------------------------------------------------------------------
    //                                        ERRORS
    // ---------------------------------------------------------------------------------------

    /// @notice `initialize` was called on an already configured escrow.
    error AlreadyInitialized();
    /// @notice A zero address was supplied where a real one is required.
    error ZeroAddress();
    /// @notice A zero amount, duration or loan-to-collateral was supplied.
    error ZeroAmount();
    /// @notice Caller is neither the escrow owner nor the party entitled to act.
    error OnlyApproved();
    /// @notice The request is no longer live.
    error Deactivated();
    /// @notice The loan has no outstanding principal.
    error NotActive();
    /// @notice The loan is past its expiry and can only be defaulted.
    error Defaulted();
    /// @notice The loan has not expired yet, so it cannot be defaulted.
    error NoDefault();
    /// @notice No roll terms were provided by the lender.
    error NotRollable();
    /// @notice The lender asked for callbacks but does not implement `ICoolerCallback`.
    error NotCoolerCallback();
    /// @notice There is nothing escrowed to claim for this loan.
    error NothingToClaim();

    // ---------------------------------------------------------------------------------------
    //                                        CONFIG
    // ---------------------------------------------------------------------------------------

    /// @notice One-shot configuration of a freshly deployed clone.
    /// @param  owner_      Borrower that owns the escrow and receives borrowed funds.
    /// @param  collateral_ Token posted as collateral.
    /// @param  debt_       Token borrowed.
    /// @param  factory_    Factory that minted this clone and sinks its logs.
    function initialize(address owner_, IERC20 collateral_, IERC20 debt_, ICoolerFactory factory_) external;

    /// @notice Borrower that owns this escrow.
    /// @return The escrow owner.
    function owner() external view returns (address);

    /// @notice Token posted as collateral.
    /// @return The collateral token.
    function collateral() external view returns (IERC20);

    /// @notice Token borrowed.
    /// @return The debt token.
    function debt() external view returns (IERC20);

    /// @notice Factory that minted this escrow.
    /// @return The factory.
    function factory() external view returns (ICoolerFactory);

    /// @notice Who supplied the collateral backing a request, and who is refunded on rescind.
    /// @param  reqID_ Request identifier.
    /// @return The address that posted the collateral.
    function requestProvider(uint256 reqID_) external view returns (address);

    /// @notice Repayments held in escrow for a loan whose lender chose indirect repayment.
    /// @param  loanID_ Loan identifier.
    /// @return Amount of debt token waiting for `claimRepaid`.
    function unclaimed(uint256 loanID_) external view returns (uint256);

    // ---------------------------------------------------------------------------------------
    //                                       BORROWER
    // ---------------------------------------------------------------------------------------

    /// @notice Post collateral and publish terms a lender may fill.
    /// @param  amount_           Principal requested, in debt-token decimals.
    /// @param  interest_         Annualised rate, 1e18 fixed point.
    /// @param  loanToCollateral_ Debt tokens per 1e18 collateral tokens.
    /// @param  duration_         Term length in seconds.
    /// @return reqID             Identifier of the new request.
    function requestLoan(uint256 amount_, uint256 interest_, uint256 loanToCollateral_, uint256 duration_)
        external
        returns (uint256 reqID);

    /// @notice Cancel an unfilled request and return its collateral to whoever posted it.
    /// @param  reqID_ Request identifier.
    function rescindRequest(uint256 reqID_) external;

    /// @notice Repay principal and interest, unlocking collateral pro rata to principal repaid.
    /// @param  loanID_    Loan identifier.
    /// @param  repayment_ Debt tokens to repay; capped at the amount owed.
    /// @return collateralReturned Collateral released to the escrow owner.
    function repayLoan(uint256 loanID_, uint256 repayment_) external returns (uint256 collateralReturned);

    /// @notice Prepay interest for `times_` further terms and push the expiry out.
    /// @param  loanID_ Loan identifier.
    /// @param  times_  Number of additional terms to buy.
    /// @return extraInterest Debt tokens paid for the extension.
    function extendLoan(uint256 loanID_, uint8 times_) external returns (uint256 extraInterest);

    /// @notice Execute the roll the lender pre-authorised: new term, new interest, top-up collateral.
    /// @param  loanID_ Loan identifier.
    /// @return newCollateral Extra collateral pulled from the escrow owner (0 when backing grew).
    /// @return newInterest   Interest added for the new term.
    function rollLoan(uint256 loanID_) external returns (uint256 newCollateral, uint256 newInterest);

    // ---------------------------------------------------------------------------------------
    //                                        LENDER
    // ---------------------------------------------------------------------------------------

    /// @notice Fill a request, funding the escrow owner and opening a loan.
    /// @param  reqID_       Request identifier.
    /// @param  repayDirect_ True to receive repayments immediately, false to escrow them.
    /// @param  isCallback_  True to receive `ICoolerCallback` hooks.
    /// @return loanID       Identifier of the new loan.
    function clearRequest(uint256 reqID_, bool repayDirect_, bool isCallback_) external returns (uint256 loanID);

    /// @notice Pre-authorise the next roll of a loan with fresh terms.
    /// @param  loanID_           Loan identifier.
    /// @param  interest_         Annualised rate for the new term, 1e18 fixed point.
    /// @param  loanToCollateral_ Loan-to-collateral for the new term.
    /// @param  duration_         Length of the new term in seconds.
    function provideNewTermsForRoll(
        uint256 loanID_,
        uint256 interest_,
        uint256 loanToCollateral_,
        uint256 duration_
    ) external;

    /// @notice Withdraw repayments that were escrowed rather than pushed to the lender.
    /// @param  loanID_ Loan identifier.
    /// @return amount  Debt tokens transferred to the lender.
    function claimRepaid(uint256 loanID_) external returns (uint256 amount);

    /// @notice Seize the collateral of an expired loan. Permissionless; proceeds go to the lender.
    /// @param  loanID_ Loan identifier.
    /// @return defaultedCollateral Collateral transferred to the lender.
    /// @return unpaidPrincipal     Principal written off.
    /// @return unpaidInterest      Interest written off.
    /// @return elapsed             Seconds between expiry and the claim.
    function claimDefaulted(uint256 loanID_)
        external
        returns (uint256 defaultedCollateral, uint256 unpaidPrincipal, uint256 unpaidInterest, uint256 elapsed);

    // ---------------------------------------------------------------------------------------
    //                                         VIEWS
    // ---------------------------------------------------------------------------------------

    /// @notice Collateral needed to borrow `principal_` at `loanToCollateral_`.
    /// @param  principal_        Principal, in debt-token decimals.
    /// @param  loanToCollateral_ Debt tokens per 1e18 collateral tokens.
    /// @return Collateral amount, in collateral-token decimals.
    function collateralFor(uint256 principal_, uint256 loanToCollateral_) external pure returns (uint256);

    /// @notice Interest charged on `principal_` at `rate_` for `duration_`.
    /// @param  principal_ Principal, in debt-token decimals.
    /// @param  rate_      Annualised rate, 1e18 fixed point.
    /// @param  duration_  Term length in seconds.
    /// @return Interest amount, in debt-token decimals.
    function interestFor(uint256 principal_, uint256 rate_, uint256 duration_) external pure returns (uint256);

    /// @notice Extra collateral a roll would require at the terms currently offered on a loan.
    /// @param  loanID_ Loan identifier.
    /// @return Extra collateral, zero when the offered terms are looser than the current ones.
    function newCollateralFor(uint256 loanID_) external view returns (uint256);

    /// @notice Interest the outstanding principal of a loan would accrue over a full year.
    /// @param  loanID_ Loan identifier.
    /// @return Interest amount, in debt-token decimals.
    function annualisedInterest(uint256 loanID_) external view returns (uint256);

    /// @notice Read a loan.
    /// @param  loanID_ Loan identifier.
    /// @return The stored loan.
    function getLoan(uint256 loanID_) external view returns (Loan memory);

    /// @notice Read a request.
    /// @param  reqID_ Request identifier.
    /// @return The stored request.
    function getRequest(uint256 reqID_) external view returns (Request memory);

    /// @notice Number of loans ever booked by this escrow.
    /// @return The loan count.
    function loanCount() external view returns (uint256);

    /// @notice Number of requests ever published by this escrow.
    /// @return The request count.
    function requestCount() external view returns (uint256);

    /// @notice Whether a loan is past its expiry.
    /// @param  loanID_ Loan identifier.
    /// @return True when the loan can be defaulted.
    function hasExpired(uint256 loanID_) external view returns (bool);
}
