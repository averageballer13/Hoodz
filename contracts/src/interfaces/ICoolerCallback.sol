// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @dev UNAUDITED. Do not use in production without a full audit.

/// @title  ICoolerCallback
/// @notice Hook interface implemented by lenders that want to be notified by a `Cooler`
///         escrow whenever one of their loans is repaid, extended by a roll, or defaulted.
/// @dev    A lender opts into callbacks by passing `isCallback_ = true` to
///         `ICooler.clearRequest`. The escrow calls `isCoolerCallback()` at that moment and
///         reverts if the lender does not answer `true`, which prevents a plain EOA from
///         accidentally creating a loan that would brick on every repayment.
///
///         Implementers MUST gate `onRepay` / `onDefault` on the caller being a `Cooler`
///         minted by the trusted `CoolerFactory`, otherwise anyone could forge repayment
///         accounting. The callbacks are invoked AFTER the escrow has settled every token
///         transfer and written its own storage, so an implementer can safely read balances.
interface ICoolerCallback {
    /// @notice Marker used by `Cooler` to verify the lender really is a callback receiver.
    /// @return True, always. A contract that does not implement this reverts on call.
    function isCoolerCallback() external pure returns (bool);

    /// @notice Called after a (partial or full) repayment has been settled.
    /// @param  loanID_        Identifier of the loan inside the calling `Cooler`.
    /// @param  principalPaid_ Amount of principal repaid, in debt-token decimals.
    /// @param  interestPaid_  Amount of interest repaid, in debt-token decimals.
    function onRepay(uint256 loanID_, uint256 principalPaid_, uint256 interestPaid_) external;

    /// @notice Called after a defaulted loan has been claimed and its collateral seized.
    /// @param  loanID_      Identifier of the loan inside the calling `Cooler`.
    /// @param  principal_   Principal that was still outstanding at default.
    /// @param  interestDue_ Interest that was still outstanding at default.
    /// @param  collateral_  Collateral transferred to the lender.
    function onDefault(uint256 loanID_, uint256 principal_, uint256 interestDue_, uint256 collateral_) external;
}
