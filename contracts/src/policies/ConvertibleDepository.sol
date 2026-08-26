// SPDX-License-Identifier: AGPL-3.0-or-later
// UNAUDITED. Do not use in production without a full audit.
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
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {HoodzAccessControlled} from "../types/HoodzAccessControlled.sol";
import {IHoodzAuthority} from "../interfaces/IHoodzAuthority.sol";
import {IHOODZ} from "../interfaces/IHOODZ.sol";
import {ITreasury} from "../interfaces/ITreasury.sol";
import {IConvertibleDepository} from "../interfaces/IConvertibleDepository.sol";

/// @title  ConvertibleDepository
/// @notice The Hoodz Convertible Deposit (CD) facility. A depositor locks reserve tokens and
///         receives a position that may be converted into HOODZ at a fixed strike until it
///         expires. While a position is open its reserve sits in a yield bearing ERC4626 vault
///         and the yield accrues to the DAO. Converting sends the reserve to the treasury and
///         mints HOODZ against it; letting the position expire simply gives the reserve back, so
///         the depositor is never exposed to HOODZ unless they choose to be.
/// @dev    UNAUDITED. Do not use in production without a full audit.
///
///         SCALING. Reserve amounts are raw 1e18 units, HOODZ amounts raw 1e9 units.
///         `conversionPrice` is whole reserve tokens per ONE WHOLE HOODZ in 1e18 fixed point, so
///             hoodzOut(1e9) = amount(1e18) * HOODZ_SCALE(1e9) / conversionPrice(1e18)
///         converts a reserve amount into HOODZ: the 1e18 numerator and denominator cancel and
///         the 1e9 factor puts the result in HOODZ's own units.
///         `reclaimRate` is 1e18 fixed point, `1e18` meaning 100% of principal returned.
///
///         ACCESS. Position creation is `onlyPolicy` - positions come out of the DAO's CD
///         auctions, never out of thin air - while converting, redeeming and reclaiming are
///         restricted to the position's own owner, since those are the depositor's rights and
///         no role may exercise them on their behalf.
contract ConvertibleDepository is IConvertibleDepository, HoodzAccessControlled, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ======================================== CONSTANTS ======================================= */

    /// @notice Fixed point unit for every ratio in this contract (1.0).
    uint256 internal constant ONE = 1e18;
    /// @notice Raw unit of the HOODZ token, which carries 9 decimals.
    uint256 internal constant HOODZ_SCALE = 1e9;
    /// @notice Decimals the reserve asset must carry for the scaling above to hold.
    uint8 internal constant RESERVE_DECIMALS = 18;
    /// @notice Decimals the HOODZ token must carry for the scaling above to hold.
    uint8 internal constant HOODZ_DECIMALS = 9;

    /* ======================================= IMMUTABLES ======================================= */

    /// @notice The HOODZ token minted on conversion.
    IHOODZ public immutable hoodz;
    /// @notice Reserve asset deposited by users, 18 decimals.
    IERC20 public immutable reserve;
    /// @notice ERC4626 vault wrapping `reserve`; holds deposits while positions are open.
    IERC4626 public immutable sReserve;
    /// @notice Hoodz Treasury: receives converted reserves and mints the HOODZ.
    ITreasury public immutable treasury;

    /* ========================================== STATE ========================================= */

    /// @inheritdoc IConvertibleDepository
    uint256 public totalDeposits;
    /// @inheritdoc IConvertibleDepository
    uint256 public reclaimRate;

    /// @dev Every position ever minted, indexed by position id.
    Position[] internal _positions;
    /// @dev Position ids minted for each depositor, in creation order.
    mapping(address => uint256[]) internal _positionsFor;

    /* ======================================= CONSTRUCTOR ====================================== */

    /// @notice Wire the convertible depository into the protocol.
    /// @param authority_   Hoodz authority holding the governor / guardian / policy / vault roles.
    /// @param hoodz_        HOODZ token, must report 9 decimals.
    /// @param reserve_     Reserve asset, must report 18 decimals.
    /// @param sReserve_    ERC4626 vault whose asset is `reserve_`.
    /// @param treasury_    Hoodz Treasury.
    /// @param reclaimRate_ Initial early exit rate, 1e18 fixed point, in `(0, 1e18]`.
    constructor(
        IHoodzAuthority authority_,
        IHOODZ hoodz_,
        IERC20 reserve_,
        IERC4626 sReserve_,
        ITreasury treasury_,
        uint256 reclaimRate_
    ) HoodzAccessControlled(authority_) {
        if (
            address(hoodz_) == address(0) || address(reserve_) == address(0) || address(sReserve_) == address(0)
                || address(treasury_) == address(0)
        ) revert CD_ZeroAddress();
        if (reclaimRate_ == 0 || reclaimRate_ > ONE) revert CD_InvalidReclaimRate(reclaimRate_);
        if (sReserve_.asset() != address(reserve_)) revert CD_AssetMismatch(address(sReserve_), address(reserve_));

        uint8 reserveDecimals = IERC20Metadata(address(reserve_)).decimals();
        if (reserveDecimals != RESERVE_DECIMALS) {
            revert CD_UnexpectedDecimals(address(reserve_), RESERVE_DECIMALS, reserveDecimals);
        }
        uint8 hoodzDecimals = IERC20Metadata(address(hoodz_)).decimals();
        if (hoodzDecimals != HOODZ_DECIMALS) {
            revert CD_UnexpectedDecimals(address(hoodz_), HOODZ_DECIMALS, hoodzDecimals);
        }

        hoodz = hoodz_;
        reserve = reserve_;
        sReserve = sReserve_;
        treasury = treasury_;
        reclaimRate = reclaimRate_;
    }

    /* ========================================= MUTATIVE ======================================= */

    /// @inheritdoc IConvertibleDepository
    /// @dev The depositor's ERC20 approval to this contract is their consent: the CD auction
    ///      policy calls this to settle a filled bid, it cannot conjure a position without one.
    ///      The reserve is wrapped immediately so the deposit earns yield for the DAO for as
    ///      long as the position stays open.
    function create(address account, uint256 amount, uint256 conversionPrice, uint48 expiry)
        external
        onlyPolicy
        nonReentrant
        returns (uint256 positionId)
    {
        if (account == address(0)) revert CD_ZeroAddress();
        if (amount == 0) revert CD_InvalidAmount(amount);
        if (conversionPrice == 0) revert CD_InvalidPrice(conversionPrice);
        if (expiry <= block.timestamp) revert CD_InvalidExpiry(expiry);

        reserve.safeTransferFrom(account, address(this), amount);
        reserve.forceApprove(address(sReserve), amount);
        sReserve.deposit(amount, address(this));

        totalDeposits += amount;

        positionId = _positions.length;
        _positions.push(
            Position({
                owner: account,
                remainingDeposit: amount,
                conversionPrice: conversionPrice,
                expiry: expiry,
                createdAt: uint48(block.timestamp)
            })
        );
        _positionsFor[account].push(positionId);

        emit PositionCreated(positionId, account, amount, conversionPrice, expiry);
    }

    /// @inheritdoc IConvertibleDepository
    /// @dev The reserve is booked into the treasury as pure profit (no HOODZ minted against it)
    ///      and the HOODZ owed is minted separately, so the two legs are always accounted for at
    ///      the strike rather than at the treasury's own valuation of the deposit.
    function convert(uint256 positionId, uint256 amount) external nonReentrant returns (uint256 hoodzOut) {
        Position storage position = _position(positionId);
        if (position.owner != msg.sender) revert CD_NotOwner(positionId, msg.sender);
        if (block.timestamp >= position.expiry) revert CD_PositionExpired(positionId, position.expiry);
        if (amount == 0 || amount > position.remainingDeposit) revert CD_InvalidAmount(amount);

        hoodzOut = (amount * HOODZ_SCALE) / position.conversionPrice;
        if (hoodzOut == 0) revert CD_NothingToConvert();

        position.remainingDeposit -= amount;
        totalDeposits -= amount;

        _unwrap(amount);
        _bookToTreasury(amount);
        treasury.payout(msg.sender, hoodzOut);

        emit Converted(positionId, msg.sender, amount, hoodzOut);
    }

    /// @inheritdoc IConvertibleDepository
    /// @dev Early exits give up `1 - reclaimRate` of the principal, which stays with the DAO as
    ///      the price of unwinding the option before it expires.
    function redeem(uint256 positionId, uint256 amount) external nonReentrant returns (uint256 reserveOut) {
        Position storage position = _position(positionId);
        if (position.owner != msg.sender) revert CD_NotOwner(positionId, msg.sender);
        if (block.timestamp >= position.expiry) revert CD_PositionExpired(positionId, position.expiry);
        if (amount == 0 || amount > position.remainingDeposit) revert CD_InvalidAmount(amount);

        position.remainingDeposit -= amount;
        totalDeposits -= amount;

        reserveOut = (amount * reclaimRate) / ONE;

        _unwrap(amount);
        if (reserveOut != 0) reserve.safeTransfer(msg.sender, reserveOut);

        uint256 forfeited = amount - reserveOut;
        if (forfeited != 0) _bookToTreasury(forfeited);

        emit Redeemed(positionId, msg.sender, amount, reserveOut);
    }

    /// @inheritdoc IConvertibleDepository
    /// @dev Once a position has expired the option is gone and the deposit is just a deposit,
    ///      so it comes back one for one with no haircut.
    function reclaim(uint256 positionId, uint256 amount) external nonReentrant returns (uint256 reserveOut) {
        Position storage position = _position(positionId);
        if (position.owner != msg.sender) revert CD_NotOwner(positionId, msg.sender);
        if (block.timestamp < position.expiry) revert CD_PositionNotExpired(positionId, position.expiry);
        if (amount == 0 || amount > position.remainingDeposit) revert CD_InvalidAmount(amount);

        position.remainingDeposit -= amount;
        totalDeposits -= amount;

        _unwrap(amount);
        reserveOut = amount;
        reserve.safeTransfer(msg.sender, reserveOut);

        emit Reclaimed(positionId, msg.sender, amount);
    }

    /// @inheritdoc IConvertibleDepository
    /// @dev Anything the vault holds above `totalDeposits` belongs to the DAO: vault yield plus
    ///      principal forfeited by early exits that has not been booked yet.
    function sweepYield() external onlyPolicy nonReentrant returns (uint256 swept) {
        uint256 assets = sReserve.previewRedeem(sReserve.balanceOf(address(this)));
        uint256 locked = totalDeposits;
        if (assets <= locked) return 0;

        swept = assets - locked;
        _unwrap(swept);
        _bookToTreasury(swept);

        emit YieldSwept(swept);
    }

    /// @inheritdoc IConvertibleDepository
    function setReclaimRate(uint256 newReclaimRate) external onlyGovernor {
        if (newReclaimRate == 0 || newReclaimRate > ONE) revert CD_InvalidReclaimRate(newReclaimRate);
        reclaimRate = newReclaimRate;
        emit ReclaimRateChanged(newReclaimRate);
    }

    /* ========================================== VIEWS ========================================= */

    /// @inheritdoc IConvertibleDepository
    function positionsFor(address account) external view returns (uint256[] memory ids) {
        ids = _positionsFor[account];
    }

    /// @inheritdoc IConvertibleDepository
    function previewConvert(uint256 positionId, uint256 amount) public view returns (uint256 hoodzOut) {
        if (positionId >= _positions.length) revert CD_UnknownPosition(positionId);
        Position storage position = _positions[positionId];
        if (amount > position.remainingDeposit) revert CD_InvalidAmount(amount);
        // hoodzOut(1e9) = amount(1e18) * 1e9 / conversionPrice(1e18)
        hoodzOut = (amount * HOODZ_SCALE) / position.conversionPrice;
    }

    /// @inheritdoc IConvertibleDepository
    function getPosition(uint256 positionId) external view returns (Position memory position) {
        if (positionId >= _positions.length) revert CD_UnknownPosition(positionId);
        position = _positions[positionId];
    }

    /// @inheritdoc IConvertibleDepository
    function positionCount() external view returns (uint256) {
        return _positions.length;
    }

    /// @notice Reserve value of everything this facility holds in the vault, yield included.
    /// @return assets Reserve equivalent of the vault shares held here, raw 1e18 units.
    function vaultAssets() external view returns (uint256 assets) {
        assets = sReserve.previewRedeem(sReserve.balanceOf(address(this)));
    }

    /// @notice Yield (and forfeited principal) currently available to `sweepYield`.
    /// @return available Reserve above `totalDeposits`, raw 1e18 units.
    function sweepableYield() external view returns (uint256 available) {
        uint256 assets = sReserve.previewRedeem(sReserve.balanceOf(address(this)));
        available = assets > totalDeposits ? assets - totalDeposits : 0;
    }

    /* ========================================= INTERNAL ======================================= */

    /// @dev Load a position, reverting on an unknown id.
    function _position(uint256 positionId) internal view returns (Position storage position) {
        if (positionId >= _positions.length) revert CD_UnknownPosition(positionId);
        position = _positions[positionId];
    }

    /// @dev Redeem exactly `amount` of reserve out of the vault into this contract.
    /// @param amount Reserve to unwrap, raw 1e18 units.
    function _unwrap(uint256 amount) internal {
        if (amount == 0) return;
        sReserve.withdraw(amount, address(this), address(this));
    }

    /// @dev Book reserves into the treasury without minting: `ITreasury.deposit` mints
    ///      `value - profit` HOODZ to the caller, so passing `profit == value` (both 9 decimal
    ///      HOODZ terms, as returned by `tokenValue`) credits the full amount and mints nothing.
    ///      HOODZ owed to a converter is minted separately, at the position's strike.
    /// @param amount Reserve to book, raw 1e18 units.
    function _bookToTreasury(uint256 amount) internal {
        if (amount == 0) return;
        uint256 value = treasury.tokenValue(address(reserve), amount);
        reserve.forceApprove(address(treasury), amount);
        treasury.deposit(amount, address(reserve), value);
    }
}
