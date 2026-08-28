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
        X      https://x.com/Hoodzfinance
        Code   https://github.com/averageballer13/Hoodz

        UNAUDITED. This code has never been audited. Read it before you
        trust it with anything you would miss.
*/

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title HoodzTimelock
 * @notice The Hoodz execution timelock: every proposal that clears {HoodzGovernor} is scheduled
 *         here and can only be executed after `MIN_DELAY` has elapsed.
 * @dev Thin wrapper around OpenZeppelin v5 `TimelockController` that hard-codes the Hoodz
 *      minimum delay of 2 days. Time-based, not block-based: `TimelockController` uses
 *      `block.timestamp`, so the 2-second block time of Robinhood Chain (chainId 4663) is
 *      irrelevant here — unlike {HoodzGovernor}, whose windows are denominated in blocks.
 *
 *      Intended role wiring (mirrors the OlympusDAO / OZ Governor reference setup):
 *      - `PROPOSER_ROLE`  -> the {HoodzGovernor} address, and nothing else.
 *      - `CANCELLER_ROLE` -> the {HoodzGovernor} address plus, optionally, the Hoodz guardian
 *                            multisig (the `guardian` role of `HoodzAuthority`) so a malicious
 *                            queued batch can be killed inside the 2-day window.
 *      - `EXECUTOR_ROLE`  -> `address(0)` for a permissionless executor (anyone may push a ready
 *                            batch through), or a keeper address for a closed setup.
 *      - `admin`          -> a bootstrap multisig that wires the roles above and then renounces
 *                            `DEFAULT_ADMIN_ROLE`, leaving the timelock self-administered.
 *
 *      This contract is the intended `governor` of `HoodzAuthority`, which makes it the ultimate
 *      owner of the Hoodz Treasury, staking, bonding and Hoodz Loans stack.
 *
 *      UNAUDITED. Do not use in production without a full audit.
 */
contract HoodzTimelock is TimelockController {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the timelock is deployed without at least one proposer.
    error HoodzTimelock__NoProposer();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice The minimum delay, in seconds, between scheduling and executing a batch: 2 days.
    /// @dev Governance can raise or lower this later only through `updateDelay`, which is itself
    ///      `onlyRole(address(this))` and therefore has to travel through the timelock.
    uint256 public constant MIN_DELAY = 2 days;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploys the Hoodz timelock with a fixed 2-day minimum delay.
     * @param proposers Addresses granted `PROPOSER_ROLE` and `CANCELLER_ROLE`. Must contain at
     *        least one entry; in the canonical deployment this is `[address(hoodzGovernor)]`.
     * @param executors Addresses granted `EXECUTOR_ROLE`. Pass `[address(0)]` to let anyone
     *        execute a batch whose delay has elapsed.
     * @param admin Optional bootstrap admin granted `DEFAULT_ADMIN_ROLE`. Pass `address(0)` for a
     *        fully self-administered timelock, or a deployer multisig that renounces the role once
     *        the roles above are wired.
     */
    constructor(address[] memory proposers, address[] memory executors, address admin)
        TimelockController(MIN_DELAY, proposers, executors, admin)
    {
        if (proposers.length == 0) revert HoodzTimelock__NoProposer();
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Whether execution of ready batches is permissionless.
     * @return open True when `address(0)` holds `EXECUTOR_ROLE`, meaning any account can call
     *         `execute` / `executeBatch` on an operation whose delay has elapsed.
     */
    function isOpenExecutor() external view returns (bool open) {
        open = hasRole(EXECUTOR_ROLE, address(0));
    }

    /**
     * @notice Whether the timelock is self-administered.
     * @dev The end state of a correct deployment: no external account can grant or revoke roles
     *      without going through a governance proposal and the full 2-day delay.
     * @param bootstrapAdmin The address that was passed as `admin` at construction.
     * @return selfAdministered True when `bootstrapAdmin` no longer holds `DEFAULT_ADMIN_ROLE`.
     */
    function isSelfAdministered(address bootstrapAdmin) external view returns (bool selfAdministered) {
        selfAdministered = bootstrapAdmin == address(0) || !hasRole(DEFAULT_ADMIN_ROLE, bootstrapAdmin);
    }
}
