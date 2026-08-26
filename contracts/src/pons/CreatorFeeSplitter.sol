// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @dev UNAUDITED. Do not use in production without a full audit.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IHoodzAuthority} from "../interfaces/IHoodzAuthority.sol";
import {IHOODZ} from "../interfaces/IHOODZ.sol";
import {HoodzAccessControlled} from "../types/HoodzAccessControlled.sol";
import {HoodzBurn} from "../types/HoodzBurn.sol";
import {ISwapRouter} from "./FeeRouterBuyback.sol";

/// @notice Minimal wrapped-native interface. Robinhood Chain pays gas - and PONS creator fees - in ETH.
interface IWrappedNative is IERC20 {
    /// @notice Wrap the attached native value 1:1.
    function deposit() external payable;
}

/// @title  CreatorFeeSplitter
/// @author Hoodz
/// @notice The protocol's entire income. Takes PONS creator fees and splits them three ways:
///         staking rewards, a permanent burn, and treasury inventory.
/// @dev    UNAUDITED. Do not use in production without a full audit.
///
///         Why this contract is the whole protocol now:
///
///         HOODZ is deployed by PONS with a fixed 1,000,000,000 supply and no mint function, so
///         Olympus's engine - create tokens from nothing and sell them at a premium - is simply not
///         available. There is exactly one recurring source of value: the creator fee PONS pays on
///         every trade of HOODZ. Point PONS at this address and the fee becomes, automatically and
///         without anyone's discretion:
///
///           * `stakersBps`  swapped to HOODZ and sent to the staking contract. This is what pays
///             the rebase. `HoodzStaking.rebase()` computes `contractBalance - circulatingStaked`
///             and does not care where the surplus came from, so a plain transfer here does exactly
///             what minting used to do - except it is funded by real revenue instead of dilution.
///           * `burnBps`     swapped to HOODZ and sent to the dead address. Circulating supply only
///             ever falls.
///           * `treasuryBps` swapped to HOODZ and sent to the treasury, rebuilding the inventory
///             that bonds and emissions pay out of.
///
///         The yield is therefore honest and bounded: it is fees divided by staked supply, and
///         nothing else. There is no flywheel, and no way to manufacture one.
///
///         Fees arrive as native ETH (PONS pays the creator wallet in the gas token). They are
///         wrapped and swapped in one transaction. `minOut` and `deadline` are caller-supplied on
///         every call, because a keeper transaction sitting in the mempool is a free option for
///         anyone watching it.
contract CreatorFeeSplitter is HoodzAccessControlled {
    using SafeERC20 for IERC20;

    /* ----------------------------------------------------------------- errors */

    /// @notice The transaction was mined after its deadline.
    error DeadlineExpired();
    /// @notice No fees on hand to distribute.
    error NothingToDistribute();
    /// @notice `minOut` was zero. An unbounded swap is a donation to the first searcher who sees it.
    error ZeroMinOut();
    /// @notice The swap delivered less HOODZ than `minOut`.
    error InsufficientOutput(uint256 received, uint256 minOut);
    /// @notice The three shares must add up to exactly 10_000 basis points.
    error SharesMustSumToOne(uint256 got);
    /// @notice A required address argument was the zero address.
    error ZeroAddress();
    /// @notice Native value was sent by an address other than the wrapped-native contract.
    error DirectTransferNotAccepted();

    /* --------------------------------------------------------------- constants */

    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;

    /* -------------------------------------------------------------- immutables */

    /// @notice The HOODZ token bought with fee income.
    IHOODZ public immutable HOODZ;
    /// @notice Wrapped native, the swap's input leg.
    IWrappedNative public immutable WRAPPED_NATIVE;
    /// @notice Router used to buy HOODZ out of the graduated PONS pool.
    ISwapRouter public immutable SWAP_ROUTER;
    /// @notice Fee tier identifying the graduated pool.
    uint24 public immutable LP_FEE_TIER;
    /// @notice The staking contract whose balance the rebase reads.
    address public immutable STAKING;
    /// @notice The Hoodz treasury.
    address public immutable TREASURY;

    /* ------------------------------------------------------------------ state */

    /// @notice Share of each distribution routed to stakers, in basis points.
    uint256 public stakersBps;
    /// @notice Share burned, in basis points.
    uint256 public burnBps;
    /// @notice Share sent to the treasury as inventory, in basis points.
    uint256 public treasuryBps;

    /// @notice Cumulative native value distributed.
    uint256 public totalNativeIn;
    /// @notice Cumulative HOODZ sent to stakers.
    uint256 public totalToStakers;
    /// @notice Cumulative HOODZ burned.
    uint256 public totalBurned;
    /// @notice Cumulative HOODZ sent to the treasury.
    uint256 public totalToTreasury;

    /* ----------------------------------------------------------------- events */

    /// @notice A fee distribution completed.
    /// @param nativeIn   Native value spent.
    /// @param hoodzOut   HOODZ bought.
    /// @param toStakers  HOODZ sent to staking.
    /// @param burned     HOODZ burned.
    /// @param toTreasury HOODZ sent to the treasury.
    event FeesDistributed(
        uint256 nativeIn, uint256 hoodzOut, uint256 toStakers, uint256 burned, uint256 toTreasury
    );

    /// @notice The split was changed.
    event SplitUpdated(uint256 stakersBps, uint256 burnBps, uint256 treasuryBps);

    /// @notice Native value arrived from PONS (or anyone else).
    event FeesReceived(address indexed from, uint256 amount);

    /* ------------------------------------------------------------ constructor */

    /// @param authority_      Authority granting the policy and governor roles.
    /// @param hoodz_          The HOODZ token, as deployed by PONS.
    /// @param wrappedNative_  Wrapped native token used as the swap input.
    /// @param swapRouter_     Router for the graduated pool.
    /// @param lpFeeTier_      Fee tier of the graduated pool.
    /// @param staking_        HoodzStaking; receives the stakers' share.
    /// @param treasury_       HoodzTreasury; receives the inventory share.
    /// @param stakersBps_     Initial stakers share.
    /// @param burnBps_        Initial burn share.
    /// @param treasuryBps_    Initial treasury share.
    constructor(
        IHoodzAuthority authority_,
        IHOODZ hoodz_,
        IWrappedNative wrappedNative_,
        ISwapRouter swapRouter_,
        uint24 lpFeeTier_,
        address staking_,
        address treasury_,
        uint256 stakersBps_,
        uint256 burnBps_,
        uint256 treasuryBps_
    ) HoodzAccessControlled(authority_) {
        if (
            address(hoodz_) == address(0) || address(wrappedNative_) == address(0)
                || address(swapRouter_) == address(0) || staking_ == address(0) || treasury_ == address(0)
        ) revert ZeroAddress();

        HOODZ = hoodz_;
        WRAPPED_NATIVE = wrappedNative_;
        SWAP_ROUTER = swapRouter_;
        LP_FEE_TIER = lpFeeTier_;
        STAKING = staking_;
        TREASURY = treasury_;

        _setSplit(stakersBps_, burnBps_, treasuryBps_);
    }

    /* -------------------------------------------------------------- receiving */

    /// @notice Accept PONS creator fees, paid in the native gas token.
    /// @dev Deliberately does nothing but record. Swapping inside `receive` would put a swap in the
    ///      middle of whatever call PONS is making and hand the gas cost - and the slippage choice -
    ///      to whoever happened to trade. Distribution is a separate, explicitly-priced call.
    receive() external payable {
        emit FeesReceived(msg.sender, msg.value);
    }

    /* ------------------------------------------------------------ distribute */

    /// @notice Convert everything on hand into HOODZ and split it.
    /// @dev Permissionless: anyone may run it, nobody can misdirect it. The destinations are
    ///      immutable and the split is governor-set, so the only thing a caller controls is when it
    ///      happens and what slippage they are willing to accept.
    /// @param minOut   Minimum HOODZ out of the swap. Must be non-zero.
    /// @param deadline Latest timestamp this may execute.
    /// @return hoodzOut Total HOODZ bought.
    function distribute(uint256 minOut, uint256 deadline) external returns (uint256 hoodzOut) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (minOut == 0) revert ZeroMinOut();

        uint256 nativeIn = address(this).balance;
        if (nativeIn == 0) revert NothingToDistribute();

        // wrap, then buy HOODZ out of the graduated pool
        WRAPPED_NATIVE.deposit{value: nativeIn}();
        IERC20(address(WRAPPED_NATIVE)).forceApprove(address(SWAP_ROUTER), nativeIn);

        hoodzOut = SWAP_ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(WRAPPED_NATIVE),
                tokenOut: address(HOODZ),
                fee: LP_FEE_TIER,
                recipient: address(this),
                deadline: deadline,
                amountIn: nativeIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        if (hoodzOut < minOut) revert InsufficientOutput(hoodzOut, minOut);

        // Split the realised HOODZ, not the notional: the treasury leg takes the remainder so
        // rounding dust can never strand a wei in this contract.
        uint256 toStakers = (hoodzOut * stakersBps) / BPS;
        uint256 toBurn = (hoodzOut * burnBps) / BPS;
        uint256 toTreasury = hoodzOut - toStakers - toBurn;

        totalNativeIn += nativeIn;
        totalToStakers += toStakers;
        totalBurned += toBurn;
        totalToTreasury += toTreasury;

        // Stakers' share goes straight into the staking contract's balance. rebase() reads
        // `contractBalance - circulatingStaked`, so this becomes the epoch's distribution with no
        // further wiring - the same slot minting used to fill.
        if (toStakers != 0) IERC20(address(HOODZ)).safeTransfer(STAKING, toStakers);
        HoodzBurn.burn(IERC20(address(HOODZ)), toBurn);
        if (toTreasury != 0) IERC20(address(HOODZ)).safeTransfer(TREASURY, toTreasury);

        emit FeesDistributed(nativeIn, hoodzOut, toStakers, toBurn, toTreasury);
    }

    /* ----------------------------------------------------------------- admin */

    /// @notice Change how each distribution is split.
    /// @dev Governor only. Takes effect on the next {distribute}; it never touches past flows.
    /// @param stakersBps_  New stakers share.
    /// @param burnBps_     New burn share.
    /// @param treasuryBps_ New treasury share.
    function setSplit(uint256 stakersBps_, uint256 burnBps_, uint256 treasuryBps_) external onlyGovernor {
        _setSplit(stakersBps_, burnBps_, treasuryBps_);
    }

    /// @dev Enforces the invariant in one place so no caller can leave the shares inconsistent.
    function _setSplit(uint256 stakersBps_, uint256 burnBps_, uint256 treasuryBps_) private {
        uint256 sum = stakersBps_ + burnBps_ + treasuryBps_;
        if (sum != BPS) revert SharesMustSumToOne(sum);

        stakersBps = stakersBps_;
        burnBps = burnBps_;
        treasuryBps = treasuryBps_;

        emit SplitUpdated(stakersBps_, burnBps_, treasuryBps_);
    }

    /* ----------------------------------------------------------------- views */

    /// @notice Native value waiting to be distributed.
    /// @return The contract's native balance.
    function pending() external view returns (uint256) {
        return address(this).balance;
    }
}
