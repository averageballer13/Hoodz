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

/// @title IPonsLaunchpad
/// @notice Minimal integration surface for the PONS launchpad on Robinhood Chain (chainId 4663).
/// @dev PONS V2 model: every token starts life on a bonding curve (no instant LP). Once the curve
///      reserves cross the graduation threshold the curve's reserves and the remaining token supply
///      are migrated into a **permanently locked** Uniswap v4 pool. The launchpad is non-custodial:
///      it never holds user funds outside the curve escrow and every trade is signed by the user.
///      Hoodz only *reads* from this contract (plus the one-shot `createToken` at launch); the
///      protocol never assumes it can call privileged launchpad functions.
interface IPonsLaunchpad {
    /// @notice Parameters for a new PONS curve launch.
    /// @param name ERC20 name of the token to launch.
    /// @param symbol ERC20 symbol of the token to launch.
    /// @param token Address of a pre-deployed ERC20 to launch, or `address(0)` to let PONS deploy one.
    /// @param reserveToken ERC20 collected by the bonding curve (the quote asset of the launch).
    /// @param targetRaise Total reserve the curve is sized to collect across its whole range.
    /// @param graduationThreshold Reserve balance at which the curve becomes graduatable.
    /// @param lpFeeTier Fee tier of the graduated Uniswap v4 pool, in hundredths of a bip (3000 = 0.30%).
    /// @param creator Address credited as the launch creator (receives the creator fee share).
    /// @param lockBeneficiary Address credited as the LP fee beneficiary of the locked position.
    /// @param extraData Opaque launchpad-specific payload (curve shape, hook config, metadata URI).
    struct TokenParams {
        string name;
        string symbol;
        address token;
        address reserveToken;
        uint256 targetRaise;
        uint256 graduationThreshold;
        uint24 lpFeeTier;
        address creator;
        address lockBeneficiary;
        bytes extraData;
    }

    /// @notice Emitted by PONS when a token is registered and its bonding curve is deployed.
    event TokenCreated(address indexed token, address indexed curve, address indexed creator, address reserveToken);

    /// @notice Emitted by PONS when a curve graduates into its permanently locked Uniswap v4 pool.
    event Graduated(address indexed token, address indexed curve, address indexed pool, uint256 reserveMigrated);

    /// @notice Launch a token on a fresh PONS bonding curve.
    /// @dev Non-custodial: the caller signs this transaction; the launchpad takes custody of nothing
    ///      beyond the curve escrow it deploys. For HOOD the token is pre-deployed by Hoodz and
    ///      passed in via `params.token`, so that the ERC20 is a clean, permissionless, tax-free token.
    /// @param params The launch parameters, see {TokenParams}.
    /// @return token The launched ERC20.
    /// @return curve The bonding curve escrow that now holds the sellable supply.
    function createToken(TokenParams calldata params) external payable returns (address token, address curve);

    /// @notice Migrate a curve that has crossed its graduation threshold into a locked Uniswap v4 pool.
    /// @dev Permissionless in PONS: anybody may push a fully funded curve over the line. Reverts if the
    ///      curve has not reached `graduationThreshold` or has already graduated.
    /// @param token The launched token whose curve should graduate.
    /// @return pool The graduated Uniswap v4 pool holding the permanently locked liquidity.
    function graduate(address token) external returns (address pool);

    /// @notice Whether a launched token has completed graduation.
    /// @param token The launched token.
    /// @return True once the curve reserves have migrated into the locked v4 pool.
    function isGraduated(address token) external view returns (bool);

    /// @notice The bonding curve escrow deployed for a launched token.
    /// @param token The launched token.
    /// @return The curve address, or `address(0)` if the token was not launched through PONS.
    function curveOf(address token) external view returns (address);

    /// @notice The graduated Uniswap v4 pool for a launched token.
    /// @param token The launched token.
    /// @return The pool address, or `address(0)` before graduation.
    function poolOf(address token) external view returns (address);
}
