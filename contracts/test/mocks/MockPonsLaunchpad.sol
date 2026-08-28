// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @dev UNAUDITED. Do not use in production without a full audit.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPonsLaunchpad} from "../../src/pons/IPonsLaunchpad.sol";
import {IPonsBondingCurve} from "../../src/pons/IPonsBondingCurve.sol";
import {IPonsFeeRouter} from "../../src/pons/IPonsFeeRouter.sol";
import {IPositionLocker} from "../../src/pons/IPositionLocker.sol";
import {IUniswapV4PoolManager, PoolKey, PonsPoolId} from "../../src/pons/IUniswapV4PoolManager.sol";

/// @title  MockPonsBondingCurve
/// @notice Stand-in for a PONS V2 bonding curve: reserves accumulate until they cross the
///         graduation threshold, at which point the curve is graduatable and its reserves are
///         considered migrated into a permanently locked Uniswap v4 pool.
/// @dev    A state machine, not a pricing model - {buy} simply credits reserves. That is all
///         `HoodzLaunchGuard` ever reads it for.
contract MockPonsBondingCurve is IPonsBondingCurve {
    /// @inheritdoc IPonsBondingCurve
    address public immutable override token;
    /// @inheritdoc IPonsBondingCurve
    address public immutable override reserveToken;
    /// @inheritdoc IPonsBondingCurve
    uint256 public immutable override graduationThreshold;

    /// @inheritdoc IPonsBondingCurve
    uint256 public override reserves;
    /// @inheritdoc IPonsBondingCurve
    uint256 public override supplySold;
    /// @inheritdoc IPonsBondingCurve
    bool public override graduated;

    /// @notice Flat price used by {buy} / {sell}, in reserve per whole token, 1e18 scaled.
    uint256 public price = 1e18;

    /// @notice Thrown when the launchpad graduates a curve that is still below its threshold.
    error ThresholdNotReached(uint256 reserves, uint256 threshold);
    /// @notice Thrown when the curve has already graduated.
    error AlreadyGraduated();
    /// @notice Thrown when this mock is asked to do something it does not model.
    error NotImplemented();

    /// @param token_ The launched token.
    /// @param reserveToken_ The curve's reserve asset.
    /// @param graduationThreshold_ Reserve balance required to graduate.
    constructor(address token_, address reserveToken_, uint256 graduationThreshold_) {
        token = token_;
        reserveToken = reserveToken_;
        graduationThreshold = graduationThreshold_;
    }

    /// @inheritdoc IPonsBondingCurve
    /// @dev Not modelled: tests credit the curve with {creditReserves} instead.
    function buy(uint256) external payable override returns (uint256) {
        revert NotImplemented();
    }

    /// @inheritdoc IPonsBondingCurve
    /// @dev Not modelled: tests debit the curve with {creditReserves}.
    function sell(uint256, uint256) external pure override returns (uint256) {
        revert NotImplemented();
    }

    /// @inheritdoc IPonsBondingCurve
    function spotPrice() external view override returns (uint256) {
        return price;
    }

    /// @notice Credits the curve with reserve, as if someone had bought on it.
    /// @param amount_ Reserve added.
    function creditReserves(uint256 amount_) external {
        reserves += amount_;
        supplySold += (amount_ * 1e18) / price;
    }

    /// @notice Marks the curve graduated. Called by {MockPonsLaunchpad.graduate}.
    function markGraduated() external {
        if (graduated) revert AlreadyGraduated();
        if (reserves < graduationThreshold) revert ThresholdNotReached(reserves, graduationThreshold);
        graduated = true;
    }

    /// @notice Overrides the graduation flag without the threshold check. Test escape hatch.
    /// @param graduated_ The state to force.
    function forceGraduated(bool graduated_) external {
        graduated = graduated_;
    }
}

