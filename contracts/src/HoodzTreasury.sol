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
        X      https://x.com/hoodzdao
        Code   https://github.com/averageballer13/Hoodz

        UNAUDITED. This code has never been audited. Read it before you
        trust it with anything you would miss.
*/

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IHOODZ} from "./interfaces/IHOODZ.sol";
import {IsHOODZ} from "./interfaces/IsHOODZ.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";
import {IBondingCalculator} from "./interfaces/IBondingCalculator.sol";
import {IHoodzAuthority} from "./interfaces/IHoodzAuthority.sol";
import {HoodzAccessControlled} from "./types/HoodzAccessControlled.sol";

/// @title IsHOODZDebt
/// @notice The debt-accounting surface of sHOODZ, used to collateralise treasury debt with
///         a debtor's staked position.
/// @dev Declared here because the shared {IsHOODZ} interface only covers the rebasing surface.
///      `HoodzStaking`'s sHOODZ implements these two members (mirroring `sOHM`).
interface IsHOODZDebt {
    /// @notice Increase or decrease the recorded debt of `debtor`, locking their sHOODZ.
    /// @param amount Debt delta, in HOODZ terms.
    /// @param debtor Account whose debt balance changes.
    /// @param add True to incur debt, false to repay it.
    function changeDebt(uint256 amount, address debtor, bool add) external;

    /// @notice Outstanding debt recorded against an account.
    /// @param debtor Account to query.
    /// @return The debt balance in HOODZ terms.
    function debtBalances(address debtor) external view returns (uint256);
}

/// @notice Thrown when a zero address is supplied where a contract is required.
error HoodzTreasury_ZeroAddress();
/// @notice Thrown when a token is not registered for the action attempted.
error HoodzTreasury_NotAccepted();
/// @notice Thrown when the caller lacks the permission the action requires.
error HoodzTreasury_NotApproved();
/// @notice Thrown when a token is neither a reserve nor a liquidity token.
error HoodzTreasury_InvalidToken();
/// @notice Thrown when an action would consume more than the treasury's excess reserves.
error HoodzTreasury_InsufficientReserves();
/// @notice The treasury does not hold enough HOODZ to make this payout. Fixed supply: it can only
///         ever distribute what it already owns.
error HoodzTreasury_InsufficientInventory(uint256 requested, uint256 held);
/// @notice Thrown when a debtor's position would exceed their configured debt limit.
error HoodzTreasury_ExceedsDebtLimit();
/// @notice Thrown when sHOODZ has not been registered yet but debt accounting was requested.
error HoodzTreasury_SHoodzNotSet();
/// @notice Thrown when a timelocked-only path is used while the timelock is disabled.
error HoodzTreasury_TimelockDisabled();
/// @notice Thrown when an instant path is used while the timelock is enabled.
error HoodzTreasury_TimelockEnabled();
/// @notice Thrown when {enableTimelock} is called and the timelock is already on.
error HoodzTreasury_TimelockAlreadyEnabled();
/// @notice Thrown when {disableTimelock} is called and the timelock is already off.
error HoodzTreasury_TimelockAlreadyDisabled();
/// @notice Thrown when a queued action is executed before its block height is reached.
error HoodzTreasury_TimelockNotComplete();
/// @notice Thrown when a nullified queue entry is executed.
error HoodzTreasury_ActionNullified();
/// @notice Thrown when a queue entry is executed twice.
error HoodzTreasury_AlreadyExecuted();
/// @notice Thrown when {initialize} is called more than once.
error HoodzTreasury_AlreadyInitialized();
/// @notice Thrown when a guardian-or-governor gated function is called by neither.
error HoodzTreasury_NotGovernorOrGuardian();
/// @notice Thrown when a liquidity token is registered without a bonding calculator.
error HoodzTreasury_MissingCalculator();

