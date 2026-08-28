// SPDX-License-Identifier: AGPL-3.0-or-later
// UNAUDITED. Do not use in production without a full audit.
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

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

import {IgHOOD} from "../interfaces/IgHOOD.sol";
import {IsHOOD} from "../interfaces/IsHOOD.sol";
import {IHoodzAuthority} from "../interfaces/IHoodzAuthority.sol";
import {HoodzAccessControlled} from "../types/HoodzAccessControlled.sol";

/// @title  gHOOD
/// @notice Governance HOOD: the non-rebasing, index-adjusted wrapper around sHOOD (18 decimals).
/// @dev    UNAUDITED. Do not use in production without a full audit.
///
///         A gHOOD balance is constant while the sHOOD it represents grows with the index:
///
///             balanceFrom(g) = g * index / 1e18     gHOOD (18dp) -> sHOOD (9dp)
///             balanceTo(s)   = s * 1e18 / index     sHOOD  (9dp) -> gHOOD (18dp)
///
///         The divisor is 10**decimals() of THIS token (1e18), not of sHOOD. That is what makes
///         one whole gHOOD equal `index` whole sHOOD, so at genesis (index = 1e9 = 1.0) one
///         gHOOD is one sHOOD. Using 1e9 here would still round-trip, but every absolute
///         constant written in gHOOD terms - the governor proposal threshold, the Clearinghouse
///         oLTC - would be off by a factor of 1e9.
///
///         Because balances never rebase, gHOOD can carry ERC20Votes checkpoints and be bridged
///         or used as collateral. Only the staking contract may mint or burn it.
///
///         Voting uses the DEFAULT OpenZeppelin clock: block numbers (not timestamps).
contract gHOOD is IgHOOD, ERC20, ERC20Permit, ERC20Votes, HoodzAccessControlled {
    /* ========================================= ERRORS ========================================= */

    /// @notice Caller is not the staking contract.
    error gHOOD_OnlyStaking(address caller);
    /// @notice A zero address was supplied where a real address is required.
    error gHOOD_ZeroAddress();
    /// @notice migrate() is a one-shot and has already run.
    error gHOOD_AlreadyMigrated();

    /* ========================================= EVENTS ========================================= */

    /// @notice Emitted once, when the staking contract and sHOOD token are wired in.
    event Migrated(address staking, address sHOOD);

    /* ======================================== CONSTANTS ======================================= */

    /// @dev 10**decimals() of gHOOD. Mirrors gOHM, which divides by `10 ** decimals()`.
    uint256 private constant INDEX_SCALE = 1e18;

    /* ========================================== STATE ========================================= */

    /// @notice The rebasing token this wrapper is indexed against.
    IsHOOD public sHOOD;

    /// @notice The staking contract: the only minter and burner of gHOOD.
    address public staking;

    /// @notice True once migrate() has wired the staking contract in.
    bool public migrated;

    /* ======================================== MODIFIERS ======================================= */

    /// @dev Restricts to the staking contract.
    modifier onlyStaking() {
        if (msg.sender != staking) revert gHOOD_OnlyStaking(msg.sender);
        _;
    }

    /* ======================================= CONSTRUCTOR ====================================== */

    /// @param _authority Address of the HoodzAuthority.
    /// @param _sHOOD     Address of sHOOD; may be the zero address if sHOOD is deployed after
    ///                   gHOOD, in which case migrate() supplies it.
    constructor(IHoodzAuthority _authority, address _sHOOD)
        ERC20("Governance HOOD", "gHOOD")
        ERC20Permit("Governance HOOD")
        HoodzAccessControlled(_authority)
    {
        if (_sHOOD != address(0)) sHOOD = IsHOOD(_sHOOD);
    }

    /* ===================================== INITIALISATION ===================================== */

    /// @notice One-shot wiring of the staking contract and the sHOOD token.
    /// @dev    Until this runs, gHOOD can neither be minted nor burned.
    /// @param _staking Address of the Hoodz staking contract.
    /// @param _sHOOD   Address of the sHOOD token.
    function migrate(address _staking, address _sHOOD) external onlyGovernor {
        if (migrated) revert gHOOD_AlreadyMigrated();
        if (_staking == address(0) || _sHOOD == address(0)) revert gHOOD_ZeroAddress();

        migrated = true;
        staking = _staking;
        sHOOD = IsHOOD(_sHOOD);

        emit Migrated(_staking, _sHOOD);
    }

    /* ========================================= MUTATIVE ======================================= */

    /// @notice Mint gHOOD against sHOOD wrapped by a staker. Restricted to the staking contract.
    /// @param to_     Recipient.
    /// @param amount_ gHOOD amount, 18 decimals.
    function mint(address to_, uint256 amount_) external override onlyStaking {
        _mint(to_, amount_);
    }

    /// @notice Burn gHOOD when a staker unwraps. Restricted to the staking contract.
    /// @param from_   Account to burn from.
    /// @param amount_ gHOOD amount, 18 decimals.
    function burn(address from_, uint256 amount_) external override onlyStaking {
        _burn(from_, amount_);
    }

    /* ========================================== VIEWS ========================================= */

    /// @notice The current sHOOD index this wrapper is denominated against.
    /// @return The index, 9 decimals.
    function index() public view override returns (uint256) {
        return sHOOD.index();
    }

    /// @notice Convert gHOOD into the sHOOD amount it currently represents.
    /// @param amount_ gHOOD amount, 18 decimals.
    /// @return The equivalent sHOOD amount, 9 decimals.
    function balanceFrom(uint256 amount_) public view override returns (uint256) {
        return (amount_ * index()) / INDEX_SCALE;
    }

    /// @notice Convert sHOOD into the gHOOD amount it currently represents.
    /// @param amount_ sHOOD amount, 9 decimals.
    /// @return The equivalent gHOOD amount, 18 decimals.
    function balanceTo(uint256 amount_) public view override returns (uint256) {
        return (amount_ * INDEX_SCALE) / index();
    }

    /// @notice Current nonce of an account, shared by permit and delegateBySig.
    /// @param owner_ Account to query.
    /// @return The next unused nonce.
    function nonces(address owner_) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner_);
    }

    /* ========================================= INTERNAL ======================================= */

    /// @dev Single transfer hook: ERC20 bookkeeping plus the ERC20Votes checkpoint move.
    function _update(address from_, address to_, uint256 value_) internal override(ERC20, ERC20Votes) {
        super._update(from_, to_, value_);
    }
}
