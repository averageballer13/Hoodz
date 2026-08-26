// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @dev UNAUDITED. Do not use in production without a full audit.

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title  MockERC20
/// @notice Test-only ERC20 with a configurable decimal count and permissionless mint/burn.
/// @dev    The decimal count is the whole point: `HoodzTreasury.tokenValue()` normalises reserve
///         tokens (6 / 8 / 18 decimals) down to HOODZ's 9, and that conversion needs exercising
///         against more than one shape of token.
contract MockERC20 is ERC20 {
    uint8 private immutable _decimalsOverride;

    /// @param name_ ERC20 name.
    /// @param symbol_ ERC20 symbol.
    /// @param decimals_ Decimal count reported by {decimals}.
    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimalsOverride = decimals_;
    }

    /// @notice The configured decimal count.
    /// @return The number of decimals this mock reports.
    function decimals() public view override returns (uint8) {
        return _decimalsOverride;
    }

    /// @notice Mints tokens to any address. Test-only, deliberately unguarded.
    /// @param to_ Recipient.
    /// @param amount_ Amount to mint.
    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }

    /// @notice Burns tokens from any address. Test-only, deliberately unguarded.
    /// @param from_ Holder to burn from.
    /// @param amount_ Amount to burn.
    function burn(address from_, uint256 amount_) external {
        _burn(from_, amount_);
    }
}
