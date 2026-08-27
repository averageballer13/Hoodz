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

import {IHoodzAuthority} from "../interfaces/IHoodzAuthority.sol";
import {HoodzAccessControlled} from "../types/HoodzAccessControlled.sol";
import {IPonsLaunchpad} from "./IPonsLaunchpad.sol";
import {IPositionLocker} from "./IPositionLocker.sol";
import {IUniswapV4PoolManager, PonsPoolId} from "./IUniswapV4PoolManager.sol";
import {PonsLaunchConfig} from "./PonsLaunchConfig.sol";

/// @notice The one mutating call {HoodzLaunchGuard} makes on `HoodzAuthority`.
/// @dev The write side of the authority the guard needs. Declared locally, and deliberately narrow: the guard can
///      move the vault role out of escrow and nothing else. The `IHoodzAuthority` shared interface is read-only, so
///      the write side lives here rather than widening a type other contracts depend on.
interface IHoodzAuthorityVaultHandoff {
    /// @notice Move the vault role to `newVault`. Callable only by the registered launch guard.
    /// @dev `HoodzAuthority.releaseVaultFromGuard` checks `msg.sender == launchGuard`, so the
    ///      caller here is THIS contract, not a human. That is what makes the handoff reachable:
    ///      `pushVault` is `onlyGovernor` on the authority, and the guard is never the governor,
    ///      so calling it from here could never succeed.
    /// @param newVault The address receiving mint authority.
    function releaseVaultFromGuard(address newVault) external;

    /// @notice The guard currently escrowing the vault role, or zero once released.
    function launchGuard() external view returns (address);
}

