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

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IBondingCalculator} from "./interfaces/IBondingCalculator.sol";
import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";

/// @notice Thrown when the constructor is handed the zero address for HOOD.
error HoodzBondingCalculator_ZeroAddress();
/// @notice Thrown when a pair is valued that does not contain HOOD on either side.
error HoodzBondingCalculator_InvalidPair();
/// @notice Thrown when an LP token reports a zero total supply, making a share undefined.
error HoodzBondingCalculator_ZeroSupply();
/// @notice Thrown when a pair holds no liquidity, making its markdown undefined.
error HoodzBondingCalculator_ZeroLiquidity();
/// @notice Thrown when a fixed-point fraction does not fit in the UQ112x112 range.
error HoodzBondingCalculator_FixedPointOverflow();

/// @title Hoodz Bonding Calculator
/// @author Hoodz
/// @notice Prices constant-product LP tokens for the Hoodz Treasury using the risk-free
///         `2 * sqrt(k)` valuation, so a liquidity bond can never be gamed by moving the
///         pool price: only the invariant `k` (i.e. real liquidity added) increases value.
/// @dev Faithful port of `OlympusBondingCalculator`. The Babylonian square root and the
///      UQ112x112 fixed-point fraction of the original are reproduced with OpenZeppelin's
///      `Math.sqrt` / `Math.mulDiv` and the local {fractionDecode112with18} helper, which are
///      arithmetically equivalent but overflow-safe under Solidity 0.8 checked math.
contract HoodzBondingCalculator is IBondingCalculator {
    // ========= CONSTANTS ========= //

    /// @notice Decimals of the HOOD token. Fixed at 9 for Olympus parity; every valuation
    ///         returned by this contract is denominated in these units.
    uint256 internal constant HOOD_DECIMALS = 9;

    /// @dev UQ112x112 scaling factor, `2**112`.
    uint256 internal constant Q112 = 2 ** 112;

    /// @dev `floor(2**112 / 1e18)` — the divisor Uniswap's `decode112with18` uses to turn a
    ///      UQ112x112 value into an 18-decimal fixed point number.
    uint256 internal constant DECODE_112_WITH_18 = 5_192_296_858_534_827;

    // ========= STATE ========= //

    /// @notice The HOOD token this calculator marks liquidity against.
    address public immutable HOOD;

    // ========= CONSTRUCTOR ========= //

    /// @param _hoodz Address of the HOOD token.
    constructor(address _hoodz) {
        if (_hoodz == address(0)) revert HoodzBondingCalculator_ZeroAddress();
        HOOD = _hoodz;
    }

    // ========= VIEWS ========= //

    /// @notice Constant-product invariant `k = reserve0 * reserve1` of a pair, normalised so
    ///         that it is expressed in the same fixed-point scale as one LP share.
    /// @dev `decimals = token0.decimals + token1.decimals - pair.decimals`; dividing the raw
    ///      product by `10 ** decimals` makes `sqrt(k)` directly comparable to LP supply.
    /// @param _pair Address of the constant-product LP token.
    /// @return k_ The normalised invariant.
    function getKValue(address _pair) public view returns (uint256 k_) {
        uint256 decimals0 = IERC20Metadata(IUniswapV2Pair(_pair).token0()).decimals();
        uint256 decimals1 = IERC20Metadata(IUniswapV2Pair(_pair).token1()).decimals();
        uint256 decimalsPair = IUniswapV2Pair(_pair).decimals();
        uint256 decimals = decimals0 + decimals1 - decimalsPair;

        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(_pair).getReserves();

        // Both reserves are uint112, so the product always fits in uint224.
        k_ = (uint256(reserve0) * uint256(reserve1)) / (10 ** decimals);
    }

    /// @notice Risk-free value of the entire pool, `2 * sqrt(k)`.
    /// @dev This is the amount an attacker cannot inflate by trading: it only rises when real
    ///      liquidity is deposited on both sides.
    /// @param _pair Address of the constant-product LP token.
    /// @return value_ Total risk-free value of the pool.
    function getTotalValue(address _pair) public view returns (uint256 value_) {
        value_ = Math.sqrt(getKValue(_pair)) * 2;
    }

    /// @inheritdoc IBondingCalculator
    function valuation(address pair_, uint256 amount_) external view override returns (uint256 value_) {
        uint256 totalValue = getTotalValue(pair_);
        uint256 totalSupply = IUniswapV2Pair(pair_).totalSupply();
        if (totalSupply == 0) revert HoodzBondingCalculator_ZeroSupply();

        value_ = Math.mulDiv(totalValue, fractionDecode112with18(amount_, totalSupply), 1e18);
    }

    /// @inheritdoc IBondingCalculator
    /// @dev Returns `2 * reserveOfNonHoodzSide * 10**9 / getTotalValue(pair)`. For a balanced
    ///      pool this equals the marginal price of HOOD in the paired asset, which the treasury
    ///      uses to mark an LP position down from its spot value to its defensible value.
    function markdown(address _LP) external view override returns (uint256) {
        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(_LP).getReserves();

        uint256 reserve;
        if (IUniswapV2Pair(_LP).token0() == HOOD) {
            reserve = uint256(reserve1);
        } else {
            if (IUniswapV2Pair(_LP).token1() != HOOD) revert HoodzBondingCalculator_InvalidPair();
            reserve = uint256(reserve0);
        }

        uint256 totalValue = getTotalValue(_LP);
        if (totalValue == 0) revert HoodzBondingCalculator_ZeroLiquidity();

        return Math.mulDiv(reserve, 2 * (10 ** HOOD_DECIMALS), totalValue);
    }

    // ========= FIXED POINT ========= //

    /// @notice `numerator / denominator` as an 18-decimal fixed point number, computed through
    ///         a UQ112x112 intermediate exactly like Uniswap's `FixedPoint.fraction(...)
    ///         .decode112with18()` that Olympus relied on.
    /// @param numerator Fraction numerator.
    /// @param denominator Fraction denominator; must be non-zero.
    /// @return The quotient scaled by 1e18.
    function fractionDecode112with18(uint256 numerator, uint256 denominator) public pure returns (uint256) {
        if (denominator == 0) revert HoodzBondingCalculator_ZeroSupply();
        if (numerator == 0) return 0;

        uint256 encoded = Math.mulDiv(numerator, Q112, denominator);
        if (encoded > type(uint224).max) revert HoodzBondingCalculator_FixedPointOverflow();

        return encoded / DECODE_112_WITH_18;
    }
}
