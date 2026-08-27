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

import {IUniswapV2ERC20} from "./IUniswapV2ERC20.sol";

/// @title IUniswapV2Pair
/// @notice Minimal constant-product pair interface used to value Hoodz liquidity reserves.
/// @dev Hoodz only ever reads from a pair (`token0`, `token1`, `getReserves`, `totalSupply`);
///      the mutative members are declared for completeness of the standard surface.
interface IUniswapV2Pair is IUniswapV2ERC20 {
    /// @notice Emitted when the cached reserves are updated.
    event Sync(uint112 reserve0, uint112 reserve1);

    /// @notice Factory that deployed this pair.
    /// @return The factory address.
    function factory() external view returns (address);

    /// @notice First token of the pair, ordered by address.
    /// @return The token0 address.
    function token0() external view returns (address);

    /// @notice Second token of the pair, ordered by address.
    /// @return The token1 address.
    function token1() external view returns (address);

    /// @notice Cached reserves of the pair.
    /// @return reserve0 Reserve of `token0`.
    /// @return reserve1 Reserve of `token1`.
    /// @return blockTimestampLast Timestamp of the last reserve update, truncated to 32 bits.
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    /// @notice Cumulative price of `token0` used by TWAP oracles.
    /// @return The cumulative price.
    function price0CumulativeLast() external view returns (uint256);

    /// @notice Cumulative price of `token1` used by TWAP oracles.
    /// @return The cumulative price.
    function price1CumulativeLast() external view returns (uint256);

    /// @notice Value of `reserve0 * reserve1` as of the last liquidity event.
    /// @return The last recorded k.
    function kLast() external view returns (uint256);

    /// @notice Mint LP shares against tokens already transferred into the pair.
    /// @param to Recipient of the new LP shares.
    /// @return liquidity LP shares minted.
    function mint(address to) external returns (uint256 liquidity);

    /// @notice Burn LP shares already transferred into the pair and return the underlying.
    /// @param to Recipient of the underlying tokens.
    /// @return amount0 Amount of `token0` returned.
    /// @return amount1 Amount of `token1` returned.
    function burn(address to) external returns (uint256 amount0, uint256 amount1);

    /// @notice Execute a swap against the pair.
    /// @param amount0Out Amount of `token0` to send out.
    /// @param amount1Out Amount of `token1` to send out.
    /// @param to Recipient of the output tokens.
    /// @param data Optional flash-swap callback payload.
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;

    /// @notice Force the cached reserves to match the pair's real balances.
    function sync() external;
}