/// @title Hoodz Treasury
/// @author Hoodz
/// @notice Balance sheet of Hoodz. It custodies every reserve and liquidity asset, mints
///         HOODZ against incoming value, and is the only contract permitted to expand supply.
/// @dev Faithful port of `OlympusTreasury` to Solidity 0.8 / OpenZeppelin v5 with custom errors.
///      Access is delegated to {HoodzAuthority} via {HoodzAccessControlled}; the treasury itself is
///      the `vault` role for HOODZ, so `HOODZ.mint` only ever succeeds from here.
///
///      Every privileged address is registered under a {STATUS} in a two-mapping registry:
///      `permissions` is the authoritative flag, `registry` is the enumerable list used by
///      {auditReserves}. Once {initialize} turns the timelock on, new permissions can only be
///      added through {queueTimelock} + {execute}, separated by `blocksNeededForQueue` blocks
///      (doubled for the manager roles that can move assets out of the treasury).
contract HoodzTreasury is HoodzAccessControlled, ITreasury {
    using SafeERC20 for IERC20;

    // ========= EVENTS ========= //

    /// @notice Emitted when an asset is deposited and HOODZ is minted against it.
    event Deposit(address indexed token, uint256 amount, uint256 value);
    /// @notice Emitted when HOODZ is burned to redeem a reserve asset.
    event Withdrawal(address indexed token, uint256 amount, uint256 value);
    /// @notice Emitted when a debtor draws against their staked collateral.
    event CreateDebt(address indexed debtor, address indexed token, uint256 amount, uint256 value);
    /// @notice Emitted when a debtor repays, in reserves or in HOODZ.
    event RepayDebt(address indexed debtor, address indexed token, uint256 amount, uint256 value);
    /// @notice Emitted when a manager withdraws assets to deploy them.
    event Managed(address indexed token, uint256 amount);
    /// @notice Emitted when reserves are recomputed from live balances.
    event ReservesAudited(uint256 indexed totalReserves);
    /// @notice Emitted when a reward manager mints HOODZ out of excess reserves.
    event PaidOut(address indexed caller, address indexed recipient, uint256 amount);
    /// @notice Emitted when a permission change enters the timelock queue.
    event PermissionQueued(STATUS indexed status, address queued);
    /// @notice Emitted when a permission is granted or revoked.
    event Permissioned(address addr, STATUS indexed status, bool result);
    /// @notice Emitted when a queued permission change is cancelled.
    event QueueNullified(uint256 indexed index);
    /// @notice Emitted when a debtor's ceiling is set.
    event DebtLimitSet(address indexed debtor, uint256 limit);
    /// @notice Emitted when the sHOODZ contract used for debt collateral is set.
    event SHoodzSet(address indexed sHoodz);
    /// @notice Emitted when the on-chain governance countdown for toggling the timelock starts.
    event TimelockOrdered(uint256 indexed timelockEndBlock);
    /// @notice Emitted when the timelock requirement is switched on or off.
    event TimelockToggled(bool enabled);

    // ========= TYPES ========= //

    /// @notice Permission classes the treasury recognises.
    /// @dev RESERVEDEPOSITOR/SPENDER/TOKEN/MANAGER govern stable reserves; the LIQUIDITY*
    ///      variants govern LP positions; RESERVEDEBTOR and HOODZDEBTOR govern sHOODZ-collateralised
    ///      borrowing; REWARDMANAGER may mint from excess reserves; SHOODZ registers the staked
    ///      token used as debt collateral.
    enum STATUS {
        RESERVEDEPOSITOR,
        RESERVESPENDER,
        RESERVETOKEN,
        RESERVEMANAGER,
        LIQUIDITYDEPOSITOR,
        LIQUIDITYTOKEN,
        LIQUIDITYMANAGER,
        RESERVEDEBTOR,
        REWARDMANAGER,
        SHOODZ,
        HOODZDEBTOR
    }

    /// @notice A pending permission change waiting out the timelock.
    struct Queue {
        STATUS managing;
        address toPermit;
        address calculator;
        uint256 timeToImplement;
        bool nullify;
        bool executed;
    }

    // ========= CONSTANTS ========= //

    /// @notice Decimals of HOODZ. Fixed at 9 for Olympus parity; every value the treasury books
    ///         (`totalReserves`, `totalDebt`, `tokenValue`) is denominated in these units.
    uint256 internal constant HOODZ_DECIMALS = 9;

    /// @dev Multiplier applied to `blocksNeededForQueue` for roles that can move assets out.
    uint256 internal constant MANAGER_TIMELOCK_MULTIPLIER = 2;

    /// @dev Multiplier applied to `blocksNeededForQueue` for toggling the timelock itself.
    uint256 internal constant GOVERNANCE_TIMELOCK_MULTIPLIER = 7;

    // ========= STATE ========= //

    /// @notice The HOODZ token. The treasury holds the `vault` role and is its only minter.
    IHOODZ public immutable HOODZ;

    /// @notice Blocks a queued permission change must wait before it can be executed.
    uint256 public immutable blocksNeededForQueue;

    /// @notice Staked HOODZ, used to collateralise treasury debt.
    IsHOODZ public sHOODZ;

    /// @notice Enumerable list of addresses ever registered under each status.
    mapping(STATUS => address[]) public registry;

    /// @notice Authoritative permission flags.
    mapping(STATUS => mapping(address => bool)) public permissions;

    /// @notice Bonding calculator used to value each registered liquidity token.
    mapping(address => address) public bondCalculator;

    /// @notice Maximum debt, in HOODZ terms, each debtor may carry.
    mapping(address => uint256) public debtLimit;

    /// @notice Total booked value of treasury assets, in HOODZ terms.
    uint256 public totalReserves;

    /// @notice Total outstanding debt, in HOODZ terms.
    uint256 public totalDebt;

    /// @notice Portion of `totalDebt` that was drawn as freshly minted HOODZ.
    uint256 public hoodzDebt;

    /// @notice Every permission change ever queued, executed or not.
    Queue[] public permissionQueue;

    /// @notice Whether permission changes must go through the queue.
    bool public timelockEnabled;

    /// @notice Whether {initialize} has run.
    bool public initialized;

    /// @notice Block height after which the timelock setting itself may be toggled.
    uint256 public onChainGovernanceTimelock;

    // ========= CONSTRUCTOR ========= //

    /// @param _hoodz Address of the HOODZ token.
    /// @param _timelock Blocks a queued permission change must wait.
    /// @param _authority Address of {HoodzAuthority}.
    constructor(address _hoodz, uint256 _timelock, address _authority)
        HoodzAccessControlled(IHoodzAuthority(_authority))
    {
        if (_hoodz == address(0)) revert HoodzTreasury_ZeroAddress();
        HOODZ = IHOODZ(_hoodz);

        blocksNeededForQueue = _timelock;
        timelockEnabled = false;
        initialized = false;
    }

    // ========= BALANCE SHEET ========= //

    /// @notice Deposit an accepted asset and mint HOODZ against its value.
    /// @dev Caller must hold the depositor permission matching the token class. `_profit` is the
    ///      slice of the deposited value retained by the treasury rather than paid to the
    ///      depositor — this is what funds staking rewards.
    /// @param _amount Amount of `_token` to pull from the caller.
    /// @param _token Asset being deposited.
    /// @param _profit Value withheld from the caller, in HOODZ terms.
    /// @return send_ HOODZ minted to the caller (`value - profit`).
    function deposit(uint256 _amount, address _token, uint256 _profit)
        external
        override
        returns (uint256 send_)
    {
        if (permissions[STATUS.RESERVETOKEN][_token]) {
            if (!permissions[STATUS.RESERVEDEPOSITOR][msg.sender]) revert HoodzTreasury_NotApproved();
        } else if (permissions[STATUS.LIQUIDITYTOKEN][_token]) {
            if (!permissions[STATUS.LIQUIDITYDEPOSITOR][msg.sender]) revert HoodzTreasury_NotApproved();
        } else {
            revert HoodzTreasury_InvalidToken();
        }

        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        uint256 value = tokenValue(_token, _amount);

        // Pay the depositor out of treasury inventory; the withheld profit stays as excess
        // reserves. Under the fixed-supply model this is a transfer, not a mint: if the treasury
        // does not hold enough HOODZ the deposit reverts rather than silently under-paying.
        send_ = value - _profit;
        _payFromInventory(msg.sender, send_);

        totalReserves += value;

        emit Deposit(_token, _amount, value);
    }

    /// @notice Burn HOODZ to redeem a reserve asset one-for-one on value.
    /// @dev Only reserve tokens are redeemable; liquidity positions are not.
    /// @param _amount Amount of `_token` to send to the caller.
    /// @param _token Reserve asset to redeem.
    function withdraw(uint256 _amount, address _token) external override {
        if (!permissions[STATUS.RESERVETOKEN][_token]) revert HoodzTreasury_NotAccepted();
        if (!permissions[STATUS.RESERVESPENDER][msg.sender]) revert HoodzTreasury_NotApproved();

        uint256 value = tokenValue(_token, _amount);
        // Fixed supply: the HOODZ returns to inventory instead of being destroyed, which is
        // strictly better - it can be paid out again without anyone having to buy it back.
        IERC20(address(HOODZ)).safeTransferFrom(msg.sender, address(this), value);

        totalReserves -= value;

        IERC20(_token).safeTransfer(msg.sender, _amount);

        emit Withdrawal(_token, _amount, value);
    }

    /// @notice Withdraw assets to deploy them, without burning HOODZ.
    /// @dev Only the excess reserves — value above what is needed to back circulating HOODZ —
    ///      may be managed. Unregistered tokens (airdrops, stray transfers) are not booked as
    ///      reserves and so are swept without touching `totalReserves`.
    /// @param _token Asset to withdraw.
    /// @param _amount Amount to withdraw.
    function manage(address _token, uint256 _amount) external override {
        if (permissions[STATUS.LIQUIDITYTOKEN][_token]) {
            if (!permissions[STATUS.LIQUIDITYMANAGER][msg.sender]) revert HoodzTreasury_NotApproved();
        } else {
            if (!permissions[STATUS.RESERVEMANAGER][msg.sender]) revert HoodzTreasury_NotApproved();
        }

        if (permissions[STATUS.RESERVETOKEN][_token] || permissions[STATUS.LIQUIDITYTOKEN][_token]) {
            uint256 value = tokenValue(_token, _amount);
            if (value > excessReserves()) revert HoodzTreasury_InsufficientReserves();
            totalReserves -= value;
        }

        IERC20(_token).safeTransfer(msg.sender, _amount);

        emit Managed(_token, _amount);
    }

    /// @notice Pay HOODZ out of treasury inventory, backed by excess reserves.
    /// @dev Replaces Olympus's `mint`. HOODZ has a fixed supply set by PONS, so the protocol can
    ///      only ever distribute what it already owns. The `excessReserves` ceiling is kept and
    ///      still means the same thing: releasing treasury-held HOODZ raises the circulating supply
    ///      against unchanged reserves, so it dilutes backing per token exactly as a mint would.
    ///      The distributor and the bond depository hold this permission.
    /// @param _recipient Address to receive the HOODZ.
    /// @param _amount Amount of HOODZ to send, 9 decimals.
    function payout(address _recipient, uint256 _amount) external override {
        if (!permissions[STATUS.REWARDMANAGER][msg.sender]) revert HoodzTreasury_NotApproved();
        if (_amount > excessReserves()) revert HoodzTreasury_InsufficientReserves();

        _payFromInventory(_recipient, _amount);

        emit PaidOut(msg.sender, _recipient, _amount);
    }

    /// @notice HOODZ held by the treasury and available to pay out.
    /// @return The treasury's HOODZ balance, 9 decimals.
    function inventory() public view override returns (uint256) {
        return HOODZ.balanceOf(address(this));
    }

    /// @dev Single choke point for every HOODZ payout, so the inventory check can never be skipped.
    function _payFromInventory(address _recipient, uint256 _amount) internal {
        if (_amount == 0) return;
        uint256 held = HOODZ.balanceOf(address(this));
        if (_amount > held) revert HoodzTreasury_InsufficientInventory(_amount, held);
        IERC20(address(HOODZ)).safeTransfer(_recipient, _amount);
    }

    // ========= DEBT ========= //

    /// @notice Borrow against a staked (sHOODZ) position.
    /// @dev Borrowing HOODZ mints it and books it under `hoodzDebt`; borrowing a reserve asset
    ///      sends the asset out and reduces `totalReserves`. Either way the debt is recorded on
    ///      sHOODZ, which locks the debtor's stake, and is checked against their {debtLimit}.
    /// @param _amount Amount of `_token` to borrow.
    /// @param _token Asset to borrow — HOODZ itself, or a registered reserve token.
    function incurDebt(uint256 _amount, address _token) external {
        if (address(sHOODZ) == address(0)) revert HoodzTreasury_SHoodzNotSet();

        uint256 value;
        if (_token == address(HOODZ)) {
            if (!permissions[STATUS.HOODZDEBTOR][msg.sender]) revert HoodzTreasury_NotApproved();
            value = _amount;
        } else {
            if (!permissions[STATUS.RESERVEDEBTOR][msg.sender]) revert HoodzTreasury_NotApproved();
            if (!permissions[STATUS.RESERVETOKEN][_token]) revert HoodzTreasury_NotAccepted();
            value = tokenValue(_token, _amount);
        }
        if (value == 0) revert HoodzTreasury_InvalidToken();

        IsHOODZDebt(address(sHOODZ)).changeDebt(value, msg.sender, true);
        if (IsHOODZDebt(address(sHOODZ)).debtBalances(msg.sender) > debtLimit[msg.sender]) {
            revert HoodzTreasury_ExceedsDebtLimit();
        }
        totalDebt += value;

        if (_token == address(HOODZ)) {
            _payFromInventory(msg.sender, value);
            hoodzDebt += value;
        } else {
            totalReserves -= value;
            IERC20(_token).safeTransfer(msg.sender, _amount);
        }

        emit CreateDebt(msg.sender, _token, _amount, value);
    }

    /// @notice Repay debt by returning a reserve asset.
    /// @param _amount Amount of `_token` to repay.
    /// @param _token Reserve asset used to repay.
    function repayDebtWithReserve(uint256 _amount, address _token) external {
        if (address(sHOODZ) == address(0)) revert HoodzTreasury_SHoodzNotSet();
        if (!permissions[STATUS.RESERVEDEBTOR][msg.sender]) revert HoodzTreasury_NotApproved();
        if (!permissions[STATUS.RESERVETOKEN][_token]) revert HoodzTreasury_NotAccepted();

        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        uint256 value = tokenValue(_token, _amount);
        IsHOODZDebt(address(sHOODZ)).changeDebt(value, msg.sender, false);
        totalDebt -= value;
        totalReserves += value;

        emit RepayDebt(msg.sender, _token, _amount, value);
    }

    /// @notice Repay debt by burning HOODZ.
    /// @param _amount Amount of HOODZ to burn against the caller's debt.
    function repayDebtWithHOODZ(uint256 _amount) external {
        if (address(sHOODZ) == address(0)) revert HoodzTreasury_SHoodzNotSet();
        if (!permissions[STATUS.RESERVEDEBTOR][msg.sender] && !permissions[STATUS.HOODZDEBTOR][msg.sender]) {
            revert HoodzTreasury_NotApproved();
        }

        // Returns to inventory rather than being burned - see {withdraw}.
        IERC20(address(HOODZ)).safeTransferFrom(msg.sender, address(this), _amount);

        IsHOODZDebt(address(sHOODZ)).changeDebt(_amount, msg.sender, false);
        totalDebt -= _amount;
        hoodzDebt -= _amount;

        emit RepayDebt(msg.sender, address(HOODZ), _amount, _amount);
    }

    /// @notice Set the maximum debt an address may carry, in HOODZ terms.
    /// @param _address Debtor to configure.
    /// @param _limit New ceiling.
    function setDebtLimit(address _address, uint256 _limit) external onlyGovernor {
        debtLimit[_address] = _limit;
        emit DebtLimitSet(_address, _limit);
    }

    // ========= PERMISSIONS ========= //

    /// @notice Grant a permission immediately. Only available while the timelock is off.
    /// @param _status Permission class to grant.
    /// @param _address Address to permit, or the sHOODZ contract when `_status` is SHOODZ.
    /// @param _calculator Bonding calculator, required when `_status` is LIQUIDITYTOKEN.
    function enable(STATUS _status, address _address, address _calculator) external onlyGovernor {
        if (timelockEnabled) revert HoodzTreasury_TimelockEnabled();
        _enable(_status, _address, _calculator);
    }

    /// @notice Revoke a permission immediately.
    /// @dev Callable by the governor or the guardian, so a compromised integration can be cut
    ///      off without waiting on governance.
    /// @param _status Permission class to revoke.
    /// @param _toDisable Address to revoke it from.
    function disable(STATUS _status, address _toDisable) external {
        if (msg.sender != authority.governor() && msg.sender != authority.guardian()) {
            revert HoodzTreasury_NotGovernorOrGuardian();
        }
        permissions[_status][_toDisable] = false;
        emit Permissioned(_toDisable, _status, false);
    }

    /// @notice Whether an address appears in a status registry, and where.
    /// @param _address Address to look up.
    /// @param _status Registry to search.
    /// @return Whether it was found.
    /// @return Its index in the registry, or zero.
    function indexInRegistry(address _address, STATUS _status) public view returns (bool, uint256) {
        address[] memory entries = registry[_status];
        uint256 length = entries.length;
        for (uint256 i; i < length; ++i) {
            if (_address == entries[i]) return (true, i);
        }
        return (false, 0);
    }

    /// @notice Queue a permission change for later execution. Only available while the timelock is on.
    /// @dev Manager roles wait twice as long, because they can move assets out of the treasury.
    /// @param _status Permission class to grant.
    /// @param _address Address to permit.
    /// @param _calculator Bonding calculator, required when `_status` is LIQUIDITYTOKEN.
    function queueTimelock(STATUS _status, address _address, address _calculator) external onlyGovernor {
        if (_address == address(0)) revert HoodzTreasury_ZeroAddress();
        if (!timelockEnabled) revert HoodzTreasury_TimelockDisabled();
        if (_status == STATUS.LIQUIDITYTOKEN && _calculator == address(0)) revert HoodzTreasury_MissingCalculator();

        uint256 timelock = block.number + blocksNeededForQueue;
        if (_status == STATUS.RESERVEMANAGER || _status == STATUS.LIQUIDITYMANAGER) {
            timelock = block.number + (blocksNeededForQueue * MANAGER_TIMELOCK_MULTIPLIER);
        }

        permissionQueue.push(
            Queue({
                managing: _status,
                toPermit: _address,
                calculator: _calculator,
                timeToImplement: timelock,
                nullify: false,
                executed: false
            })
        );

        emit PermissionQueued(_status, _address);
    }

    /// @notice Execute a queued permission change once its timelock has elapsed.
    /// @dev Permissionless by design: anyone may push through a change governance already
    ///      approved and the public has had `blocksNeededForQueue` blocks to react to.
    /// @param _index Index into {permissionQueue}.
    function execute(uint256 _index) external {
        if (!timelockEnabled) revert HoodzTreasury_TimelockDisabled();

        Queue memory info = permissionQueue[_index];

        if (info.nullify) revert HoodzTreasury_ActionNullified();
        if (info.executed) revert HoodzTreasury_AlreadyExecuted();
        if (block.number < info.timeToImplement) revert HoodzTreasury_TimelockNotComplete();

        permissionQueue[_index].executed = true;
        _enable(info.managing, info.toPermit, info.calculator);
    }

    /// @notice Cancel a queued permission change before it can be executed.
    /// @param _index Index into {permissionQueue}.
    function nullify(uint256 _index) external onlyGovernor {
        permissionQueue[_index].nullify = true;
        emit QueueNullified(_index);
    }

    /// @notice Number of entries in the permission queue.
    /// @return The queue length.
    function permissionQueueLength() external view returns (uint256) {
        return permissionQueue.length;
    }

    /// @notice Number of addresses ever registered under a status.
    /// @param _status Registry to measure.
    /// @return The registry length.
    function registryLength(STATUS _status) external view returns (uint256) {
        return registry[_status].length;
    }

    // ========= TIMELOCK GOVERNANCE ========= //

    /// @notice Turn the timelock on at deployment time, once.
    /// @dev Unlike the Olympus original this is governor-gated, so the initial state cannot be
    ///      front-run by an unrelated caller.
    function initialize() external onlyGovernor {
        if (initialized) revert HoodzTreasury_AlreadyInitialized();
        timelockEnabled = true;
        initialized = true;
        emit TimelockToggled(true);
    }

    /// @notice Start the on-chain governance countdown required to toggle the timelock setting.
    /// @dev The countdown is seven times the ordinary queue delay, so removing the treasury's
    ///      safety rail is itself the slowest action governance can take.
    function orderTimelock() external onlyGovernor {
        onChainGovernanceTimelock = block.number + (blocksNeededForQueue * GOVERNANCE_TIMELOCK_MULTIPLIER);
        emit TimelockOrdered(onChainGovernanceTimelock);
    }

    /// @notice Re-enable the timelock after {orderTimelock} has matured.
    function enableTimelock() external onlyGovernor {
        if (timelockEnabled) revert HoodzTreasury_TimelockAlreadyEnabled();
        if (onChainGovernanceTimelock == 0 || block.number < onChainGovernanceTimelock) {
            revert HoodzTreasury_TimelockNotComplete();
        }

        timelockEnabled = true;
        onChainGovernanceTimelock = 0;
        emit TimelockToggled(true);
    }

    /// @notice Disable the timelock. Self-arming: the first call starts the countdown, a second
    ///         call after it matures actually disables.
    function disableTimelock() external onlyGovernor {
        if (!timelockEnabled) revert HoodzTreasury_TimelockAlreadyDisabled();

        if (onChainGovernanceTimelock != 0 && onChainGovernanceTimelock <= block.number) {
            timelockEnabled = false;
            onChainGovernanceTimelock = 0;
            emit TimelockToggled(false);
        } else {
            onChainGovernanceTimelock = block.number + (blocksNeededForQueue * GOVERNANCE_TIMELOCK_MULTIPLIER);
            emit TimelockOrdered(onChainGovernanceTimelock);
        }
    }

    // ========= ACCOUNTING ========= //

    /// @notice Supply of HOODZ used as the denominator of protocol accounting.
    /// @return Total HOODZ in existence.
    function baseSupply() external view override returns (uint256) {
        return HOODZ.totalSupply();
    }

    /// @notice Reserves held above what is required to back every circulating HOODZ one-for-one.
    /// @dev `totalReserves - (baseSupply - totalDebt)`. Reverts if the treasury is under water,
    ///      which by construction blocks {mint} and {manage}.
    /// @return The excess reserves, in HOODZ terms.
    function excessReserves() public view override returns (uint256) {
        return totalReserves - (HOODZ.totalSupply() - totalDebt);
    }

    /// @notice Recompute `totalReserves` from the treasury's live balances.
    /// @dev Walks both token registries and re-values everything still permitted. The only way
    ///      to correct the books after a rebase, a fee-on-transfer surprise, or a donation.
    function auditReserves() external onlyGovernor {
        uint256 reserves;

        address[] memory reserveTokens = registry[STATUS.RESERVETOKEN];
        uint256 length = reserveTokens.length;
        for (uint256 i; i < length; ++i) {
            address token = reserveTokens[i];
            if (permissions[STATUS.RESERVETOKEN][token]) {
                reserves += tokenValue(token, IERC20(token).balanceOf(address(this)));
            }
        }

        address[] memory liquidityTokens = registry[STATUS.LIQUIDITYTOKEN];
        length = liquidityTokens.length;
        for (uint256 i; i < length; ++i) {
            address token = liquidityTokens[i];
            if (permissions[STATUS.LIQUIDITYTOKEN][token]) {
                reserves += tokenValue(token, IERC20(token).balanceOf(address(this)));
            }
        }

        totalReserves = reserves;
        emit ReservesAudited(reserves);
    }

    /// @notice Value of `_amount` of `_token` in HOODZ terms (9 decimals).
    /// @dev Reserve tokens are a pure decimal renormalisation — one dollar of a stable reserve
    ///      is one HOODZ of backing. Liquidity tokens are routed to their bonding calculator,
    ///      which prices them at risk-free value rather than spot.
    /// @param _token Asset to value.
    /// @param _amount Amount of the asset.
    /// @return value_ The value in HOODZ terms.
    function tokenValue(address _token, uint256 _amount) public view override returns (uint256 value_) {
        value_ = (_amount * (10 ** HOODZ_DECIMALS)) / (10 ** IERC20Metadata(_token).decimals());

        if (permissions[STATUS.LIQUIDITYTOKEN][_token]) {
            value_ = IBondingCalculator(bondCalculator[_token]).valuation(_token, _amount);
        }
    }

    // ========= INTERNAL ========= //

    /// @dev Shared body of {enable} and {execute}. Registering a token under one class removes
    ///      it from the other, so a pair can be reclassified without being counted twice by
    ///      {auditReserves}.
    function _enable(STATUS _status, address _address, address _calculator) internal {
        if (_status == STATUS.SHOODZ) {
            if (_address == address(0)) revert HoodzTreasury_ZeroAddress();
            sHOODZ = IsHOODZ(_address);
            emit SHoodzSet(_address);
            emit Permissioned(_address, _status, true);
            return;
        }

        if (_status == STATUS.LIQUIDITYTOKEN) {
            if (_calculator == address(0)) revert HoodzTreasury_MissingCalculator();
            bondCalculator[_address] = _calculator;
        }

        permissions[_status][_address] = true;

        (bool registered,) = indexInRegistry(_address, _status);
        if (!registered) {
            registry[_status].push(_address);

            if (_status == STATUS.LIQUIDITYTOKEN) {
                (bool reg, uint256 index) = indexInRegistry(_address, STATUS.RESERVETOKEN);
                if (reg) delete registry[STATUS.RESERVETOKEN][index];
            } else if (_status == STATUS.RESERVETOKEN) {
                (bool reg, uint256 index) = indexInRegistry(_address, STATUS.LIQUIDITYTOKEN);
                if (reg) delete registry[STATUS.LIQUIDITYTOKEN][index];
            }
        }

        emit Permissioned(_address, _status, true);
    }
}
