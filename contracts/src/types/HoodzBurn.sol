// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @dev UNAUDITED. Do not use in production without a full audit.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title  HoodzBurn
/// @notice Burning HOODZ when HOODZ has no burn function.
/// @dev    HOODZ is deployed by the PONS launchpad, not by this repo: a plain fixed-supply ERC20
///         with no `burn`, no `mint` and no owner. So "burn" here means the only thing that works
///         on an arbitrary ERC20 - an ordinary transfer to an address whose private key cannot
///         exist. The supply figure reported by the token does not move; the circulating supply
///         does, permanently and verifiably on the explorer.
///
///         Use {circulatingSupply} rather than `totalSupply()` anywhere the number matters.
library HoodzBurn {
    using SafeERC20 for IERC20;

    /// @notice The canonical dead address. No private key maps to it.
    address internal constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Send `amount` of `token` somewhere it can never come back from.
    /// @param token  The token to burn.
    /// @param amount Amount to burn. Zero is a no-op.
    function burn(IERC20 token, uint256 amount) internal {
        if (amount == 0) return;
        token.safeTransfer(BURN_ADDRESS, amount);
    }

    /// @notice Pull `amount` from `from` and burn it. Requires an allowance.
    /// @param token  The token to burn.
    /// @param from   Holder to pull from.
    /// @param amount Amount to burn. Zero is a no-op.
    function burnFrom(IERC20 token, address from, uint256 amount) internal {
        if (amount == 0) return;
        token.safeTransferFrom(from, BURN_ADDRESS, amount);
    }

    /// @notice Total supply minus everything sent to the dead address.
    /// @param token The token to measure.
    /// @return The supply that can still move.
    function circulatingSupply(IERC20 token) internal view returns (uint256) {
        return token.totalSupply() - token.balanceOf(BURN_ADDRESS);
    }

    /// @notice How much of `token` has been burned so far.
    /// @param token The token to measure.
    /// @return The balance parked at the dead address.
    function burned(IERC20 token) internal view returns (uint256) {
        return token.balanceOf(BURN_ADDRESS);
    }
}
