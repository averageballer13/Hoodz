// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @dev UNAUDITED. Do not use in production without a full audit.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {Cooler} from "./Cooler.sol";
import {ICooler} from "../interfaces/ICooler.sol";
import {ICoolerFactory} from "../interfaces/ICoolerFactory.sol";

/// @title  CoolerFactory
/// @notice Deterministic clone factory for Hoodz Loans escrows, and the single log sink every
///         escrow reports its lifecycle to.
/// @dev    UNAUDITED. Do not use in production without a full audit.
///
///         Every escrow is a minimal proxy (EIP-1167) keyed by the triplet
///         (owner, collateral, debt), so each borrower has exactly one escrow per token pair
///         and its address can be computed off-chain before it exists. `generateCooler` is
///         idempotent: calling it twice returns the same escrow instead of reverting.
///
///         `created` is the trust root of the whole system. A lender policy such as
///         `Clearinghouse` refuses to touch any escrow that is not registered here, because
///         only a registered escrow is guaranteed to run the canonical `Cooler` bytecode.
///         The implementation contract itself is deliberately never registered.
///
///         `newEvent` exists so indexers subscribe to one address rather than to an unbounded
///         and growing set of clones.
contract CoolerFactory is ICoolerFactory {
    // ---------------------------------------------------------------------------------------
    //                                        STATE
    // ---------------------------------------------------------------------------------------

    /// @inheritdoc ICoolerFactory
    address public immutable override coolerImplementation;

    /// @inheritdoc ICoolerFactory
    mapping(address => bool) public override created;

    /// @dev Escrows deployed for each owner, in deployment order.
    mapping(address => address[]) internal _coolersOf;

    /// @dev Every escrow ever deployed, in deployment order.
    address[] internal _allCoolers;

    // ---------------------------------------------------------------------------------------
    //                                     CONSTRUCTOR
    // ---------------------------------------------------------------------------------------

    /// @notice Deploys the escrow implementation the clones will delegate to.
    /// @dev    The implementation is left uninitialised and is never registered in `created`,
    ///         so initialising it has no effect on any clone and grants no privilege anywhere.
    constructor() {
        coolerImplementation = address(new Cooler());
    }

    // ---------------------------------------------------------------------------------------
    //                                       DEPLOY
    // ---------------------------------------------------------------------------------------

    /// @inheritdoc ICoolerFactory
    /// @dev Idempotent. The salt binds the escrow to `msg.sender`, so nobody can front-run a
    ///      borrower into an escrow they do not own.
    function generateCooler(IERC20 collateral_, IERC20 debt_) external override returns (address cooler) {
        if (address(collateral_) == address(0) || address(debt_) == address(0)) revert ZeroAddress();

        bytes32 salt = _salt(msg.sender, address(collateral_), address(debt_));
        cooler = Clones.predictDeterministicAddress(coolerImplementation, salt, address(this));
        if (created[cooler]) return cooler;

        Clones.cloneDeterministic(coolerImplementation, salt);

        created[cooler] = true;
        _coolersOf[msg.sender].push(cooler);
        _allCoolers.push(cooler);

        ICooler(cooler).initialize(msg.sender, collateral_, debt_, ICoolerFactory(address(this)));

        emit Created(cooler, msg.sender, address(collateral_), address(debt_));
    }

    // ---------------------------------------------------------------------------------------
    //                                      LOG SINK
    // ---------------------------------------------------------------------------------------

    /// @inheritdoc ICoolerFactory
    /// @dev Only a registered escrow may emit through the factory, otherwise the fan-out feed
    ///      an indexer relies on could be poisoned with forged loan activity.
    function newEvent(uint256 id_, Events ev_, uint256 amount_) external override {
        if (!created[msg.sender]) revert OnlyFromFactory();

        if (ev_ == Events.RequestLoan) {
            emit RequestLoanEvent(msg.sender, id_);
        } else if (ev_ == Events.RescindRequest) {
            emit RescindRequestEvent(msg.sender, id_);
        } else if (ev_ == Events.ClearRequest) {
            emit ClearRequestEvent(msg.sender, id_);
        } else if (ev_ == Events.RepayLoan) {
            emit RepayLoanEvent(msg.sender, id_, amount_);
        } else if (ev_ == Events.ExtendLoan) {
            emit ExtendLoanEvent(msg.sender, id_, uint8(amount_));
        } else if (ev_ == Events.RollLoan) {
            emit RollLoanEvent(msg.sender, id_, amount_);
        } else {
            emit DefaultLoanEvent(msg.sender, id_, amount_);
        }
    }

    // ---------------------------------------------------------------------------------------
    //                                         VIEWS
    // ---------------------------------------------------------------------------------------

    /// @inheritdoc ICoolerFactory
    function predictCoolerFor(address owner_, address collateral_, address debt_)
        public
        view
        override
        returns (address)
    {
        return Clones.predictDeterministicAddress(
            coolerImplementation, _salt(owner_, collateral_, debt_), address(this)
        );
    }

    /// @inheritdoc ICoolerFactory
    function getCoolerFor(address owner_, address collateral_, address debt_)
        external
        view
        override
        returns (address)
    {
        address cooler = predictCoolerFor(owner_, collateral_, debt_);
        return created[cooler] ? cooler : address(0);
    }

    /// @notice Escrows deployed for an owner, in deployment order.
    /// @param  owner_ Escrow owner.
    /// @return The list of escrow addresses.
    function coolersOf(address owner_) external view returns (address[] memory) {
        return _coolersOf[owner_];
    }

    /// @notice Number of escrows ever deployed by this factory.
    /// @return The escrow count.
    function coolerCount() external view returns (uint256) {
        return _allCoolers.length;
    }

    /// @notice Escrow at an index of the global deployment list.
    /// @param  index_ Position in the deployment list.
    /// @return The escrow address.
    function coolerAt(uint256 index_) external view returns (address) {
        return _allCoolers[index_];
    }

    // ---------------------------------------------------------------------------------------
    //                                       INTERNAL
    // ---------------------------------------------------------------------------------------

    /// @dev Clone salt: the escrow identity is exactly (owner, collateral, debt).
    function _salt(address owner_, address collateral_, address debt_) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner_, collateral_, debt_));
    }
}
