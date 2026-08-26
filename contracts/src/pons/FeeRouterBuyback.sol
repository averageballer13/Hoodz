// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @dev UNAUDITED. Do not use in production without a full audit.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IHOODZ} from "../interfaces/IHOODZ.sol";
import {IHoodzAuthority} from "../interfaces/IHoodzAuthority.sol";
import {HoodzAccessControlled} from "../types/HoodzAccessControlled.sol";
import {IPonsFeeRouter} from "./IPonsFeeRouter.sol";
import {PonsLaunchConfig} from "./PonsLaunchConfig.sol";
import {HoodzBurn} from "../types/HoodzBurn.sol";

/// @notice Minimal swap surface used to buy HOODZ out of the graduated pool.
/// @dev Shaped like the familiar `exactInputSingle`. On Robinhood Chain the graduated PONS pool lives in
///      the Uniswap v4 singleton, so this is the router facade in front of it rather than a v3 router;
///      the fee tier identifies the pool and `sqrtPriceLimitX96 = 0` means "no price limit", leaving
///      `amountOutMinimum` as the only slippage bound.
interface ISwapRouter {
    /// @param tokenIn Asset being sold.
    /// @param tokenOut Asset being bought.
    /// @param fee Fee tier identifying the pool, in hundredths of a bip.
    /// @param recipient Address receiving `tokenOut`.
    /// @param deadline Unix timestamp after which the swap must revert.
    /// @param amountIn Exact amount of `tokenIn` to sell.
    /// @param amountOutMinimum Minimum acceptable `tokenOut`, slippage bound.
    /// @param sqrtPriceLimitX96 Price limit, Q64.96; zero for none.
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swap an exact amount of `tokenIn` for as much `tokenOut` as the pool gives.
    /// @param params The swap parameters, see {ExactInputSingleParams}.
    /// @return amountOut Amount of `tokenOut` delivered to `params.recipient`.
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @title FeeRouterBuyback
/// @author Hoodz
/// @notice Turns Hoodz's share of PONS trading fees into permanently destroyed HOODZ.
/// @dev The graduated pool's LP position is locked forever, so its trading fees are the one cash flow
///      the launch produces in perpetuity. This contract is where Hoodz's slice of that flow lands:
///      it claims the reserve-denominated fee share from the PONS fee router, buys HOODZ back out of the
///      same pool that generated the fees, and burns it. Mirrors PONS's own buyback-and-burn.
///
///      Deliberately narrow. It cannot mint, it holds no privileged role over HOODZ beyond burning what
///      it owns, and the only asset it can spend is whatever reserve has been routed to it. The burn is
///      unconditional: HOODZ that reaches this contract never leaves it.
///
///      Every buyback carries both a caller-supplied `minOut` and a `deadline`, because a keeper
///      transaction that sits in the mempool is a free option for whoever is watching it.
contract FeeRouterBuyback is HoodzAccessControlled {
    using SafeERC20 for IERC20;

    /* ----------------------------------------------------------------- errors */

    /// @notice The transaction was mined after its deadline.
    error DeadlineExpired();

    /// @notice No reserve token on hand to spend, before or after claiming fees.
    error NothingToBuy();

    /// @notice `minOut` was zero. An unbounded buyback is a donation to the first searcher who sees it.
    error ZeroMinOut();

    /// @notice The swap delivered less HOODZ than `minOut`.
    error InsufficientOutput();

    /// @notice A required address argument was the zero address.
    error ZeroAddress();

    /* ------------------------------------------------------------- immutables */

    /// @notice The immutable on-chain record of the HOODZ launch.
    PonsLaunchConfig public immutable CONFIG;

    /// @notice The HOODZ token bought back and burned.
    IHOODZ public immutable HOODZ;

    /// @notice The reserve token the protocol fee share is paid in.
    IERC20 public immutable RESERVE;

    /// @notice The PONS fee router that pays out the protocol fee share.
    IPonsFeeRouter public immutable FEE_ROUTER;

    /// @notice The router used to buy HOODZ out of the graduated pool.
    ISwapRouter public immutable SWAP_ROUTER;

    /// @notice Fee tier identifying the graduated pool, read from {CONFIG}.
    uint24 public immutable LP_FEE_TIER;

    /* ------------------------------------------------------------------ state */

    /// @notice Cumulative HOODZ destroyed by this contract, in HOODZ decimals.
    uint256 public totalBurned;

    /* ----------------------------------------------------------------- events */

    /// @notice Emitted on every completed buyback.
    /// @param reserveIn Reserve token spent.
    /// @param hoodzBurned HOODZ destroyed.
    event BuybackAndBurn(uint256 reserveIn, uint256 hoodzBurned);

    /// @notice Emitted when fees are pulled in from the PONS fee router.
    event ProtocolFeesClaimed(uint256 amount);

    /// @notice Emitted when the fee router is pointed at this contract.
    event FeeRouterAimed(address indexed feeRouter);

    /* ------------------------------------------------------------ constructor */

    /// @param authority_ The `HoodzAuthority` granting the policy role that may trigger buybacks.
    /// @param config_ The immutable {PonsLaunchConfig}; supplies HOODZ, the reserve token and the fee tier.
    /// @param feeRouter_ The PONS fee router paying out the protocol fee share.
    /// @param swapRouter_ The router used to buy HOODZ out of the graduated pool.
    constructor(
        IHoodzAuthority authority_,
        PonsLaunchConfig config_,
        IPonsFeeRouter feeRouter_,
        ISwapRouter swapRouter_
    ) HoodzAccessControlled(authority_) {
        if (
            address(authority_) == address(0) || address(config_) == address(0) || address(feeRouter_) == address(0)
                || address(swapRouter_) == address(0)
        ) {
            revert ZeroAddress();
        }

        address hoodz_ = config_.hoodzToken();
        address reserve_ = config_.reserveToken();
        if (hoodz_ == address(0) || reserve_ == address(0)) revert ZeroAddress();

        CONFIG = config_;
        HOODZ = IHOODZ(hoodz_);
        RESERVE = IERC20(reserve_);
        FEE_ROUTER = feeRouter_;
        SWAP_ROUTER = swapRouter_;
        LP_FEE_TIER = config_.lpFeeTier();
    }

    /* -------------------------------------------------------------- buy /burn */

    /// @notice Claim accrued fees, buy HOODZ with every reserve token on hand, and burn all of it.
    /// @dev Policy only. Claiming is best-effort - a fee router that reverts because nothing has accrued
    ///      must not strand reserve that is already sitting here. The swap is bounded by both `minOut`
    ///      and `deadline`, and the HOODZ actually received is measured from balances rather than taken
    ///      from the router's return value.
    /// @param minOut Minimum HOODZ the swap must deliver. Must be non-zero.
    /// @param deadline Unix timestamp after which this call reverts.
    /// @return reserveIn Reserve token spent on the buyback.
    /// @return hoodzBurned HOODZ destroyed, including any HOODZ that was already sitting in this contract.
    function buybackAndBurn(uint256 minOut, uint256 deadline)
        external
        onlyPolicy
        returns (uint256 reserveIn, uint256 hoodzBurned)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (minOut == 0) revert ZeroMinOut();

        _claim();

        reserveIn = RESERVE.balanceOf(address(this));
        if (reserveIn == 0) revert NothingToBuy();

        uint256 hoodzBefore = HOODZ.balanceOf(address(this));

        RESERVE.forceApprove(address(SWAP_ROUTER), reserveIn);
        uint256 reported = SWAP_ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(RESERVE),
                tokenOut: address(HOODZ),
                fee: LP_FEE_TIER,
                recipient: address(this),
                deadline: deadline,
                amountIn: reserveIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        // Leave no standing allowance behind, even if the router spent less than it was given.
        RESERVE.forceApprove(address(SWAP_ROUTER), 0);

        uint256 received = HOODZ.balanceOf(address(this)) - hoodzBefore;
        if (received < minOut || reported < minOut) revert InsufficientOutput();

        hoodzBurned = hoodzBefore + received;
        totalBurned += hoodzBurned;

        HoodzBurn.burn(IERC20(address(HOODZ)), hoodzBurned);

        emit BuybackAndBurn(reserveIn, hoodzBurned);
    }