/// @title  MockPonsLaunchpad
/// @notice Stand-in for the PONS launchpad registry: maps a token to its curve and its graduated
///         pool, and answers `isGraduated`, the first of the three questions `HoodzLaunchGuard`
///         gates HOOD mint authority on.
/// @dev    Non-custodial by construction, mirroring PONS V2 - it never takes user funds.
contract MockPonsLaunchpad is IPonsLaunchpad {
    /// @inheritdoc IPonsLaunchpad
    mapping(address token => address curve) public override curveOf;
    /// @inheritdoc IPonsLaunchpad
    mapping(address token => address pool) public override poolOf;

    /// @dev When set, overrides the curve's own answer so a test can flip graduation directly.
    mapping(address token => bool forced) private _forced;
    mapping(address token => bool value) private _forcedValue;

    /// @dev When true, every read reverts, exercising the guard's fail-closed `try/catch`.
    bool public reverting;

    /// @notice Thrown when the token has no registered curve.
    error NotLaunched(address token);
    /// @notice Thrown while {reverting} is set, to test fail-closed behaviour.
    error LaunchpadDown();

    /// @inheritdoc IPonsLaunchpad
    /// @dev HOOD is pre-deployed and passed in via `params.token`; this mock only registers it
    ///      against the curve the test already deployed with {register}.
    function createToken(TokenParams calldata params) external payable override returns (address, address) {
        address curve = curveOf[params.token];
        if (curve == address(0)) revert NotLaunched(params.token);
        emit TokenCreated(params.token, curve, params.creator, params.reserveToken);
        return (params.token, curve);
    }

    /// @inheritdoc IPonsLaunchpad
    function graduate(address token_) external override returns (address pool) {
        address curve = curveOf[token_];
        if (curve == address(0)) revert NotLaunched(token_);

        MockPonsBondingCurve(curve).markGraduated();
        pool = poolOf[token_];

        emit Graduated(token_, curve, pool, MockPonsBondingCurve(curve).reserves());
    }

    /// @inheritdoc IPonsLaunchpad
    function isGraduated(address token_) external view override returns (bool) {
        if (reverting) revert LaunchpadDown();
        if (_forced[token_]) return _forcedValue[token_];
        address curve = curveOf[token_];
        if (curve == address(0)) revert NotLaunched(token_);
        return IPonsBondingCurve(curve).graduated();
    }

    /// @notice Registers a token against a curve and the pool it will graduate into.
    /// @param token_ The launched token.
    /// @param curve_ Its bonding curve.
    /// @param pool_ The Uniswap v4 pool graduation migrates into.
    function register(address token_, address curve_, address pool_) external {
        curveOf[token_] = curve_;
        poolOf[token_] = pool_;
    }

    /// @notice Overrides the graduation answer for a token.
    /// @param token_ The token to override.
    /// @param value_ The answer to report.
    function setGraduated(address token_, bool value_) external {
        _forced[token_] = true;
        _forcedValue[token_] = value_;
    }

    /// @notice Clears the graduated pool, simulating a launchpad that lost the pool record.
    /// @param token_ The token to clear.
    function clearPool(address token_) external {
        poolOf[token_] = address(0);
    }

    /// @notice Makes every read revert, so a consumer's fail-closed path can be exercised.
    /// @param reverting_ Whether reads should revert.
    function setReverting(bool reverting_) external {
        reverting = reverting_;
    }
}

/// @title  MockPositionLocker
/// @notice Stand-in for the contract that owns the graduated PONS LP position forever.
/// @dev    {lockForever} writes the shape `HoodzLaunchGuard` demands: liquidity present, pool id
///         hashing to the recorded key, `unlockable == false`, `unlockTime == type(uint256).max`.
///         The setters below exist so a test can break exactly one of those at a time and prove
///         the guard fails closed on each.
contract MockPositionLocker is IPositionLocker {
    mapping(address token => LockedPosition position) private _positions;
    mapping(address token => bool value) private _unlockable;
    mapping(address token => bool value) private _permanent;

    /// @notice When true, every read reverts, exercising the guard's fail-closed `try/catch`.
    bool public reverting;

    /// @notice Thrown while {reverting} is set.
    error LockerDown();

    /// @inheritdoc IPositionLocker
    function lockOf(address token_) external view override returns (LockedPosition memory) {
        if (reverting) revert LockerDown();
        return _positions[token_];
    }

    /// @inheritdoc IPositionLocker
    function isPermanentlyLocked(address token_) external view override returns (bool) {
        if (reverting) revert LockerDown();
        return _permanent[token_];
    }

    /// @inheritdoc IPositionLocker
    function unlockable(address token_) external view override returns (bool) {
        if (reverting) revert LockerDown();
        return _unlockable[token_];
    }

    /// @inheritdoc IPositionLocker
    function beneficiary(address token_) external view override returns (address) {
        return _positions[token_].beneficiary;
    }

    /// @notice Records a well-formed, permanently locked position for `token_`.
    /// @param token_ The launched token.
    /// @param pool_ The graduated pool.
    /// @param key_ The v4 pool key the position was minted against.
    /// @param liquidity_ Locked liquidity; must be non-zero for the guard to accept it.
    /// @param beneficiary_ Fee beneficiary of the locked position.
    function lockForever(address token_, address pool_, PoolKey memory key_, uint128 liquidity_, address beneficiary_)
        external
    {
        _positions[token_] = LockedPosition({
            token: token_,
            pool: pool_,
            poolId: PonsPoolId.toId(key_),
            key: key_,
            positionId: 1,
            liquidity: liquidity_,
            beneficiary: beneficiary_,
            unlockTime: type(uint256).max,
            unlockable: false
        });
        _permanent[token_] = liquidity_ != 0;
        _unlockable[token_] = false;

        emit PositionLocked(token_, pool_, 1, liquidity_);
    }

    /// @notice Opens an unlock path on a recorded position - the guard must refuse to release.
    /// @param token_ The launched token.
    /// @param unlockable_ Whether an unlock path exists.
    /// @param unlockTime_ Timestamp at which principal could be withdrawn.
    function setUnlockable(address token_, bool unlockable_, uint256 unlockTime_) external {
        _positions[token_].unlockable = unlockable_;
        _positions[token_].unlockTime = unlockTime_;
        _unlockable[token_] = unlockable_;
        if (unlockable_) _permanent[token_] = false;
    }

    /// @notice Overwrites the recorded pool id, simulating a spoofed id that does not hash right.
    /// @param token_ The launched token.
    /// @param poolId_ The id to record.
    function setPoolId(address token_, bytes32 poolId_) external {
        _positions[token_].poolId = poolId_;
    }

    /// @notice Sets the recorded liquidity, so a drained position can be simulated.
    /// @param token_ The launched token.
    /// @param liquidity_ Liquidity to record.
    function setLiquidity(address token_, uint128 liquidity_) external {
        _positions[token_].liquidity = liquidity_;
        _permanent[token_] = liquidity_ != 0 && !_unlockable[token_];
    }

    /// @notice Makes every read revert, so a consumer's fail-closed path can be exercised.
    /// @param reverting_ Whether reads should revert.
    function setReverting(bool reverting_) external {
        reverting = reverting_;
    }
}

