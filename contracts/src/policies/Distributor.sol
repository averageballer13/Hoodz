// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @dev UNAUDITED. Do not use in production without a full audit.

import {ITreasury} from "../interfaces/ITreasury.sol";
import {IDistributor} from "../interfaces/IDistributor.sol";
import {IHoodzAuthority} from "../interfaces/IHoodzAuthority.sol";
import {HoodzAccessControlled} from "../types/HoodzAccessControlled.sol";

/**
 * @title  Distributor
 * @notice Hoodz's emissions policy. A faithful re-implementation of the Olympus
 *         `Distributor`: every time `HoodzStaking.rebase()` rolls an epoch it calls
 *         `distribute()`, which mints each recipient `baseSupply * rate / 1e6` HOODZ from the
 *         Hoodz Treasury. The staking contract is normally recipient #0, so its share becomes
 *         the next epoch's `epoch.distribute` and thus the sHOODZ rebase.
 *
 *         Rates are per-epoch and expressed in millionths (`RATE_DENOMINATOR = 1_000_000`),
 *         so `5000` = 0.5% of base supply per epoch. Rates can be walked toward a target
 *         one epoch at a time via `setAdjustment` (the "reward rate ramp").
 *
 * @dev    UNAUDITED. Do not use in production without a full audit.
 */