    /// @notice Pull the accrued protocol fee share in from the PONS fee router.
    /// @dev Permissionless: it can only move fees to the address they were already destined for.
    /// @return claimed Reserve token pulled in, zero if the router had nothing or reverted.
    function claim() external returns (uint256 claimed) {
        claimed = _claim();
    }

    /* ------------------------------------------------------------- governance */

    /// @notice Point the PONS fee router's payouts at this contract.
    /// @dev Governor only, and only effective if this contract is the launch's registered fee owner on
    ///      the PONS side. Normally called once, right after graduation.
    function pointFeesHere() external onlyGovernor {
        FEE_ROUTER.setFeeRecipient(address(this));
        emit FeeRouterAimed(address(FEE_ROUTER));
    }

    /* ------------------------------------------------------------------ views */

    /// @notice What a buyback would have to spend right now. For keepers deciding whether to fire.
    /// @return held Reserve token already sitting in this contract.
    /// @return claimable Reserve token accrued at the fee router but not yet pulled in.
    function pendingFees() external view returns (uint256 held, uint256 claimable) {
        held = RESERVE.balanceOf(address(this));
        try FEE_ROUTER.claimableFees(address(HOODZ)) returns (uint256 amount) {
            claimable = amount;
        } catch {
            claimable = 0;
        }
    }

    /* --------------------------------------------------------------- internal */

    /// @dev Best-effort claim. A reverting or empty fee router is not a reason to fail a buyback that
    ///      already has reserve to spend.
    function _claim() private returns (uint256 claimed) {
        try FEE_ROUTER.claimFees(address(HOODZ)) returns (uint256 amount) {
            claimed = amount;
            if (amount != 0) emit ProtocolFeesClaimed(amount);
        } catch {
            claimed = 0;
        }
    }
}
