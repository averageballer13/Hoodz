// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @dev UNAUDITED. Do not use in production without a full audit.

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title  MockPonsToken
/// @notice Stand-in for the HOODZ token the PONS launchpad deploys. TEST ONLY.
/// @dev    This contract exists so the suite has something to point `IHOODZ` at. It is deliberately
///         as dumb as the real thing:
///
///           * fixed supply, minted once in the constructor and never again;
///           * no `mint`, no `burn`, no owner, no pause, no tax, no hooks;
///           * the whole supply goes to one address, standing in for the bonding curve.
///
///         Do NOT deploy this. On Robinhood Chain the real token comes out of the PONS factory when
///         the launch form is submitted, and this repository never touches its bytecode. If you find
///         yourself wanting to add `mint` here to make a test pass, the test is wrong: the protocol
///         has to work without one.
contract MockPonsToken is ERC20 {
    /// @dev PONS launches are fixed at one billion tokens.
    uint256 public constant PONS_SUPPLY = 1_000_000_000;

    uint8 private immutable _decimals;

    /// @param name_      Token name.
    /// @param symbol_    Token symbol.
    /// @param decimals_  Decimals the launchpad gave the token.
    /// @param curve_     Address receiving the entire supply, standing in for the bonding curve.
    constructor(string memory name_, string memory symbol_, uint8 decimals_, address curve_)
        ERC20(name_, symbol_)
    {
        _decimals = decimals_;
        _mint(curve_, PONS_SUPPLY * (10 ** decimals_));
    }

    /// @inheritdoc ERC20
    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}
