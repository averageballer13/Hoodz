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

import {PoolKey} from "./IUniswapV4PoolManager.sol";

/// @title IPositionLocker
/// @notice Minimal integration surface for the contract that owns the graduated PONS LP position.
/// @dev On graduation the curve's reserves and remaining supply are deposited into a Uniswap v4 pool
///      and the resulting position is transferred to this locker with **no** unlock path: `unlockable`
///      is false and `unlockTime` is `type(uint256).max` forever. Only the accrued trading fees can be
///      collected, and only to `beneficiary` - the principal can never be withdrawn by anyone,
///      including PONS, the launch creator and Hoodz governance.
///
///      {HoodzLaunchGuard} reads this interface as one of the three preconditions for handing HOODZ mint
///      authority to the Treasury. A locker that returns "unlockable" for HOODZ blocks the release.
interface IPositionLocker {
    /// @notice The permanently locked LP position backing a graduated launch.
    /// @param token The launched token.
    /// @param pool The graduated Uniswap v4 pool.
    /// @param poolId The v4 pool id.
    /// @param key The v4 pool key the position was minted against.
    /// @param positionId Identifier of the locked position within the position manager.
    /// @param liquidity Locked liquidity; never decreases.
    /// @param beneficiary Address allowed to collect the position's trading fees. Fees only, never principal.
    /// @param unlockTime Timestamp at which the principal could be withdrawn; `type(uint256).max` = never.
    /// @param unlockable Whether any unlock path exists at all. False forever for a graduated PONS pool.
    struct LockedPosition {
        address token;
        address pool;
        bytes32 poolId;
        PoolKey key;
        uint256 positionId;
        uint128 liquidity;
        address beneficiary;
        uint256 unlockTime;
        bool unlockable;
    }

    /// @notice Emitted once, when a graduated position is locked forever.
    event PositionLocked(address indexed token, address indexed pool, uint256 positionId, uint128 liquidity);

    /// @notice Emitted when the position's accrued trading fees are collected to the beneficiary.
    event FeesCollected(address indexed token, address indexed beneficiary, uint256 amount0, uint256 amount1);

    /// @notice The locked position recorded for a launched token.
    /// @param token The launched token.
    /// @return position The locked position; a zero `pool` means nothing is locked for this token.
    function lockOf(address token) external view returns (LockedPosition memory position);

    /// @notice Whether the launched token's LP position is locked with no unlock path whatsoever.
    /// @param token The launched token.
    /// @return True only if a position exists, holds liquidity, and can never be unlocked.
    function isPermanentlyLocked(address token) external view returns (bool);

    /// @notice Whether any unlock path exists for the launched token's position.
    /// @param token The launched token.
    /// @return False forever for a graduated PONS pool.
    function unlockable(address token) external view returns (bool);

    /// @notice Address entitled to collect the locked position's trading fees.
    /// @param token The launched token.
    /// @return The fee beneficiary.
    function beneficiary(address token) external view returns (address);
}
