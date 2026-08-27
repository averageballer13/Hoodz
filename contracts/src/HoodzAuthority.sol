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
        X      https://x.com/Hoodzfinancial
        Code   https://github.com/averageballer13/Hoodz

        UNAUDITED. This code has never been audited. Read it before you
        trust it with anything you would miss.
*/

import {IHoodzAuthority} from "./interfaces/IHoodzAuthority.sol";
import {HoodzAccessControlled} from "./types/HoodzAccessControlled.sol";

/// @title  HoodzAuthority
/// @notice Single source of truth for the four Hoodz roles: governor, guardian, policy, vault.
///         Every module inherits HoodzAccessControlled and resolves its permissions here, so a role
///         rotation re-permissions the whole protocol atomically.
/// @dev    UNAUDITED. Do not use in production without a full audit.
///         Role handover is push/pull (two-step): the holder nominates a successor with push*(),
///         the successor claims it with pull*(). Passing `effectiveImmediately = true` installs the
///         successor at once (single-step) while still recording the nomination, mirroring
///         OlympusAuthority. The authority governs itself: its own `authority` pointer is `this`.
contract HoodzAuthority is IHoodzAuthority, HoodzAccessControlled {
    /* ========================================= ERRORS ========================================= */

    /// @notice A zero address was supplied for a role.
    error HoodzAuthority_ZeroAddress();
    /// @notice Caller is not the nominated successor for this role.
    error HoodzAuthority_NotNominated(address caller);
    /// @notice The vault role is escrowed with the launch guard; only the guard can move it.
    error HoodzAuthority_VaultLockedToGuard(address launchGuard);
    /// @notice The vault role is already escrowed with a launch guard. One-shot.
    error HoodzAuthority_VaultAlreadyLocked();
    /// @notice Caller is not the registered launch guard.
    error HoodzAuthority_NotLaunchGuard(address caller);

    /* ========================================= EVENTS ========================================= */

    /// @notice The vault role was escrowed with `launchGuard`; HOODZ supply is now frozen.
    event VaultLockedToGuard(address indexed launchGuard);
    /// @notice `launchGuard` completed its checks and released the vault role to `newVault`.
    event VaultReleasedFromGuard(address indexed launchGuard, address indexed newVault);

    /* ========================================== STATE ========================================= */

    /// @notice Current governor: protocol owner.
    address public override governor;
    /// @notice Current guardian: emergency operator.
    address public override guardian;
    /// @notice Current policy: parameter setter.
    address public override policy;
    /// @notice Current vault: the only address allowed to mint HOODZ.
    address public override vault;

    /// @notice Governor nominee awaiting pullGovernor().
    address public newGovernor;
    /// @notice Guardian nominee awaiting pullGuardian().
    address public newGuardian;
    /// @notice Policy nominee awaiting pullPolicy().
    address public newPolicy;
    /// @notice Vault nominee awaiting pullVault().
    address public newVault;

    /// @notice The launch guard currently escrowing the vault role, or zero.
    /// @dev While non-zero, {pushVault} is disabled: the ONLY way to move the vault role is
    ///      {releaseVaultFromGuard}, which only the guard itself can call and which the guard only
    ///      calls after PONS graduation, a live LP-lock check and its 48h delay. Without this the
    ///      guard would be decorative - a governor could hand mint authority straight to the
    ///      treasury with one `pushVault` and skip every check.
    address public launchGuard;

    /* ======================================= CONSTRUCTOR ====================================== */

    /// @param _governor  Initial governor.
    /// @param _guardian  Initial guardian.
    /// @param _policy    Initial policy.
    /// @param _vault     Initial vault (the Hoodz Treasury once deployed).
    constructor(address _governor, address _guardian, address _policy, address _vault)
        HoodzAccessControlled(IHoodzAuthority(address(this)))
    {
        if (_governor == address(0) || _guardian == address(0) || _policy == address(0) || _vault == address(0)) {
            revert HoodzAuthority_ZeroAddress();
        }

        governor = _governor;
        emit GovernorPushed(address(0), _governor, true);

        guardian = _guardian;
        emit GuardianPushed(address(0), _guardian, true);

        policy = _policy;
        emit PolicyPushed(address(0), _policy, true);

        vault = _vault;
        emit VaultPushed(address(0), _vault, true);
    }

    /* ========================================== PUSH ========================================== */

    /// @notice Nominate a new governor.
    /// @param _newGovernor        Successor address.
    /// @param _effectiveImmediately True to install the successor now instead of waiting for a pull.
    function pushGovernor(address _newGovernor, bool _effectiveImmediately) external onlyGovernor {
        if (_newGovernor == address(0)) revert HoodzAuthority_ZeroAddress();
        if (_effectiveImmediately) governor = _newGovernor;
        newGovernor = _newGovernor;
        emit GovernorPushed(governor, _newGovernor, _effectiveImmediately);
    }

    /// @notice Nominate a new guardian.
    /// @param _newGuardian        Successor address.
    /// @param _effectiveImmediately True to install the successor now instead of waiting for a pull.
    function pushGuardian(address _newGuardian, bool _effectiveImmediately) external onlyGovernor {
        if (_newGuardian == address(0)) revert HoodzAuthority_ZeroAddress();
        if (_effectiveImmediately) guardian = _newGuardian;
        newGuardian = _newGuardian;
        emit GuardianPushed(guardian, _newGuardian, _effectiveImmediately);
    }

    /// @notice Nominate a new policy.
    /// @param _newPolicy          Successor address.
    /// @param _effectiveImmediately True to install the successor now instead of waiting for a pull.
    function pushPolicy(address _newPolicy, bool _effectiveImmediately) external onlyGovernor {
        if (_newPolicy == address(0)) revert HoodzAuthority_ZeroAddress();
        if (_effectiveImmediately) policy = _newPolicy;
        newPolicy = _newPolicy;
        emit PolicyPushed(policy, _newPolicy, _effectiveImmediately);
    }

    /// @notice Nominate a new vault (the address allowed to mint HOODZ).
    /// @param _newVault           Successor address.
    /// @param _effectiveImmediately True to install the successor now instead of waiting for a pull.
    /// @dev Reverts while the vault role is escrowed with a launch guard.
    function pushVault(address _newVault, bool _effectiveImmediately) external onlyGovernor {
        if (launchGuard != address(0)) revert HoodzAuthority_VaultLockedToGuard(launchGuard);
        if (_newVault == address(0)) revert HoodzAuthority_ZeroAddress();
        if (_effectiveImmediately) vault = _newVault;
        newVault = _newVault;
        emit VaultPushed(vault, _newVault, _effectiveImmediately);
    }

    /* ====================================== LAUNCH GUARD ====================================== */

    /// @notice Escrow the vault role with the PONS launch guard. One-way, one-shot.
    /// @dev Governor only, and only once. Installs `_launchGuard` as the vault immediately, which
    ///      freezes HOODZ supply: the guard has no mint function, so no HOODZ can be created until
    ///      {releaseVaultFromGuard}. From this call onwards {pushVault} reverts, so the governor
    ///      cannot route around the guard's graduation and LP-lock checks.
    ///      Deploy order: HoodzAuthority -> HoodzLaunchGuard(authority) -> lockVaultToGuard(guard).
    /// @param _launchGuard The HoodzLaunchGuard instance.
    function lockVaultToGuard(address _launchGuard) external onlyGovernor {
        if (launchGuard != address(0)) revert HoodzAuthority_VaultAlreadyLocked();
        if (_launchGuard == address(0)) revert HoodzAuthority_ZeroAddress();

        launchGuard = _launchGuard;

        emit VaultPushed(vault, _launchGuard, true);
        vault = _launchGuard;
        newVault = _launchGuard;

        emit VaultLockedToGuard(_launchGuard);
    }

    /// @notice Move the vault role out of escrow. Callable only by the registered launch guard.
    /// @dev The guard calls this from {HoodzLaunchGuard.releaseToTreasury} once graduation and the
    ///      permanent LP lock are verified live and its delay has elapsed. `msg.sender` is the guard
    ///      contract, not a human, which is why this is deliberately NOT `onlyGovernor`: the guard
    ///      is never the governor, so an `onlyGovernor` check here would make the handoff
    ///      unreachable in every deployment. Clearing `launchGuard` re-enables {pushVault}.
    /// @param _newVault The address receiving mint authority (the Hoodz Treasury).
    function releaseVaultFromGuard(address _newVault) external {
        if (msg.sender != launchGuard) revert HoodzAuthority_NotLaunchGuard(msg.sender);
        if (_newVault == address(0)) revert HoodzAuthority_ZeroAddress();

        address guard = launchGuard;
        launchGuard = address(0);

        emit VaultPushed(vault, _newVault, true);
        vault = _newVault;
        newVault = _newVault;

        emit VaultReleasedFromGuard(guard, _newVault);
    }

    /* ========================================== PULL ========================================== */

    /// @notice Claim the governor role after being nominated.
    function pullGovernor() external {
        if (msg.sender != newGovernor) revert HoodzAuthority_NotNominated(msg.sender);
        emit GovernorPulled(governor, newGovernor);
        governor = newGovernor;
    }

    /// @notice Claim the guardian role after being nominated.
    function pullGuardian() external {
        if (msg.sender != newGuardian) revert HoodzAuthority_NotNominated(msg.sender);
        emit GuardianPulled(guardian, newGuardian);
        guardian = newGuardian;
    }

    /// @notice Claim the policy role after being nominated.
    function pullPolicy() external {
        if (msg.sender != newPolicy) revert HoodzAuthority_NotNominated(msg.sender);
        emit PolicyPulled(policy, newPolicy);
        policy = newPolicy;
    }

    /// @notice Claim the vault role after being nominated.
    function pullVault() external {
        if (msg.sender != newVault) revert HoodzAuthority_NotNominated(msg.sender);
        emit VaultPulled(vault, newVault);
        vault = newVault;
    }
}