/// @title HoodzLaunchGuard
/// @author Hoodz
/// @notice Holds the HOODZ vault role hostage until the PONS launch has provably completed.
/// @dev The failure mode this contract exists to prevent: a protocol that can mint HOODZ *while* HOODZ is
///      still price-discovering on a bonding curve. Between deployment and graduation the guard is the
///      vault, and the guard has no mint function - so HOODZ's supply is frozen at exactly the amount
///      escrowed on the curve, and no amount of governance haste can change that.
///
///      Mint authority moves to the Treasury only when all three of these hold at the same time:
///        (a) `IPonsLaunchpad.isGraduated(HOODZ)` is true - the curve has closed;
///        (b) the graduated Uniswap v4 LP position is verified locked with no unlock path, ever;
///        (c) a governor-signed {arm} happened at least {TRANSFER_DELAY} (48h) ago.
///
///      (a) and (b) are re-checked live inside {releaseToTreasury}, not merely trusted from the earlier
///      {verifyGraduation} snapshot. (c) gives HOODZ holders a fixed, public window to exit before the
///      protocol gains the ability to mint. The guardian can {abort} at any point during that window,
///      which resets the clock; the governor can re-{arm} and wait out another 48 hours. The release is
///      one-way and one-shot - `released` never goes back to false.
///
///      The Treasury address is immutable. Governance chooses *when* the handoff happens, never *where*
///      it goes.
///
///      Deployment requirement: the governor must call `HoodzAuthority.lockVaultToGuard(guard)`
///      once, which installs this contract as the vault and disables `pushVault` outright. From
///      that point the ONLY way the vault role can move is {releaseToTreasury} here, which can fire
///      exactly once and can only ever name `TREASURY`. Skip that call and the guard is decorative:
///      the governor could hand mint authority to the treasury directly and bypass every check.
contract HoodzLaunchGuard is HoodzAccessControlled {
    /* ----------------------------------------------------------------- errors */

    /// @notice The PONS curve for HOODZ has not graduated yet.
    error NotGraduated();

    /// @notice The graduated LP position is missing, empty, or not permanently locked.
    error LpNotLocked();

    /// @notice {arm} has not been called, or was undone by {abort}.
    error NotArmed();

    /// @notice {TRANSFER_DELAY} has not elapsed since {arm}.
    error DelayNotElapsed();

    /// @notice Mint authority has already been handed to the Treasury. This contract is spent.
    error AlreadyReleased();

    /// @notice A required address argument was the zero address.
    error ZeroAddress();

    /// @notice `HoodzAuthority` accepted the handoff call but the vault role did not actually move.
    error HandoffFailed();

    /* -------------------------------------------------------------- constants */

    /// @notice Minimum delay between a governor-signed {arm} and a successful {releaseToTreasury}.
    uint256 public constant TRANSFER_DELAY = 48 hours;

    /* ------------------------------------------------------------- immutables */

    /// @notice The immutable on-chain record of the HOODZ launch this guard is anchored to.
    PonsLaunchConfig public immutable CONFIG;

    /// @notice The HOODZ token, read from {CONFIG} at deployment.
    address public immutable HOODZ;

    /// @notice The PONS launchpad that hosts the HOODZ launch.
    IPonsLaunchpad public immutable LAUNCHPAD;

    /// @notice The locker that owns the graduated LP position.
    IPositionLocker public immutable LOCKER;

    /// @notice Optional Uniswap v4 PoolManager, used as an independent liquidity cross-check.
    /// @dev `address(0)` disables the cross-check; the locker checks still apply.
    IUniswapV4PoolManager public immutable POOL_MANAGER;

    /// @notice The Hoodz Treasury that receives mint authority. Fixed at deployment.
    address public immutable TREASURY;

    /// @notice The `HoodzAuthority` this guard hands the vault role over on.
    /// @dev Captured at deployment and never read from the mutable `authority` pointer, so that a later
    ///      {HoodzAccessControlled-setAuthority} cannot redirect the handoff to a counterfeit authority.
    address public immutable HOODZ_AUTHORITY;

    /* ------------------------------------------------------------------ state */

    /// @notice The graduated pool recorded by the most recent successful {verifyGraduation}.
    address public verifiedPool;

    /// @notice Timestamp of the governor-signed {arm}, or zero if not armed.
    uint64 public armedAt;

    /// @notice Whether {verifyGraduation} has succeeded since the last {abort}.
    bool public graduationVerified;

    /// @notice Whether mint authority has been handed to the Treasury. One-way.
    bool public released;

    /* ----------------------------------------------------------------- events */

    /// @notice Emitted when the governor starts the 48h release timer.
    event Armed(address indexed governor, uint64 armedAt, uint64 eligibleAt);

    /// @notice Emitted when graduation and the permanent LP lock are verified on-chain.
    event GraduationVerified(address indexed pool, address indexed verifier, uint64 verifiedAt);

    /// @notice Emitted once, when mint authority moves to the Treasury.
    event MintAuthorityReleased(address indexed treasury, uint64 releasedAt);

    /// @notice Emitted when the guardian cancels a pending release.
    event Aborted(address indexed guardian, uint64 abortedAt);

    /* ------------------------------------------------------------ constructor */

    /// @param authority_ The `HoodzAuthority` this guard is governed by and hands the vault role over on.
    /// @param config_ The immutable {PonsLaunchConfig} record for the HOODZ launch.
    /// @param launchpad_ The PONS launchpad hosting the launch.
    /// @param locker_ The locker that will own the graduated LP position.
    /// @param poolManager_ The Uniswap v4 PoolManager for the liquidity cross-check, or `address(0)` to skip it.
    /// @param treasury_ The Hoodz Treasury that will receive mint authority. Immutable from here on.
    constructor(
        IHoodzAuthority authority_,
        PonsLaunchConfig config_,
        IPonsLaunchpad launchpad_,
        IPositionLocker locker_,
        IUniswapV4PoolManager poolManager_,
        address treasury_
    ) HoodzAccessControlled(authority_) {
        if (
            address(authority_) == address(0) || address(config_) == address(0) || address(launchpad_) == address(0)
                || address(locker_) == address(0) || treasury_ == address(0)
        ) {
            revert ZeroAddress();
        }

        address hoodz_ = config_.hoodzToken();
        if (hoodz_ == address(0)) revert ZeroAddress();

        CONFIG = config_;
        HOODZ = hoodz_;
        LAUNCHPAD = launchpad_;
        LOCKER = locker_;
        POOL_MANAGER = poolManager_;
        TREASURY = treasury_;
        HOODZ_AUTHORITY = address(authority_);
    }

    /* ------------------------------------------------------------- governance */

    /// @notice Start the {TRANSFER_DELAY} countdown to the mint authority handoff.
    /// @dev Governor only. Deliberately callable before graduation - arming is a public statement of
    ///      intent, not a claim that the launch is finished; {releaseToTreasury} still proves (a) and
    ///      (b) independently. Re-arming restarts the countdown from now.
    function arm() external onlyGovernor {
        if (released) revert AlreadyReleased();

        uint64 stamp = uint64(block.timestamp);
        armedAt = stamp;

        emit Armed(msg.sender, stamp, stamp + uint64(TRANSFER_DELAY));
    }

    /// @notice Prove on-chain that HOODZ graduated and its LP position is locked forever.
    /// @dev Permissionless: it records facts anyone can already read, and recording them cannot help an
    ///      attacker - {releaseToTreasury} re-derives both from source anyway.
    /// @return pool The graduated Uniswap v4 pool.
    function verifyGraduation() external returns (address pool) {
        if (released) revert AlreadyReleased();
        if (!_isGraduated()) revert NotGraduated();

        bool ok;
        (ok, pool) = _lockState();
        if (!ok) revert LpNotLocked();

        verifiedPool = pool;
        graduationVerified = true;

        emit GraduationVerified(pool, msg.sender, uint64(block.timestamp));
    }

    /// @notice Hand HOODZ mint authority to the Treasury. One-way, one-shot.
    /// @dev Governor only. Requires, at this exact block: a prior {verifyGraduation}, a live-checked
    ///      graduation, a live-checked permanent LP lock, and {TRANSFER_DELAY} elapsed since {arm}.
    ///      Pushes the vault role to the immutable {TREASURY} and asserts it actually landed.
    function releaseToTreasury() external onlyGovernor {
        if (released) revert AlreadyReleased();
        if (armedAt == 0) revert NotArmed();
        if (block.timestamp < uint256(armedAt) + TRANSFER_DELAY) revert DelayNotElapsed();
        if (!graduationVerified || !_isGraduated()) revert NotGraduated();

        (bool ok, address pool) = _lockState();
        if (!ok) revert LpNotLocked();

        released = true;
        verifiedPool = pool;

        IHoodzAuthorityVaultHandoff(HOODZ_AUTHORITY).releaseVaultFromGuard(TREASURY);
        if (IHoodzAuthority(HOODZ_AUTHORITY).vault() != TREASURY) revert HandoffFailed();

        emit MintAuthorityReleased(TREASURY, uint64(block.timestamp));
    }

    /// @notice Cancel a pending release and reset the countdown.
    /// @dev Guardian only, and useless after the fact: once {released} is true nothing here can undo it.
    ///      The guardian cannot block the handoff forever - the governor may re-{arm} and wait out
    ///      another {TRANSFER_DELAY}. This is a speed bump for emergencies, not a veto.
    function abort() external onlyGuardian {
        if (released) revert AlreadyReleased();

        armedAt = 0;
        graduationVerified = false;

        emit Aborted(msg.sender, uint64(block.timestamp));
    }

    /* ------------------------------------------------------------------ views */

    /// @notice Earliest timestamp at which {releaseToTreasury} can succeed.
    /// @return Zero if not armed, otherwise `armedAt + TRANSFER_DELAY`.
    function releaseEligibleAt() external view returns (uint256) {
        return armedAt == 0 ? 0 : uint256(armedAt) + TRANSFER_DELAY;
    }

    /// @notice Seconds remaining before the handoff becomes eligible.
    /// @return Zero if not armed or already elapsed, otherwise the remaining seconds.
    function secondsUntilRelease() external view returns (uint256) {
        if (armedAt == 0) return 0;
        uint256 eligible = uint256(armedAt) + TRANSFER_DELAY;
        return block.timestamp >= eligible ? 0 : eligible - block.timestamp;
    }

    /// @notice Every release precondition, evaluated without reverting. For keepers and dashboards.
    /// @return isGraduated_ Whether the PONS curve for HOODZ has graduated.
    /// @return lpLocked_ Whether the graduated LP position is permanently locked.
    /// @return armed_ Whether the governor has armed the handoff.
    /// @return delayElapsed_ Whether {TRANSFER_DELAY} has elapsed since {arm}.
    /// @return released_ Whether mint authority has already moved to the Treasury.
    function releaseStatus()
        external
        view
        returns (bool isGraduated_, bool lpLocked_, bool armed_, bool delayElapsed_, bool released_)
    {
        isGraduated_ = _isGraduated();
        (lpLocked_,) = _lockState();
        armed_ = armedAt != 0;
        delayElapsed_ = armed_ && block.timestamp >= uint256(armedAt) + TRANSFER_DELAY;
        released_ = released;
    }

    /// @notice Whether {releaseToTreasury} would succeed if called right now.
    /// @return True only if every precondition currently holds.
    function canRelease() external view returns (bool) {
        if (released || armedAt == 0 || !graduationVerified) return false;
        if (block.timestamp < uint256(armedAt) + TRANSFER_DELAY) return false;
        if (!_isGraduated()) return false;
        (bool ok,) = _lockState();
        return ok;
    }

    /// @notice Whether this guard currently sits in the HOODZ vault role, freezing supply.
    /// @return True while the guard is the vault on the authority captured at deployment.
    function holdsVaultRole() external view returns (bool) {
        return IHoodzAuthority(HOODZ_AUTHORITY).vault() == address(this);
    }

    /* --------------------------------------------------------------- internal */

    /// @dev Non-reverting read of the launchpad's graduation flag.
    function _isGraduated() private view returns (bool) {
        try LAUNCHPAD.isGraduated(HOODZ) returns (bool graduated_) {
            return graduated_;
        } catch {
            return false;
        }
    }

    /// @dev Non-reverting proof that the graduated LP position can never be unwound.
    ///      Every branch is a way the lock could be fake, so every branch fails closed.
    /// @return ok True only if the position exists, holds liquidity, and has no unlock path at all.
    /// @return pool The graduated pool as reported by the launchpad.
    function _lockState() private view returns (bool ok, address pool) {
        try LAUNCHPAD.poolOf(HOODZ) returns (address pool_) {
            pool = pool_;
        } catch {
            return (false, address(0));
        }
        if (pool == address(0)) return (false, address(0));

        IPositionLocker.LockedPosition memory position;
        try LOCKER.lockOf(HOODZ) returns (IPositionLocker.LockedPosition memory position_) {
            position = position_;
        } catch {
            return (false, pool);
        }

        // The lock must be for this token, in this pool, and hold real liquidity.
        if (position.token != HOODZ) return (false, pool);
        if (position.pool != pool) return (false, pool);
        if (position.liquidity == 0) return (false, pool);
        // The pool key must actually hash to the recorded pool id, so the id cannot be spoofed.
        if (PonsPoolId.toId(position.key) != position.poolId) return (false, pool);
        // No unlock path may exist, now or ever.
        if (position.unlockable) return (false, pool);
        if (position.unlockTime != type(uint256).max) return (false, pool);

        try LOCKER.isPermanentlyLocked(HOODZ) returns (bool locked) {
            if (!locked) return (false, pool);
        } catch {
            return (false, pool);
        }

        try LOCKER.unlockable(HOODZ) returns (bool unlockable_) {
            if (unlockable_) return (false, pool);
        } catch {
            return (false, pool);
        }

        // Independent cross-check against the v4 singleton, when one is configured.
        if (address(POOL_MANAGER) != address(0)) {
            try POOL_MANAGER.getLiquidity(position.poolId) returns (uint128 liquidity) {
                if (liquidity == 0) return (false, pool);
            } catch {
                return (false, pool);
            }
        }

        return (true, pool);
    }
}
