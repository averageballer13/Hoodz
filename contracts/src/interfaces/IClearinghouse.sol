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
import {ICooler} from "./ICooler.sol";

/// @title  IClearinghouse
/// @notice Interface of the Hoodz side of Hoodz Loans: the policy that lends treasury
///         reserves against gHOOD collateral at a fixed 0.5% annualised rate, with no
///         liquidations and perpetually rollable terms.
interface IClearinghouse {
    // ---------------------------------------------------------------------------------------
    //                                        EVENTS
    // ---------------------------------------------------------------------------------------

    /// @notice A loan was originated for an escrow.
    event Lend(address indexed cooler, uint256 indexed loanID, uint256 principal, uint256 interest);
    /// @notice A loan was rolled into a new term.
    event Roll(address indexed cooler, uint256 indexed loanID, uint256 newCollateral, uint256 newInterest);
    /// @notice Defaulted loans were claimed and their collateral seized.
    event Defaulted(uint256 principal, uint256 interest, uint256 collateral, uint256 keeperReward);
    /// @notice Reserves moved between the treasury and this policy.
    event Rebalanced(uint256 amount, bool intoClearinghouse);
    /// @notice Idle reserves were parked in the savings vault.
    event Swept(uint256 assets, uint256 shares);
    /// @notice Assets were returned to the treasury outside the rebalance cadence.
    event Defunded(address indexed token, uint256 amount);
    /// @notice Seized gHOOD collateral was unstaked and burned.
    event Burned(uint256 collateral, uint256 hoodzBurned);
    /// @notice Lending was switched on.
    event Activated();
    /// @notice Lending was switched off.
    event Deactivated();

    // ---------------------------------------------------------------------------------------
    //                                        ERRORS
    // ---------------------------------------------------------------------------------------

    /// @notice A zero address was supplied to the constructor.
    error ZeroAddress();
    /// @notice A zero amount was supplied.
    error ZeroAmount();
    /// @notice The escrow was not minted by the trusted factory.
    error OnlyFromFactory();
    /// @notice The escrow is pinned to the wrong collateral or debt token.
    error BadEscrow();
    /// @notice The savings vault does not hold the configured reserve asset.
    error BadSavingsVault();
    /// @notice Only the owner of the escrow may borrow or roll through this policy.
    error OnlyBorrower();
    /// @notice This policy is not the lender of the referenced loan.
    error NotLender();
    /// @notice Lending is currently switched off.
    error NotActive();
    /// @notice Lending is already switched on.
    error AlreadyActive();
    /// @notice Array arguments have mismatched lengths.
    error LengthDiscrepancy();
    /// @notice gHOOD leaves this policy only through `burn`.
    error OnlyBurnable();
    /// @notice There is no seized collateral to burn.
    error NothingToBurn();

    // ---------------------------------------------------------------------------------------
    //                                       LENDING
    // ---------------------------------------------------------------------------------------

    /// @notice Originate a loan for an escrow at the current oLTC and the fixed 0.5% rate.
    /// @param  cooler_ Escrow to lend to; must be factory-minted and gHOOD/reserve pinned.
    /// @param  amount_ Principal to lend, in reserve decimals.
    /// @return loanID  Identifier of the new loan inside the escrow.
    function lendToCooler(ICooler cooler_, uint256 amount_) external returns (uint256 loanID);

    /// @notice Roll a loan into a fresh term at the current oLTC and the fixed 0.5% rate.
    /// @param  cooler_ Escrow holding the loan.
    /// @param  loanID_ Loan identifier.
    function rollLoan(ICooler cooler_, uint256 loanID_) external;

    /// @notice Claim expired loans, seizing their gHOOD collateral for later burning.
    /// @param  coolers_ Escrows holding the defaulted loans.
    /// @param  loans_   Loan identifiers, index-aligned with `coolers_`.
    function claimDefaulted(address[] calldata coolers_, uint256[] calldata loans_) external;

    // ---------------------------------------------------------------------------------------
    //                                       TREASURY
    // ---------------------------------------------------------------------------------------

    /// @notice Top up (or return) reserves so the policy holds exactly one funding tranche.
    /// @return True when a rebalance ran, false when the cadence has not elapsed.
    function rebalance() external returns (bool);

    /// @notice Park every idle reserve token in the savings vault.
    /// @return shares Vault shares minted.
    function sweepIntoSavingsVault() external returns (uint256 shares);

    /// @notice Return assets to the treasury outside the rebalance cadence.
    /// @param  token_  Token to return; gHOOD is rejected because it is burn-only.
    /// @param  amount_ Amount to return, in the token decimals.
    function defund(IERC20 token_, uint256 amount_) external;

    /// @notice Stop lending and push every reserve asset back to the treasury.
    function emergencyShutdown() external;

    /// @notice Resume lending and restart the funding cadence.
    function reactivate() external;

    /// @notice Unstake every seized gHOOD into HOOD and burn it.
    /// @return hoodzBurned HOOD removed from supply.
    function burn() external returns (uint256 hoodzBurned);

    // ---------------------------------------------------------------------------------------
    //                                         VIEWS
    // ---------------------------------------------------------------------------------------

    /// @notice Current origination loan-to-collateral, i.e. reserve lent per 1e18 gHOOD.
    /// @return The oLTC, 1e18 fixed point.
    function loanToCollateral() external view returns (uint256);

    /// @notice Interest charged for a principal over a duration at the fixed rate.
    /// @param  principal_ Principal, in reserve decimals.
    /// @param  duration_  Term length in seconds.
    /// @return Interest, in reserve decimals.
    function interestForLoan(uint256 principal_, uint256 duration_) external view returns (uint256);

    /// @notice Reserve value of an amount of gHOOD collateral at the current oLTC.
    /// @param  collateral_ Collateral amount, 1e18 decimals.
    /// @return Reserve amount, in reserve decimals.
    function debtForCollateral(uint256 collateral_) external view returns (uint256);

    /// @notice Reserve tokens held directly plus the asset value of the savings vault position.
    /// @return The total reserve balance controlled by this policy.
    function reserveBalance() external view returns (uint256);

    /// @notice Outstanding principal plus outstanding interest across every live loan.
    /// @return The total receivables.
    function totalReceivables() external view returns (uint256);

    /// @notice Outstanding principal across every live loan.
    /// @return The principal receivables.
    function principalReceivables() external view returns (uint256);

    /// @notice Outstanding interest across every live loan.
    /// @return The interest receivables.
    function interestReceivables() external view returns (uint256);

    /// @notice Whether the policy is lending.
    /// @return True when active.
    function active() external view returns (bool);

    /// @notice Timestamp at which the next rebalance becomes available.
    /// @return The next funding time.
    function fundTime() external view returns (uint256);
}
