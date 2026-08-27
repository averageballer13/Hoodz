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

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IsHOODZ} from "./interfaces/IsHOODZ.sol";
import {IgHOODZ} from "./interfaces/IgHOODZ.sol";
import {IDistributor} from "./interfaces/IDistributor.sol";
import {IHoodzAuthority} from "./interfaces/IHoodzAuthority.sol";
import {HoodzAccessControlled} from "./types/HoodzAccessControlled.sol";

/**
 * @title  HoodzStaking
 * @notice The Hoodz staking + rebase engine. A faithful re-implementation of
 *         `OlympusStaking`, rebranded for Hoodz on Robinhood Chain (chainId 4663).
 *
 *         HOODZ is deposited here and represented by either:
 *           - sHOODZ, a rebasing 1:1 claim whose balance grows every epoch, or
 *           - gHOODZ, a non-rebasing "index wrapped" claim whose balance is constant
 *             while its HOODZ value grows with `index()`.
 *
 *         Every epoch (`epoch.length` seconds) `rebase()` pays `epoch.distribute` HOODZ out
 *         to sHOODZ holders, pulls the next epoch's emission from the `Distributor`, and
 *         recomputes `epoch.distribute` as the surplus HOODZ sitting in this contract.
 *
 * @dev    UNAUDITED. Do not use in production without a full audit.
 */