contract Distributor is IDistributor, HoodzAccessControlled {
    /* ========================================= ERRORS ========================================= */

    /// @notice A constructor argument or recipient was the zero address.
    error Distributor_ZeroAddress();
    /// @notice Only the staking contract may pull emissions.
    error Distributor_OnlyStaking(address caller);
    /// @notice Caller holds neither the governor nor the guardian role.
    error Distributor_NotGovernorOrGuardian(address caller);
    /// @notice A rate above `RATE_DENOMINATOR` (100% of base supply per epoch) was supplied.
    error Distributor_RateExceedsDenominator(uint256 rate);
    /// @notice No recipient is registered at that index.
    error Distributor_RecipientDoesNotExist(uint256 index);
    /// @notice The index is past the end of the recipient array.
    error Distributor_IndexOutOfBounds(uint256 index);
    /// @notice The guardian may only nudge a rate by <= 2.5% of its current value per call.
    error Distributor_AdjustmentTooLarge(uint256 rate, uint256 maximum);
    /// @notice A downward adjustment step cannot exceed the rate it is subtracted from.
    error Distributor_DecreaseTooLarge(uint256 rate, uint256 currentRate);

    /* ========================================= EVENTS ========================================= */

    /// @notice Emitted when a new emissions recipient is registered.
    event RecipientAdded(uint256 indexed index, address indexed recipient, uint256 rate);
    /// @notice Emitted when a recipient is retired (its slot is zeroed, not removed).
    event RecipientRemoved(uint256 indexed index, address indexed recipient);
    /// @notice Emitted when a rate ramp is scheduled or cleared.
    event AdjustmentSet(uint256 indexed index, bool add, uint256 rate, uint256 target);
    /// @notice Emitted once per recipient per epoch.
    event Distributed(uint256 indexed index, address indexed recipient, uint256 amount);
    /// @notice Emitted when a ramp step moves a rate. `finished` is true when the target was hit.
    event RateAdjusted(uint256 indexed index, uint256 newRate, bool finished);

    /* ========================================= TYPES ========================================== */

    /// @param rate      per-epoch emission in millionths of `treasury.baseSupply()`
    /// @param recipient address receiving the minted HOODZ; address(0) once retired
    struct Info {
        uint256 rate;
        address recipient;
    }

    /// @param add    true to ramp the rate up, false to ramp it down
    /// @param rate   step size applied once per epoch; 0 disables the ramp
    /// @param target rate at which the ramp stops
    struct Adjust {
        bool add;
        uint256 rate;
        uint256 target;
    }

    /* ======================================== CONSTANTS ======================================= */

    /// @notice Denominator for reward rates: 1_000_000 == 100% of base supply per epoch.
    uint256 public constant RATE_DENOMINATOR = 1_000_000;

    /// @dev Guardian ramp ceiling: 25/1000 == 2.5% of the recipient's current rate.
    uint256 private constant GUARDIAN_LIMIT_NUMERATOR = 25;
    uint256 private constant GUARDIAN_LIMIT_DENOMINATOR = 1_000;

    /* ======================================== STORAGE ========================================= */

    /// @notice The Hoodz Treasury, which mints the emission.
    ITreasury public immutable treasury;
    /// @notice The HOODZ token being emitted (informational; the treasury does the minting).
    address public immutable HOODZ;
    /// @notice The only address allowed to call `distribute()`.
    address public immutable staking;

    /// @notice Registered emission recipients.
    Info[] public info;

    /// @notice Pending rate ramp per recipient index.
    mapping(uint256 => Adjust) public adjustments;

    /* ====================================== CONSTRUCTOR ======================================= */

    /**
     * @param _treasury  Hoodz Treasury address (must grant this contract the REWARDMANAGER right)
     * @param _hoodz      HOODZ token address
     * @param _staking   HoodzStaking address, the sole caller of `distribute()`
     * @param _authority HoodzAuthority holding the governor/guardian/policy/vault roles
     */
    constructor(address _treasury, address _hoodz, address _staking, address _authority)
        HoodzAccessControlled(IHoodzAuthority(_authority))
    {
        if (_treasury == address(0) || _hoodz == address(0) || _staking == address(0)) {
            revert Distributor_ZeroAddress();
        }
        treasury = ITreasury(_treasury);
        HOODZ = _hoodz;
        staking = _staking;
    }

    /* ======================================== MUTATIVE ======================================== */

    /**
     * @notice Mint the epoch's emission to every recipient, then advance their rate ramps.
     * @dev    Called by `HoodzStaking.rebase()` on every epoch rollover. Retired recipients
     *         carry rate 0 and are skipped, so the array is never compacted.
     */
    function distribute() external override {
        if (msg.sender != staking) revert Distributor_OnlyStaking(msg.sender);

        uint256 length = info.length;
        for (uint256 i; i < length; ++i) {
            Info memory recipientInfo = info[i];
            if (recipientInfo.rate == 0) continue;

            uint256 amount = nextRewardAt(recipientInfo.rate);
            if (amount != 0) treasury.payout(recipientInfo.recipient, amount);
            emit Distributed(i, recipientInfo.recipient, amount);

            _adjust(i);
        }
    }

    /* ========================================= ADMIN ========================================== */

    /**
     * @notice Register a new emission recipient.
     * @param _recipient  address to mint HOODZ to each epoch
     * @param _rewardRate per-epoch rate in millionths of base supply (5000 == 0.5%)
     */
    function addRecipient(address _recipient, uint256 _rewardRate) external onlyGovernor {
        if (_recipient == address(0)) revert Distributor_ZeroAddress();
        if (_rewardRate > RATE_DENOMINATOR) revert Distributor_RateExceedsDenominator(_rewardRate);

        info.push(Info({recipient: _recipient, rate: _rewardRate}));
        emit RecipientAdded(info.length - 1, _recipient, _rewardRate);
    }

    /**
     * @notice Retire a recipient by zeroing its slot. Callable by governor or guardian.
     * @param _index index into `info`
     */
    function removeRecipient(uint256 _index) external {
        _onlyGovernorOrGuardian();
        if (_index >= info.length) revert Distributor_IndexOutOfBounds(_index);

        address recipient = info[_index].recipient;
        if (recipient == address(0)) revert Distributor_RecipientDoesNotExist(_index);

        info[_index].recipient = address(0);
        info[_index].rate = 0;
        delete adjustments[_index];

        emit RecipientRemoved(_index, recipient);
    }

    /**
     * @notice Schedule a per-epoch ramp of a recipient's reward rate toward a target.
     * @dev    Governor may set any step; the guardian is limited to 2.5% of the current rate.
     *         A zero `_rate` clears the ramp.
     * @param _index  index into `info`
     * @param _add    true to ramp up, false to ramp down
     * @param _rate   step size applied once per epoch
     * @param _target rate at which the ramp stops
     */
    function setAdjustment(uint256 _index, bool _add, uint256 _rate, uint256 _target) external {
        _onlyGovernorOrGuardian();
        if (_index >= info.length) revert Distributor_IndexOutOfBounds(_index);

        uint256 currentRate = info[_index].rate;
        if (info[_index].recipient == address(0)) revert Distributor_RecipientDoesNotExist(_index);
        if (_target > RATE_DENOMINATOR) revert Distributor_RateExceedsDenominator(_target);

        if (msg.sender == authority.guardian() && msg.sender != authority.governor()) {
            uint256 maximum = (currentRate * GUARDIAN_LIMIT_NUMERATOR) / GUARDIAN_LIMIT_DENOMINATOR;
            if (_rate > maximum) revert Distributor_AdjustmentTooLarge(_rate, maximum);
        }

        if (!_add && _rate > currentRate) revert Distributor_DecreaseTooLarge(_rate, currentRate);

        adjustments[_index] = Adjust({add: _add, rate: _rate, target: _target});
        emit AdjustmentSet(_index, _add, _rate, _target);
    }

    /* ========================================== VIEWS ========================================= */

    /**
     * @notice HOODZ that would be minted this epoch for a given rate.
     * @param _rate per-epoch rate in millionths of base supply
     * @return the emission in HOODZ
     */
    function nextRewardAt(uint256 _rate) public view returns (uint256) {
        return (treasury.baseSupply() * _rate) / RATE_DENOMINATOR;
    }

    /**
     * @notice HOODZ that would be minted this epoch for a given recipient.
     * @dev    Sums every slot pointing at `_recipient`, so duplicates are handled.
     * @param _recipient the address to price
     * @return reward the emission in HOODZ
     */
    function nextRewardFor(address _recipient) external view override returns (uint256 reward) {
        uint256 length = info.length;
        for (uint256 i; i < length; ++i) {
            if (info[i].recipient == _recipient) {
                reward += nextRewardAt(info[i].rate);
            }
        }
    }

    /**
     * @notice Number of recipient slots ever registered, retired ones included.
     * @return the length of the `info` array
     */
    function recipientCount() external view returns (uint256) {
        return info.length;
    }

    /* ======================================== INTERNAL ======================================== */

    /// @dev Walk a recipient's rate one step toward its target, clearing the ramp on arrival.
    function _adjust(uint256 _index) internal {
        Adjust memory adjustment = adjustments[_index];
        if (adjustment.rate == 0) return;

        uint256 rate = info[_index].rate;

        if (adjustment.add) {
            rate += adjustment.rate;
            if (rate >= adjustment.target) {
                rate = adjustment.target;
                delete adjustments[_index];
            }
        } else {
            rate = rate > adjustment.rate ? rate - adjustment.rate : 0;
            if (rate <= adjustment.target) {
                rate = adjustment.target;
                delete adjustments[_index];
            }
        }

        info[_index].rate = rate;
        emit RateAdjusted(_index, rate, adjustments[_index].rate == 0);
    }

    /// @dev Governor or guardian may steer emissions; anyone else is rejected.
    function _onlyGovernorOrGuardian() internal view {
        if (msg.sender != authority.governor() && msg.sender != authority.guardian()) {
            revert Distributor_NotGovernorOrGuardian(msg.sender);
        }
    }
}
