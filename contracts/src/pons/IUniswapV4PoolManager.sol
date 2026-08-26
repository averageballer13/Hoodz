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

/// @notice Minimal mirror of the Uniswap v4 `PoolKey`.
/// @dev The real v4 type wraps `currency0`/`currency1` in the `Currency` user-defined value type and
///      `hooks` in `IHooks`; both are `address` under the hoodz, so the ABI encoding - and therefore the
///      derived pool id - is identical. Currencies are sorted ascending, and the native asset is the
///      zero address.
/// @param currency0 Lower-sorted asset of the pair.
/// @param currency1 Higher-sorted asset of the pair.
/// @param fee LP fee in hundredths of a bip (3000 = 0.30%); the dynamic-fee flag is 0x800000.
/// @param tickSpacing Tick spacing of the pool.
/// @param hooks Hook contract attached to the pool, or `address(0)` for none.
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @title PonsPoolId
/// @notice Derives the Uniswap v4 pool id from a {PoolKey}.
library PonsPoolId {
    /// @notice Hash a pool key into its v4 pool id.
    /// @param key The pool key.
    /// @return id The keccak256 of the ABI-encoded key, matching v4's `PoolIdLibrary.toId`.
    function toId(PoolKey memory key) internal pure returns (bytes32 id) {
        id = keccak256(abi.encode(key));
    }
}

/// @title IUniswapV4PoolManager
/// @notice Read-only slice of the Uniswap v4 singleton PoolManager that Hoodz integrates against.
/// @dev Hoodz never provides, moves or removes liquidity in v4 - the graduated PONS position is
///      locked forever. This interface exists purely so {HoodzLaunchGuard} can independently confirm
///      that the graduated pool is initialised and actually holds liquidity before mint authority is
///      released to the Treasury. `getLiquidity` / `getSlot0` are the `StateLibrary` reads exposed as
///      plain view functions by the PONS deployment's read facade; `extsload` is the raw v4 primitive
///      they are built from.
interface IUniswapV4PoolManager {
    /// @notice Total in-range liquidity of a pool.
    /// @param id The v4 pool id, see {PonsPoolId-toId}.
    /// @return liquidity Current pool liquidity; zero for an uninitialised or fully drained pool.
    function getLiquidity(bytes32 id) external view returns (uint128 liquidity);

    /// @notice Current price and fee state of a pool.
    /// @param id The v4 pool id, see {PonsPoolId-toId}.
    /// @return sqrtPriceX96 Square root of the pool price, Q64.96; zero if uninitialised.
    /// @return tick Current tick.
    /// @return protocolFee Packed protocol fee, in hundredths of a bip per direction.
    /// @return lpFee Current LP fee, in hundredths of a bip.
    function getSlot0(bytes32 id)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);

    /// @notice Raw storage read on the v4 singleton.
    /// @param slot The storage slot to read.
    /// @return value The word stored at `slot`.
    function extsload(bytes32 slot) external view returns (bytes32 value);
}
