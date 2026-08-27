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
        X      https://x.com/Hoodzfinancial
        Code   https://github.com/averageballer13/Hoodz

        UNAUDITED. This code has never been audited. Read it before you
        trust it with anything you would miss.
*/

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title  ICoolerFactory
/// @notice Interface of the deterministic clone factory that mints `Cooler` escrows for
///         Hoodz Loans, and the single log sink every escrow reports its lifecycle to.
/// @dev    Lender policies (e.g. `Clearinghouse`) MUST check `created(cooler)` before
///         trusting an escrow: it is the only proof that the escrow runs the canonical
///         `Cooler` bytecode and therefore honours the collateral/debt invariants.
interface ICoolerFactory {
    /// @notice Lifecycle events fanned out through `newEvent` so indexers only watch one address.
    enum Events {
        RequestLoan,
        RescindRequest,
        ClearRequest,
        RepayLoan,
        ExtendLoan,
        RollLoan,
        DefaultLoan
    }

    /// @notice A new escrow clone was deployed.
    event Created(address indexed cooler, address indexed owner, address indexed collateral, address debt);
    /// @notice Fan-out logs, all emitted by the factory on behalf of `cooler`.
    event RequestLoanEvent(address indexed cooler, uint256 indexed reqID);
    event RescindRequestEvent(address indexed cooler, uint256 indexed reqID);
    event ClearRequestEvent(address indexed cooler, uint256 indexed loanID);
    event RepayLoanEvent(address indexed cooler, uint256 indexed loanID, uint256 amount);
    event ExtendLoanEvent(address indexed cooler, uint256 indexed loanID, uint8 times);
    event RollLoanEvent(address indexed cooler, uint256 indexed loanID, uint256 newCollateral);
    event DefaultLoanEvent(address indexed cooler, uint256 indexed loanID, uint256 collateral);

    /// @notice Caller is not an escrow minted by this factory.
    error OnlyFromFactory();
    /// @notice A zero address was supplied where a token or owner is required.
    error ZeroAddress();

    /// @notice The `Cooler` implementation every clone delegates to.
    function coolerImplementation() external view returns (address);

    /// @notice Whether `cooler` is an escrow deployed by this factory.
    /// @param  cooler Address to check.
    /// @return True when the address is a canonical escrow.
    function created(address cooler) external view returns (bool);

    /// @notice Deploy (or return the existing) escrow for `msg.sender` and the given token pair.
    /// @param  collateral Token posted as collateral (gHOODZ for Hoodz Loans).
    /// @param  debt       Token borrowed (the reserve asset).
    /// @return cooler     Address of the escrow, deterministic in (owner, collateral, debt).
    function generateCooler(IERC20 collateral, IERC20 debt) external returns (address cooler);

    /// @notice Deterministic address of the escrow for a triplet, whether or not it exists yet.
    /// @param  owner      Escrow owner.
    /// @param  collateral Collateral token.
    /// @param  debt       Debt token.
    /// @return The counterfactual clone address.
    function predictCoolerFor(address owner, address collateral, address debt) external view returns (address);

    /// @notice Address of a deployed escrow, or `address(0)` when it has not been generated.
    /// @param  owner      Escrow owner.
    /// @param  collateral Collateral token.
    /// @param  debt       Debt token.
    /// @return The escrow address or zero.
    function getCoolerFor(address owner, address collateral, address debt) external view returns (address);

    /// @notice Emit a lifecycle log on behalf of the calling escrow.
    /// @param  id     Request or loan identifier inside the calling escrow.
    /// @param  ev     Which lifecycle event to emit.
    /// @param  amount Event payload (repayment size, roll collateral, extension count, ...).
    function newEvent(uint256 id, Events ev, uint256 amount) external;
}
