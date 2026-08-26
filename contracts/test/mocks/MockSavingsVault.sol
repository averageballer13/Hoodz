// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @dev UNAUDITED. Do not use in production without a full audit.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

/// @title  MockSavingsVault
/// @notice Minimal ERC-4626 savings wrapper around the reserve token - the sDAI-shaped vault the
///         Yield Repurchase Facility and the Hoodz Loans clearinghouse park idle reserves in.
/// @dev    Yield is simulated by donating assets with {accrue}: the share price rises for every
///         holder, which is exactly the cash flow the YRF harvests.
contract MockSavingsVault is ERC4626 {
    /// @param asset_ The underlying reserve token.
    /// @param name_ ERC20 name of the share token.
    /// @param symbol_ ERC20 symbol of the share token.
    constructor(IERC20 asset_, string memory name_, string memory symbol_) ERC20(name_, symbol_) ERC4626(asset_) {}

    /// @notice Donates assets to the vault, raising the share price for every holder.
    /// @dev The caller must have approved this contract for `amount_` of the underlying.
    /// @param amount_ Amount of underlying to donate as yield.
    function accrue(uint256 amount_) external {
        IERC20(asset()).transferFrom(msg.sender, address(this), amount_);
    }
}
