// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @dev UNAUDITED. Do not use in production without a full audit.

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {GovernorVotesQuorumFraction} from
    "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {HoodzTimelock} from "./HoodzTimelock.sol";

/**
 * @title HoodzGovernor
 * @notice On-chain governance for Hoodz. Voting power is gHOODZ (`ERC20Votes`), the index-bearing
 *         wrapper around staked HOODZ, so voting weight tracks a share of the staking pool and is
 *         immune to sHOODZ rebases.
 * @dev OpenZeppelin v5 Governor composed of:
 *      `Governor` + `GovernorSettings` + `GovernorCountingSimple` + `GovernorVotes` +
 *      `GovernorVotesQuorumFraction` + `GovernorTimelockControl`.
 *
 *      CLOCK. gHOODZ does not override `clock()` / `CLOCK_MODE()`, so it uses the ERC-6372 default
 *      block-number clock (`mode=blocknumber&from=default`). `GovernorVotes.clock()` mirrors the
 *      token, which means every window below is denominated in BLOCKS, not seconds. Robinhood Chain
 *      (chainId 4663) produces a block every ~2 seconds, hence:
 *
 *      | Parameter          | Value                         | Wall clock |
 *      | ------------------ | ----------------------------- | ---------- |
 *      | votingDelay        | 43,200 blocks                 | ~1 day     |
 *      | votingPeriod       | 216,000 blocks                | ~5 days    |
 *      | proposalThreshold  | 1,000e18 gHOODZ                | -          |
 *      | quorum             | 4% of gHOODZ past total supply | -          |
 *      | timelock minDelay  | 2 days, seconds-based         | ~2 days    |
 *
 *      Should Robinhood Chain change its block cadence, governance can re-tune the three
 *      `GovernorSettings` values through a proposal (`setVotingDelay`, `setVotingPeriod`,
 *      `setProposalThreshold`) - all `onlyGovernance`, i.e. executable only by the timelock.
 *
 *      EXECUTION. `_executor()` is the {HoodzTimelock}, so a passed proposal is scheduled on the
 *      timelock and executed from it. The timelock - not this contract - is the `governor` of
 *      `HoodzAuthority` and therefore the ultimate owner of the Treasury, staking, bonding and
 *      Hoodz Loans stack.
 *
 *      UNAUDITED. Do not use in production without a full audit.
 */