/// @title  MockUniswapV4PoolManager
/// @notice Read-only stand-in for the Uniswap v4 singleton: reports the liquidity a test sets.
/// @dev    `HoodzLaunchGuard` cross-checks the locker's claim against this when configured.
contract MockUniswapV4PoolManager is IUniswapV4PoolManager {
    mapping(bytes32 id => uint128 liquidity) private _liquidity;
    mapping(bytes32 id => uint160 sqrtPriceX96) private _sqrtPriceX96;

    /// @inheritdoc IUniswapV4PoolManager
    function getLiquidity(bytes32 id_) external view override returns (uint128) {
        return _liquidity[id_];
    }

    /// @inheritdoc IUniswapV4PoolManager
    function getSlot0(bytes32 id_) external view override returns (uint160, int24, uint24, uint24) {
        return (_sqrtPriceX96[id_], int24(0), uint24(0), uint24(3000));
    }

    /// @inheritdoc IUniswapV4PoolManager
    /// @dev Not modelled; the guard only uses the typed reads above.
    function extsload(bytes32) external pure override returns (bytes32) {
        return bytes32(0);
    }

    /// @notice Sets the liquidity reported for a pool id.
    /// @param id_ The v4 pool id.
    /// @param liquidity_ Liquidity to report.
    function setLiquidity(bytes32 id_, uint128 liquidity_) external {
        _liquidity[id_] = liquidity_;
        _sqrtPriceX96[id_] = liquidity_ == 0 ? 0 : uint160(1 << 96);
    }
}

/// @title  MockPonsFeeRouter
/// @notice Stand-in for the PONS fee router that pays the protocol's share of trading fees.
/// @dev    Holds reserve tokens the test minted into it and releases them to the caller, which
///         is exactly the shape `FeeRouterBuyback._claim()` expects.
contract MockPonsFeeRouter is IPonsFeeRouter {
    /// @notice The fee asset paid out.
    IERC20 public immutable feeToken;

    /// @inheritdoc IPonsFeeRouter
    address public override feeRecipient;

    mapping(address token => uint256 amount) private _claimable;

    /// @notice Thrown when a non-recipient tries to claim.
    error NotRecipient(address caller);

    /// @param feeToken_ The asset fees are paid in (the launch reserve token).
    constructor(IERC20 feeToken_) {
        feeToken = feeToken_;
    }

    /// @inheritdoc IPonsFeeRouter
    function claimFees(address token_) external override returns (uint256 amount) {
        if (feeRecipient != address(0) && msg.sender != feeRecipient) revert NotRecipient(msg.sender);
        amount = _claimable[token_];
        _claimable[token_] = 0;
        if (amount != 0) feeToken.transfer(msg.sender, amount);
    }

    /// @inheritdoc IPonsFeeRouter
    function claimableFees(address token_) external view override returns (uint256) {
        return _claimable[token_];
    }

    /// @inheritdoc IPonsFeeRouter
    function setFeeRecipient(address newRecipient) external override {
        feeRecipient = newRecipient;
    }

    /// @notice Books fees as accrued for a launched token. The router must already hold them.
    /// @param token_ The launched token the fees belong to.
    /// @param amount_ Fee amount now claimable.
    function accrue(address token_, uint256 amount_) external {
        _claimable[token_] = amount_;
    }
}
