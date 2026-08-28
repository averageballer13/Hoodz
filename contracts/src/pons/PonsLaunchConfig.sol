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

/// @title PonsLaunchConfig
/// @author Hoodz
/// @notice The immutable, on-chain record of the HOOD launch on PONS.
/// @dev Deployed once, before the curve is funded, and never again. Every field is `immutable`, set in
///      the constructor and burned into the deployed bytecode: there is no owner, no setter, no
///      upgrade path and no storage to overwrite. Its only job is to make the terms of the launch -
///      which token, against which reserve, on which curve, at what raise, threshold and fee tier, and
///      who may ever touch the locked LP's fees - independently verifiable by anyone reading the chain,
///      rather than a claim in a document.
///
///      {HoodzLaunchGuard} anchors itself to this record, so the guard's notion of "the HOOD launch"
///      cannot be re-pointed at a different token after deployment.
contract PonsLaunchConfig {
    /* ------------------------------------------------------------------ types */

    /// @notice The complete launch record.
    /// @param hoodzToken The HOOD ERC20 being launched.
    /// @param reserveToken The quote asset collected by the bonding curve.
    /// @param curve The PONS bonding curve escrow for this launch.
    /// @param targetRaise Total reserve the curve is sized to collect across its whole range.
    /// @param graduationThreshold Reserve balance at which the curve becomes graduatable.
    /// @param lpFeeTier Fee tier of the graduated Uniswap v4 pool, in hundredths of a bip.
    /// @param lockBeneficiary Address entitled to the locked LP position's trading fees. Fees only.
    /// @param launchTimestamp Unix timestamp the curve went live.
    struct LaunchManifest {
        address hoodzToken;
        address reserveToken;
        address curve;
        uint256 targetRaise;
        uint256 graduationThreshold;
        uint24 lpFeeTier;
        address lockBeneficiary;
        uint64 launchTimestamp;
    }

    /* ----------------------------------------------------------------- errors */

    /// @notice A required address argument was the zero address.
    error ZeroAddress();

    /// @notice A required amount argument was zero.
    error ZeroAmount();

    /// @notice The graduation threshold was zero or larger than the target raise.
    error InvalidThreshold();

    /// @notice The LP fee tier was not a valid Uniswap v4 fee.
    error InvalidFeeTier();

    /* -------------------------------------------------------------- constants */

    /// @notice Maximum static Uniswap v4 LP fee, in hundredths of a bip (100%).
    uint24 public constant MAX_LP_FEE = 1_000_000;

    /// @notice Sentinel fee value marking a Uniswap v4 dynamic-fee pool.
    uint24 public constant DYNAMIC_FEE_FLAG = 0x800000;

    /* ------------------------------------------------------------- immutables */

    address private immutable _HOOD_TOKEN;
    address private immutable _RESERVE_TOKEN;
    address private immutable _CURVE;
    uint256 private immutable _TARGET_RAISE;
    uint256 private immutable _GRADUATION_THRESHOLD;
    uint24 private immutable _LP_FEE_TIER;
    address private immutable _LOCK_BENEFICIARY;
    uint64 private immutable _LAUNCH_TIMESTAMP;

    /* ----------------------------------------------------------------- events */

    /// @notice Emitted exactly once, at deployment, with the full launch record.
    event LaunchConfigured(
        address indexed hoodzToken,
        address indexed reserveToken,
        address indexed curve,
        uint256 targetRaise,
        uint256 graduationThreshold,
        uint24 lpFeeTier,
        address lockBeneficiary,
        uint64 launchTimestamp
    );

    /* ------------------------------------------------------------ constructor */

    /// @param hoodzToken_ The HOOD ERC20 being launched. Must be a clean, permissionless ERC20.
    /// @param reserveToken_ The quote asset collected by the bonding curve.
    /// @param curve_ The PONS bonding curve escrow for this launch.
    /// @param targetRaise_ Total reserve the curve is sized to collect.
    /// @param graduationThreshold_ Reserve balance at which the curve becomes graduatable. `0 < x <= targetRaise_`.
    /// @param lpFeeTier_ Fee tier of the graduated pool, in hundredths of a bip, or {DYNAMIC_FEE_FLAG}.
    /// @param lockBeneficiary_ Address entitled to the locked LP position's trading fees.
    /// @param launchTimestamp_ Unix timestamp the curve went live; pass `0` to stamp deployment time.
    constructor(
        address hoodzToken_,
        address reserveToken_,
        address curve_,
        uint256 targetRaise_,
        uint256 graduationThreshold_,
        uint24 lpFeeTier_,
        address lockBeneficiary_,
        uint64 launchTimestamp_
    ) {
        if (
            hoodzToken_ == address(0) || reserveToken_ == address(0) || curve_ == address(0)
                || lockBeneficiary_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (targetRaise_ == 0) revert ZeroAmount();
        if (graduationThreshold_ == 0 || graduationThreshold_ > targetRaise_) revert InvalidThreshold();
        if (lpFeeTier_ == 0 || (lpFeeTier_ > MAX_LP_FEE && lpFeeTier_ != DYNAMIC_FEE_FLAG)) revert InvalidFeeTier();

        uint64 stamp = launchTimestamp_ == 0 ? uint64(block.timestamp) : launchTimestamp_;

        _HOOD_TOKEN = hoodzToken_;
        _RESERVE_TOKEN = reserveToken_;
        _CURVE = curve_;
        _TARGET_RAISE = targetRaise_;
        _GRADUATION_THRESHOLD = graduationThreshold_;
        _LP_FEE_TIER = lpFeeTier_;
        _LOCK_BENEFICIARY = lockBeneficiary_;
        _LAUNCH_TIMESTAMP = stamp;

        emit LaunchConfigured(
            hoodzToken_,
            reserveToken_,
            curve_,
            targetRaise_,
            graduationThreshold_,
            lpFeeTier_,
            lockBeneficiary_,
            stamp
        );
    }

    /* ---------------------------------------------------------------- getters */

    /// @notice The HOOD ERC20 launched through PONS.
    /// @return The HOOD token address.
    function hoodzToken() external view returns (address) {
        return _HOOD_TOKEN;
    }

    /// @notice The quote asset the bonding curve collected.
    /// @return The reserve token address.
    function reserveToken() external view returns (address) {
        return _RESERVE_TOKEN;
    }

    /// @notice The PONS bonding curve escrow for this launch.
    /// @return The curve address.
    function curve() external view returns (address) {
        return _CURVE;
    }

    /// @notice Total reserve the curve was sized to collect across its whole range.
    /// @return The target raise, in reserve token decimals.
    function targetRaise() external view returns (uint256) {
        return _TARGET_RAISE;
    }

    /// @notice Reserve balance at which the curve becomes graduatable.
    /// @return The graduation threshold, in reserve token decimals.
    function graduationThreshold() external view returns (uint256) {
        return _GRADUATION_THRESHOLD;
    }

    /// @notice Fee tier of the graduated Uniswap v4 pool.
    /// @return The LP fee, in hundredths of a bip, or {DYNAMIC_FEE_FLAG}.
    function lpFeeTier() external view returns (uint24) {
        return _LP_FEE_TIER;
    }

    /// @notice Address entitled to the locked LP position's trading fees.
    /// @dev Fees only. The locked principal is withdrawable by nobody, this address included.
    /// @return The lock beneficiary.
    function lockBeneficiary() external view returns (address) {
        return _LOCK_BENEFICIARY;
    }

    /// @notice Unix timestamp the curve went live.
    /// @return The launch timestamp.
    function launchTimestamp() external view returns (uint64) {
        return _LAUNCH_TIMESTAMP;
    }

    /// @notice The whole launch record in one call.
    /// @return The populated {LaunchManifest}.
    function manifest() external view returns (LaunchManifest memory) {
        return LaunchManifest({
            hoodzToken: _HOOD_TOKEN,
            reserveToken: _RESERVE_TOKEN,
            curve: _CURVE,
            targetRaise: _TARGET_RAISE,
            graduationThreshold: _GRADUATION_THRESHOLD,
            lpFeeTier: _LP_FEE_TIER,
            lockBeneficiary: _LOCK_BENEFICIARY,
            launchTimestamp: _LAUNCH_TIMESTAMP
        });
    }
}
