// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @dev UNAUDITED. Do not use in production without a full audit.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IsHOODZ} from "../../src/interfaces/IsHOODZ.sol";

/// @title  MockStaking
/// @notice The bare minimum sHOODZ needs from a staking contract, so the rebase and gons maths
///         can be tested without standing the whole protocol up.
/// @dev    `sHOODZ.initialize` grants its entire gon supply to the staking contract, and
///         `circulatingSupply()` is `totalSupply - balanceOf(staking) + gHOODZ float +
///         staking.supplyInWarmup()`. This mock owns that float and hands it out with
///         {transferTo}, which is how a test puts sHOODZ "in circulation".
contract MockStaking {
    /// @notice The sHOODZ token this mock drives.
    IsHOODZ public sHoodz;

    /// @notice Value reported to sHOODZ as sitting in staking warmup.
    uint256 public supplyInWarmup;

    /// @notice Thrown before {setSHoodz} has been called.
    error NotInitialized();

    /// @notice Points the mock at an sHOODZ deployment.
    /// @param sHoodz_ The sHOODZ token.
    function setSHoodz(address sHoodz_) external {
        sHoodz = IsHOODZ(sHoodz_);
    }

    /// @notice Sets the warmup float reported to sHOODZ.
    /// @param amount_ Amount considered "in warmup".
    function setSupplyInWarmup(uint256 amount_) external {
        supplyInWarmup = amount_;
    }

    /// @notice Triggers a rebase as the staking contract.
    /// @param profit_ Rebase profit, in sHOODZ units (9 decimals).
    /// @param epoch_ Epoch number to stamp on the rebase.
    /// @return The new total supply.
    function rebase(uint256 profit_, uint256 epoch_) external returns (uint256) {
        if (address(sHoodz) == address(0)) revert NotInitialized();
        return sHoodz.rebase(profit_, epoch_);
    }

    /// @notice Moves sHOODZ out of the staking float, simulating a stake.
    /// @param to_ Recipient.
    /// @param amount_ Amount of sHOODZ to send.
    function transferTo(address to_, uint256 amount_) external {
        if (address(sHoodz) == address(0)) revert NotInitialized();
        IERC20(address(sHoodz)).transfer(to_, amount_);
    }

    /// @notice The current sHOODZ index.
    /// @return The index, 9 decimals.
    function index() external view returns (uint256) {
        return sHoodz.index();
    }
}
