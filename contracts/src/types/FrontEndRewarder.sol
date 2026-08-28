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

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IHoodzAuthority} from "../interfaces/IHoodzAuthority.sol";
import {HoodzAccessControlled} from "./HoodzAccessControlled.sol";

/**
 * @title  FrontEndRewarder
 * @author Hoodz
 * @notice Referral / DAO reward accounting for Hoodz bond markets.
 * @dev    Port of the Olympus V2 `FrontEndRewarder`. Rewards are denominated in HOOD and
 *         accrue as a pull-payment balance; they are minted alongside the bond payout by
 *         the inheriting NoteKeeper, so this contract never needs a funding step.
 *
 *         Reward rates are expressed out of `RATE_DENOMINATOR` (1e4): 100 = 1.00%.
 */
abstract contract FrontEndRewarder is HoodzAccessControlled {
    using SafeERC20 for IERC20;

    /* ========== ERRORS ========== */

    /// @notice Thrown when `getReward` is called with a zero accrued balance.
    error FrontEndRewarder_NothingToClaim();

    /// @notice Thrown when a reward rate above `MAX_REWARD_RATE` is proposed.
    error FrontEndRewarder_RateTooHigh(uint256 rate, uint256 max);

    /// @notice Thrown when the zero address is passed where a real address is required.
    error FrontEndRewarder_ZeroAddress();

    /* ========== EVENTS ========== */

    /// @notice Emitted when the governor updates the reward rates.
    event RewardsSet(uint256 toFrontEnd, uint256 toDAO);

    /// @notice Emitted when an operator's whitelist status is toggled.
    event Whitelisted(address indexed operator, bool status);

    /// @notice Emitted when accrued rewards are claimed.
    event RewardsClaimed(address indexed operator, uint256 amount);

    /* ========== CONSTANTS ========== */

    /// @notice Denominator for the reward rates. 100 / 1e4 == 1%.
    uint256 public constant RATE_DENOMINATOR = 1e4;

    /// @notice Hoodz addition: hard ceiling on either reward rate (10%).
    uint256 public constant MAX_REWARD_RATE = 1e3;

    /* ========== STATE ========== */

    /// @notice Share of every bond payout minted to the DAO, out of `RATE_DENOMINATOR`.
    uint256 public daoReward;

    /// @notice Share of every bond payout minted to a whitelisted referrer, out of `RATE_DENOMINATOR`.
    uint256 public refReward;

    /// @notice Unclaimed HOOD rewards per recipient.
    mapping(address => uint256) public rewards;

    /// @notice Front end operators approved to earn `refReward`.
    mapping(address => bool) public whitelisted;

    /// @notice The reward token (HOOD).
    IERC20 internal immutable hoodz;

    /* ========== CONSTRUCTOR ========== */

    /**
     * @param _authority Hoodz authority contract.
     * @param _hoodz      HOOD token used to pay rewards.
     */
    constructor(IHoodzAuthority _authority, IERC20 _hoodz) HoodzAccessControlled(_authority) {
        if (address(_hoodz) == address(0)) revert FrontEndRewarder_ZeroAddress();
        hoodz = _hoodz;
    }

    /* ========== EXTERNAL ========== */

    /**
     * @notice Claim all HOOD rewards accrued by the caller.
     * @dev    Pull payment: the balance is zeroed before the transfer.
     * @return reward_ Amount of HOOD transferred to the caller.
     */
    function getReward() external returns (uint256 reward_) {
        reward_ = rewards[msg.sender];
        if (reward_ == 0) revert FrontEndRewarder_NothingToClaim();

        rewards[msg.sender] = 0;
        hoodz.safeTransfer(msg.sender, reward_);

        emit RewardsClaimed(msg.sender, reward_);
    }

    /**
     * @notice Set the referral and DAO reward rates.
     * @dev    Governor only. Both rates are out of `RATE_DENOMINATOR` and capped at `MAX_REWARD_RATE`.
     * @param _toFrontEnd New referral rate.
     * @param _toDAO      New DAO rate.
     */
    function setRewards(uint256 _toFrontEnd, uint256 _toDAO) external onlyGovernor {
        if (_toFrontEnd > MAX_REWARD_RATE) revert FrontEndRewarder_RateTooHigh(_toFrontEnd, MAX_REWARD_RATE);
        if (_toDAO > MAX_REWARD_RATE) revert FrontEndRewarder_RateTooHigh(_toDAO, MAX_REWARD_RATE);

        refReward = _toFrontEnd;
        daoReward = _toDAO;

        emit RewardsSet(_toFrontEnd, _toDAO);
    }

    /**
     * @notice Toggle whether `_operator` may earn referral rewards.
     * @dev    Policy only. Mirrors the Olympus toggle semantics.
     * @param _operator Front end operator address.
     * @return status_ The operator's whitelist status after the toggle.
     */
    function whitelist(address _operator) external onlyPolicy returns (bool status_) {
        if (_operator == address(0)) revert FrontEndRewarder_ZeroAddress();

        status_ = !whitelisted[_operator];
        whitelisted[_operator] = status_;

        emit Whitelisted(_operator, status_);
    }

    /* ========== INTERNAL ========== */

    /**
     * @notice Book the DAO and referral rewards owed on a bond payout.
     * @dev    The DAO receives both shares when the referrer is not whitelisted.
     * @param _payout   Bond payout, in HOOD.
     * @param _referral Front end operator that referred the deposit.
     * @return Total HOOD that must be minted on top of `_payout` to cover the rewards.
     */
    function _giveRewards(uint256 _payout, address _referral) internal returns (uint256) {
        uint256 toDAO = (_payout * daoReward) / RATE_DENOMINATOR;
        uint256 toRef = (_payout * refReward) / RATE_DENOMINATOR;

        address dao = authority.guardian();

        if (whitelisted[_referral]) {
            rewards[_referral] += toRef;
            rewards[dao] += toDAO;
        } else {
            rewards[dao] += toDAO + toRef;
        }

        return toDAO + toRef;
    }
}