contract HoodzGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl
{
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the gHOODZ token or the timelock is the zero address.
    error HoodzGovernor__ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Human-readable governor name, also the EIP-712 domain name used by `castVoteBySig`.
    string private constant GOVERNOR_NAME = "Hoodz Governor";

    /// @notice Nominal Robinhood Chain block time in seconds, used only to convert block-denominated
    ///         windows into an approximate wall-clock duration for UIs.
    uint256 public constant BLOCK_TIME_SECONDS = 2;

    /// @notice Blocks between a proposal being created and voting opening: ~1 day at 2s blocks.
    uint48 public constant INITIAL_VOTING_DELAY = 43_200;

    /// @notice Blocks the poll stays open: ~5 days at 2s blocks.
    uint32 public constant INITIAL_VOTING_PERIOD = 216_000;

    /// @notice gHOODZ voting power required to submit a proposal.
    uint256 public constant INITIAL_PROPOSAL_THRESHOLD = 1_000e18;

    /// @notice Quorum as a percentage of the gHOODZ total supply at the proposal snapshot.
    uint256 public constant INITIAL_QUORUM_NUMERATOR = 4;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploys the Hoodz governor.
     * @param gHOODZ The gHOODZ token (`ERC20Votes`, default block-number clock) used for voting power.
     * @param timelock The {HoodzTimelock} that queues and executes successful proposals. This
     *        governor must hold `PROPOSER_ROLE` (and ideally `CANCELLER_ROLE`) on it.
     */
    constructor(IVotes gHOODZ, HoodzTimelock timelock)
        Governor(GOVERNOR_NAME)
        GovernorSettings(INITIAL_VOTING_DELAY, INITIAL_VOTING_PERIOD, INITIAL_PROPOSAL_THRESHOLD)
        GovernorVotes(gHOODZ)
        GovernorVotesQuorumFraction(INITIAL_QUORUM_NUMERATOR)
        GovernorTimelockControl(timelock)
    {
        if (address(gHOODZ) == address(0) || address(timelock) == address(0)) revert HoodzGovernor__ZeroAddress();
    }

    /*//////////////////////////////////////////////////////////////
                          HOODZ CONVENIENCE VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Current voting delay expressed in seconds rather than blocks.
     * @dev Approximation only: `votingDelay()` is authoritative and is measured in blocks.
     * @return delaySeconds `votingDelay() * BLOCK_TIME_SECONDS`.
     */
    function votingDelaySeconds() external view returns (uint256 delaySeconds) {
        delaySeconds = votingDelay() * BLOCK_TIME_SECONDS;
    }

    /**
     * @notice Current voting period expressed in seconds rather than blocks.
     * @dev Approximation only: `votingPeriod()` is authoritative and is measured in blocks.
     * @return periodSeconds `votingPeriod() * BLOCK_TIME_SECONDS`.
     */
    function votingPeriodSeconds() external view returns (uint256 periodSeconds) {
        periodSeconds = votingPeriod() * BLOCK_TIME_SECONDS;
    }

    /**
     * @notice Quorum that a proposal created in this block would have to clear.
     * @dev Evaluated at `clock() - 1` because ERC-5805 checkpoint lookups are only defined for
     *      timepoints strictly in the past.
     * @return quorumVotes gHOODZ votes required for such a proposal to be quorate.
     */
    function currentQuorum() external view returns (uint256 quorumVotes) {
        uint48 timepoint = clock();
        quorumVotes = timepoint == 0 ? 0 : quorum(timepoint - 1);
    }

    /*//////////////////////////////////////////////////////////////
                     OVERRIDES REQUIRED BY SOLIDITY
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Blocks that must pass after a proposal is created before voting opens.
     * @return The voting delay in blocks (~1 day at the 2s Robinhood Chain block time).
     */
    function votingDelay() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingDelay();
    }

    /**
     * @notice Number of blocks a proposal stays open for voting.
     * @return The voting period in blocks (~5 days at the 2s Robinhood Chain block time).
     */
    function votingPeriod() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingPeriod();
    }

    /**
     * @notice gHOODZ votes required at the snapshot for a proposal to be quorate.
     * @param timepoint Block number of the proposal snapshot.
     * @return The quorum, i.e. 4% of the gHOODZ total supply at `timepoint`.
     */
    function quorum(uint256 timepoint) public view override(Governor, GovernorVotesQuorumFraction) returns (uint256) {
        return super.quorum(timepoint);
    }

    /**
     * @notice Lifecycle state of a proposal, timelock-aware.
     * @param proposalId Identifier returned by `propose` / `getProposalId`.
     * @return The proposal state, including `Queued` once scheduled on the {HoodzTimelock}.
     */
    function state(uint256 proposalId) public view override(Governor, GovernorTimelockControl) returns (ProposalState) {
        return super.state(proposalId);
    }

    /**
     * @notice Whether a successful proposal must be queued before it can be executed.
     * @param proposalId Identifier of the proposal.
     * @return Always true: every Hoodz proposal routes through the 2-day timelock.
     */
    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    /**
     * @notice gHOODZ voting power an account must hold at the previous block to submit a proposal.
     * @return The proposal threshold in gHOODZ (18 decimals).
     */
    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.proposalThreshold();
    }

    /**
     * @dev Schedules the batch on the {HoodzTimelock}.
     * @return ETA, as a timestamp, at which the batch becomes executable.
     */
    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    /// @dev Executes the queued batch through the {HoodzTimelock}, so calls originate from it.
    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    /// @dev Cancels the proposal here and, if already scheduled, on the {HoodzTimelock} too.
    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    /// @dev The {HoodzTimelock}: the address proposals execute from and the holder of protocol roles.
    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }
}
