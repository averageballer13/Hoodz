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

/// @title  IConvertibleDepository
/// @notice Interface of the Hoodz Convertible Deposit (CD) facility. A depositor locks
///         reserve tokens and receives a position that may be converted into HOODZ at a fixed
///         strike until it expires. Deposits that are never converted are simply returned,
///         so the depositor is only ever exposed to the reserve.
/// @dev    UNAUDITED. Do not use in production without a full audit.
///
///         FIXED POINT CONVENTIONS
///         - `remainingDeposit` is raw reserve units (1e18).
///         - `conversionPrice` is whole reserve tokens per ONE WHOLE HOODZ, 1e18 fixed point.
///         - Conversion: `hoodzOut(1e9) = amount(1e18) * 1e9 / conversionPrice(1e18)`.
///         - `reclaimRate` is 1e18 fixed point, `1e18` == 100% returned on an early exit.
interface IConvertibleDepository {
    /// @notice A single convertible deposit position.
    /// @param owner            Only address allowed to convert, redeem or reclaim.
    /// @param remainingDeposit Reserve still locked in the position, raw 1e18 units.
    /// @param conversionPrice  Strike: whole reserve per whole HOODZ, 1e18.
    /// @param expiry           Unix timestamp after which conversion is closed and reclaim opens.
    /// @param createdAt        Unix timestamp the position was created.
    struct Position {
        address owner;
        uint256 remainingDeposit;
        uint256 conversionPrice;
        uint48 expiry;
        uint48 createdAt;
    }

    /* ------------------------------------------------------------------ events */

    /// @notice Emitted when a position is minted for a depositor.
    event PositionCreated(
        uint256 indexed positionId, address indexed owner, uint256 amount, uint256 conversionPrice, uint48 expiry
    );
    /// @notice Emitted when a depositor converts part of a position into HOODZ.
    event Converted(uint256 indexed positionId, address indexed owner, uint256 amount, uint256 hoodzOut);
    /// @notice Emitted when a depositor exits early at the reclaim rate.
    event Redeemed(uint256 indexed positionId, address indexed owner, uint256 amount, uint256 reserveOut);
    /// @notice Emitted when a depositor takes an expired deposit back one for one.
    event Reclaimed(uint256 indexed positionId, address indexed owner, uint256 amount);
    /// @notice Emitted when vault yield (and forfeited principal) is pushed to the treasury.
    event YieldSwept(uint256 amount);
    /// @notice Emitted when governance changes the early exit rate.
    event ReclaimRateChanged(uint256 newReclaimRate);

    /* ------------------------------------------------------------------ errors */

    error CD_ZeroAddress();
    error CD_InvalidAmount(uint256 amount);
    error CD_InvalidPrice(uint256 conversionPrice);
    error CD_InvalidExpiry(uint48 expiry);
    error CD_InvalidReclaimRate(uint256 reclaimRate);
    error CD_UnknownPosition(uint256 positionId);
    error CD_NotOwner(uint256 positionId, address caller);
    error CD_PositionExpired(uint256 positionId, uint48 expiry);
    error CD_PositionNotExpired(uint256 positionId, uint48 expiry);
    error CD_UnexpectedDecimals(address token, uint8 expected, uint8 actual);
    error CD_AssetMismatch(address vault, address expectedAsset);
    error CD_NothingToConvert();

    /* ---------------------------------------------------------------- mutative */

    /// @notice Mint a convertible deposit position for `account`, pulling their reserve.
    /// @param account         Depositor; must have approved this contract for `amount`.
    /// @param amount          Reserve to lock, raw 1e18 units.
    /// @param conversionPrice Strike, whole reserve per whole HOODZ, 1e18.
    /// @param expiry          Unix timestamp at which conversion closes.
    /// @return positionId Identifier of the new position.
    function create(address account, uint256 amount, uint256 conversionPrice, uint48 expiry)
        external
        returns (uint256 positionId);

    /// @notice Convert part of a position into HOODZ at its strike, before expiry.
    /// @param positionId Position to convert.
    /// @param amount     Reserve to convert, raw 1e18 units.
    /// @return hoodzOut HOODZ minted to the position owner, raw 1e9 units.
    function convert(uint256 positionId, uint256 amount) external returns (uint256 hoodzOut);

    /// @notice Exit a position early, before expiry, at the reclaim rate.
    /// @param positionId Position to exit.
    /// @param amount     Reserve to withdraw, raw 1e18 units.
    /// @return reserveOut Reserve returned to the owner; the remainder is treasury profit.
    function redeem(uint256 positionId, uint256 amount) external returns (uint256 reserveOut);

    /// @notice Take an expired, unconverted deposit back one for one.
    /// @param positionId Position to reclaim.
    /// @param amount     Reserve to withdraw, raw 1e18 units.
    /// @return reserveOut Reserve returned to the owner, always equal to `amount`.
    function reclaim(uint256 positionId, uint256 amount) external returns (uint256 reserveOut);

    /// @notice Push accrued vault yield and forfeited principal to the treasury.
    /// @return swept Reserve sent to the treasury, raw 1e18 units.
    function sweepYield() external returns (uint256 swept);

    /// @notice Change the fraction of principal returned on an early exit.
    /// @param newReclaimRate New rate, 1e18 fixed point, in `(0, 1e18]`.
    function setReclaimRate(uint256 newReclaimRate) external;

    /* ------------------------------------------------------------------- views */

    /// @notice All position identifiers ever minted for `account`.
    /// @param account Depositor to look up.
    /// @return ids Position identifiers, including fully spent positions.
    function positionsFor(address account) external view returns (uint256[] memory ids);

    /// @notice HOODZ that converting `amount` of `positionId` would mint right now.
    /// @param positionId Position to price.
    /// @param amount     Reserve to convert, raw 1e18 units.
    /// @return hoodzOut HOODZ out, raw 1e9 units.
    function previewConvert(uint256 positionId, uint256 amount) external view returns (uint256 hoodzOut);

    /// @notice Read a full position.
    /// @param positionId Position to read.
    /// @return position The stored {Position}.
    function getPosition(uint256 positionId) external view returns (Position memory position);

    /// @notice Number of positions ever minted.
    function positionCount() external view returns (uint256);

    /// @notice Reserve currently locked across every open position, raw 1e18 units.
    function totalDeposits() external view returns (uint256);

    /// @notice Fraction of principal returned on an early exit, 1e18.
    function reclaimRate() external view returns (uint256);
}