contract HoodzStaking is HoodzAccessControlled {
    using SafeERC20 for IERC20;

    /* ========================================= ERRORS ========================================= */

    /// @notice A constructor argument or a recipient was the zero address.
    error HoodzStaking_ZeroAddress();
    /// @notice An amount argument was zero.
    error HoodzStaking_ZeroAmount();
    /// @notice The epoch length may not be zero (it would make `rebase()` a no-op loop).
    error HoodzStaking_ZeroEpochLength();
    /// @notice Third-party deposits into `account`'s warmup are disabled until it calls `toggleLock()`.
    error HoodzStaking_DepositsLocked(address account);
    /// @notice Third-party claims for `account` are disabled until it calls `toggleLock()`.
    error HoodzStaking_ClaimsLocked(address account);
    /// @notice `account` has nothing sitting in warmup to forfeit.
    error HoodzStaking_NothingInWarmup(address account);
    /// @notice This contract does not hold enough HOODZ to honour the unstake.
    error HoodzStaking_InsufficientBalance(uint256 requested, uint256 available);

    /* ========================================= EVENTS ========================================= */

    /// @notice Emitted when the governor points staking at a new emissions distributor.
    event DistributorSet(address indexed distributor);
    /// @notice Emitted when the governor changes the warmup length (in epochs).
    event WarmupSet(uint256 warmup);
    /// @notice Emitted on every deposit. `claimed` is false when the deposit went to warmup.
    event Stake(address indexed caller, address indexed to, uint256 amount, bool rebasing, bool claimed);
    /// @notice Emitted when a matured warmup position is released to its owner.
    event Claimed(address indexed to, uint256 amount, bool rebasing);
    /// @notice Emitted when a warmup position is abandoned and its principal returned.
    event Forfeit(address indexed account, uint256 amount);
    /// @notice Emitted when an account flips third-party deposit/claim permission.
    event LockToggled(address indexed account, bool lock);
    /// @notice Emitted on every withdrawal of HOODZ.
    event Unstake(address indexed caller, address indexed to, uint256 amount, bool rebasing);
    /// @notice Emitted when sHOODZ is wrapped into gHOODZ.
    event Wrap(address indexed to, uint256 sAmount, uint256 gAmount);
    /// @notice Emitted when gHOODZ is unwrapped into sHOODZ.
    event Unwrap(address indexed to, uint256 gAmount, uint256 sAmount);
    /// @notice Emitted once per epoch rollover.
    event Rebase(uint256 indexed epochNumber, uint256 distributed, uint256 nextDistribute, uint256 index);

    /* ========================================= TYPES ========================================== */

    /// @param length     epoch duration in seconds
    /// @param number     epochs elapsed since inception
    /// @param end        unix timestamp at which the current epoch may be rolled
    /// @param distribute HOODZ paid to sHOODZ holders at the next rollover
    struct Epoch {
        uint256 length;
        uint256 number;
        uint256 end;
        uint256 distribute;
    }

    /// @param deposit HOODZ principal, returned verbatim by `forfeit()`
    /// @param gons    sHOODZ gons held on behalf of the depositor while in warmup
    /// @param expiry  epoch number at which the position becomes claimable
    /// @param lock    when true, third parties may deposit/claim for this account
    struct Claim {
        uint256 deposit;
        uint256 gons;
        uint256 expiry;
        bool lock;
    }

    /* ======================================== STORAGE ========================================= */

    /// @notice The HOODZ token being staked.
    IERC20 public immutable HOODZ;
    /// @notice The rebasing staked token.
    IsHOODZ public immutable sHOODZ;
    /// @notice The index-wrapped, non-rebasing staked token.
    IgHOODZ public immutable gHOODZ;

    /// @notice The live epoch.
    Epoch public epoch;

    /// @notice Mints the per-epoch emission into this contract. May be unset (address(0)).
    IDistributor public distributor;

    /// @notice Warmup position per account.
    mapping(address => Claim) public warmupInfo;

    /// @notice Warmup length, denominated in epochs.
    uint256 public warmupPeriod;

    /// @dev Sum of all gons currently held in warmup.
    uint256 private gonsInWarmup;

    /* ====================================== CONSTRUCTOR ======================================= */

    /**
     * @param _hoodz            HOODZ token address
     * @param _sHOODZ           sHOODZ token address
     * @param _gHOODZ           gHOODZ token address
     * @param _epochLength     epoch duration in seconds
     * @param _firstEpochNumber epoch number to start counting from
     * @param _firstEpochTime  unix timestamp of the first epoch rollover
     * @param _authority       HoodzAuthority holding the governor/guardian/policy/vault roles
     */
    constructor(
        address _hoodz,
        address _sHOODZ,
        address _gHOODZ,
        uint256 _epochLength,
        uint256 _firstEpochNumber,
        uint256 _firstEpochTime,
        address _authority
    ) HoodzAccessControlled(IHoodzAuthority(_authority)) {
        if (_hoodz == address(0) || _sHOODZ == address(0) || _gHOODZ == address(0)) revert HoodzStaking_ZeroAddress();
        if (_epochLength == 0) revert HoodzStaking_ZeroEpochLength();

        HOODZ = IERC20(_hoodz);
        sHOODZ = IsHOODZ(_sHOODZ);
        gHOODZ = IgHOODZ(_gHOODZ);

        epoch = Epoch({length: _epochLength, number: _firstEpochNumber, end: _firstEpochTime, distribute: 0});
    }

    /* ======================================== MUTATIVE ======================================== */

    /**
     * @notice Deposit HOODZ and receive sHOODZ or gHOODZ, immediately or after the warmup.
     * @dev    Triggers `rebase()` first so the epoch is always current before accounting.
     * @param _to       recipient of the staked position
     * @param _amount   HOODZ to deposit
     * @param _rebasing true to receive sHOODZ, false to receive gHOODZ
     * @param _claim    true to skip warmup when `warmupPeriod == 0`
     * @return The amount credited: HOODZ/sHOODZ terms when `_rebasing`, gHOODZ terms otherwise,
     *         or the HOODZ principal parked in warmup.
     */
    function stake(address _to, uint256 _amount, bool _rebasing, bool _claim) external returns (uint256) {
        if (_to == address(0)) revert HoodzStaking_ZeroAddress();
        if (_amount == 0) revert HoodzStaking_ZeroAmount();

        rebase();

        HOODZ.safeTransferFrom(msg.sender, address(this), _amount);

        if (_claim && warmupPeriod == 0) {
            emit Stake(msg.sender, _to, _amount, _rebasing, true);
            return _send(_to, _amount, _rebasing);
        }

        Claim memory info = warmupInfo[_to];
        if (!info.lock && _to != msg.sender) revert HoodzStaking_DepositsLocked(_to);

        uint256 gons = sHOODZ.gonsForBalance(_amount);
        warmupInfo[_to] = Claim({
            deposit: info.deposit + _amount,
            gons: info.gons + gons,
            expiry: epoch.number + warmupPeriod,
            lock: info.lock
        });
        gonsInWarmup += gons;

        emit Stake(msg.sender, _to, _amount, _rebasing, false);
        return _amount;
    }

    /**
     * @notice Release a matured warmup position.
     * @dev    Returns 0 (rather than reverting) when the position is empty or still warming,
     *         so it can be called opportunistically.
     * @param _to       account whose warmup is being claimed
     * @param _rebasing true to receive sHOODZ, false to receive gHOODZ
     * @return The amount sent, in sHOODZ terms when `_rebasing` and gHOODZ terms otherwise.
     */
    function claim(address _to, bool _rebasing) public returns (uint256) {
        Claim memory info = warmupInfo[_to];
        if (!info.lock && _to != msg.sender) revert HoodzStaking_ClaimsLocked(_to);

        if (info.expiry != 0 && epoch.number >= info.expiry) {
            delete warmupInfo[_to];
            gonsInWarmup -= info.gons;

            uint256 amount = sHOODZ.balanceForGons(info.gons);
            emit Claimed(_to, amount, _rebasing);
            return _send(_to, amount, _rebasing);
        }
        return 0;
    }

    /**
     * @notice Abandon a warmup position and take the HOODZ principal back.
     * @dev    Rebases accrued while in warmup are forfeited to the contract, as in Olympus.
     * @return The HOODZ principal returned to the caller.
     */
    function forfeit() external returns (uint256) {
        Claim memory info = warmupInfo[msg.sender];
        if (info.deposit == 0 && info.gons == 0) revert HoodzStaking_NothingInWarmup(msg.sender);

        delete warmupInfo[msg.sender];
        gonsInWarmup -= info.gons;

        emit Forfeit(msg.sender, info.deposit);
        HOODZ.safeTransfer(msg.sender, info.deposit);

        return info.deposit;
    }

    /**
     * @notice Flip whether third parties may deposit into / claim from the caller's warmup.
     * @dev    Defaults to false (locked), which is why `stake`/`claim` require `_to == msg.sender`.
     */
    function toggleLock() external {
        bool lock = !warmupInfo[msg.sender].lock;
        warmupInfo[msg.sender].lock = lock;
        emit LockToggled(msg.sender, lock);
    }

    /**
     * @notice Redeem sHOODZ or gHOODZ for HOODZ.
     * @dev    Checks-effects-interactions: the staked token is pulled in / burned and the HOODZ
     *         balance is verified BEFORE any HOODZ leaves the contract.
     * @param _to       recipient of the HOODZ
     * @param _amount   sHOODZ when `_rebasing`, gHOODZ otherwise
     * @param _trigger  true to roll the epoch before unstaking
     * @param _rebasing true when `_amount` is denominated in sHOODZ
     * @return amount_ HOODZ sent to `_to`
     */
    function unstake(address _to, uint256 _amount, bool _trigger, bool _rebasing)
        external
        returns (uint256 amount_)
    {
        if (_to == address(0)) revert HoodzStaking_ZeroAddress();
        if (_amount == 0) revert HoodzStaking_ZeroAmount();

        if (_trigger) rebase();

        if (_rebasing) {
            // sHOODZ returns to the staking contract, removing it from circulating supply.
            IERC20(address(sHOODZ)).safeTransferFrom(msg.sender, address(this), _amount);
            amount_ = _amount;
        } else {
            // gHOODZ is burned; its HOODZ value is derived from the current index.
            gHOODZ.burn(msg.sender, _amount);
            amount_ = gHOODZ.balanceFrom(_amount);
        }

        uint256 balance = contractBalance();
        if (amount_ > balance) revert HoodzStaking_InsufficientBalance(amount_, balance);

        emit Unstake(msg.sender, _to, amount_, _rebasing);
        HOODZ.safeTransfer(_to, amount_);
    }

    /**
     * @notice Convert sHOODZ into gHOODZ at the current index.
     * @param _to     recipient of the gHOODZ
     * @param _amount sHOODZ to wrap
     * @return gBalance_ gHOODZ minted
     */
    function wrap(address _to, uint256 _amount) external returns (uint256 gBalance_) {
        if (_to == address(0)) revert HoodzStaking_ZeroAddress();
        if (_amount == 0) revert HoodzStaking_ZeroAmount();

        IERC20(address(sHOODZ)).safeTransferFrom(msg.sender, address(this), _amount);
        gBalance_ = gHOODZ.balanceTo(_amount);

        emit Wrap(_to, _amount, gBalance_);
        gHOODZ.mint(_to, gBalance_);
    }

    /**
     * @notice Convert gHOODZ back into sHOODZ at the current index.
     * @dev    The gHOODZ is burned before the sHOODZ is released (checks-effects-interactions).
     * @param _to     recipient of the sHOODZ
     * @param _amount gHOODZ to unwrap
     * @return sBalance_ sHOODZ sent
     */
    function unwrap(address _to, uint256 _amount) external returns (uint256 sBalance_) {
        if (_to == address(0)) revert HoodzStaking_ZeroAddress();
        if (_amount == 0) revert HoodzStaking_ZeroAmount();

        gHOODZ.burn(msg.sender, _amount);
        sBalance_ = gHOODZ.balanceFrom(_amount);

        emit Unwrap(_to, _amount, sBalance_);
        IERC20(address(sHOODZ)).safeTransfer(_to, sBalance_);
    }

    /**
     * @notice Roll the epoch if it has ended: pay out sHOODZ holders, pull the next emission,
     *         and recompute the surplus to be distributed next epoch.
     * @dev    A no-op before `epoch.end`. Catches up one epoch per call.
     */
    function rebase() public {
        if (epoch.end > block.timestamp) return;

        uint256 number = epoch.number;
        uint256 distributed = epoch.distribute;

        sHOODZ.rebase(distributed, number);

        epoch.end += epoch.length;
        epoch.number = number + 1;

        if (address(distributor) != address(0)) {
            distributor.distribute();
        }

        uint256 balance = contractBalance();
        uint256 staked = sHOODZ.circulatingSupply();
        uint256 next = balance <= staked ? 0 : balance - staked;
        epoch.distribute = next;

        emit Rebase(number, distributed, next, sHOODZ.index());
    }

    /* ========================================= ADMIN ========================================== */

    /**
     * @notice Point staking at a new emissions distributor. Pass address(0) to halt emissions.
     * @param _distributor the new IDistributor
     */
    function setDistributor(address _distributor) external onlyGovernor {
        distributor = IDistributor(_distributor);
        emit DistributorSet(_distributor);
    }

    /**
     * @notice Set the warmup length, denominated in epochs.
     * @param _warmupPeriod number of epochs a new deposit must wait before it can be claimed
     */
    function setWarmupLength(uint256 _warmupPeriod) external onlyGovernor {
        warmupPeriod = _warmupPeriod;
        emit WarmupSet(_warmupPeriod);
    }

    /* ========================================== VIEWS ========================================= */

    /**
     * @notice HOODZ held by this contract, i.e. the backing for sHOODZ + gHOODZ + warmup.
     * @return HOODZ balance of the staking contract
     */
    function contractBalance() public view returns (uint256) {
        return HOODZ.balanceOf(address(this));
    }

    /**
     * @notice sHOODZ currently sitting in warmup, in sHOODZ terms.
     * @return the sHOODZ value of all warmup gons
     */
    function supplyInWarmup() public view returns (uint256) {
        return sHOODZ.balanceForGons(gonsInWarmup);
    }

    /**
     * @notice The sHOODZ rebase index (HOODZ per gHOODZ).
     * @return the current index
     */
    function index() public view returns (uint256) {
        return sHOODZ.index();
    }

    /**
     * @notice Seconds remaining until `rebase()` becomes callable.
     * @return 0 once the epoch is over, otherwise `epoch.end - block.timestamp`
     */
    function secondsToNextEpoch() external view returns (uint256) {
        return epoch.end > block.timestamp ? epoch.end - block.timestamp : 0;
    }

    /* ======================================== INTERNAL ======================================== */

    /**
     * @dev Send a staked position out, either as sHOODZ (1:1) or as freshly minted gHOODZ.
     *      When gHOODZ is minted the sHOODZ stays here as its backing.
     */
    function _send(address _to, uint256 _amount, bool _rebasing) internal returns (uint256) {
        if (_rebasing) {
            IERC20(address(sHOODZ)).safeTransfer(_to, _amount);
            return _amount;
        }
        uint256 gBalance = gHOODZ.balanceTo(_amount);
        gHOODZ.mint(_to, gBalance);
        return gBalance;
    }
}
