// SPDX-License-Identifier: AGPL-3.0-or-later
// UNAUDITED. Do not use in production without a full audit.
pragma solidity ^0.8.24;

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
    function pushVault(address _newVault, bool _effectiveImmediately) external onlyGovernor {
        if (_newVault == address(0)) revert HoodzAuthority_ZeroAddress();
        if (_effectiveImmediately) vault = _newVault;
        newVault = _newVault;
        emit VaultPushed(vault, _newVault, _effectiveImmediately);
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
