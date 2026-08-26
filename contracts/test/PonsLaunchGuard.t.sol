// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @dev UNAUDITED. Do not use in production without a full audit.

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HoodzAuthority} from "../src/HoodzAuthority.sol";
import {HoodzTreasury} from "../src/HoodzTreasury.sol";
import {IHoodzAuthority} from "../src/interfaces/IHoodzAuthority.sol";
import {MockPonsToken} from "./mocks/MockPonsToken.sol";

import {PonsLaunchConfig} from "../src/pons/PonsLaunchConfig.sol";
import {HoodzLaunchGuard} from "../src/pons/HoodzLaunchGuard.sol";
import {FeeRouterBuyback, ISwapRouter} from "../src/pons/FeeRouterBuyback.sol";
import {IPonsLaunchpad} from "../src/pons/IPonsLaunchpad.sol";
import {IPonsFeeRouter} from "../src/pons/IPonsFeeRouter.sol";
import {IPositionLocker} from "../src/pons/IPositionLocker.sol";
import {IUniswapV4PoolManager, PoolKey, PonsPoolId} from "../src/pons/IUniswapV4PoolManager.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {
    MockPonsBondingCurve,
    MockPonsLaunchpad,
    MockPositionLocker,
    MockUniswapV4PoolManager,
    MockPonsFeeRouter
} from "./mocks/MockPonsLaunchpad.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";

/// @title  PonsLaunchGuardTest
/// @notice The one thing §4 of the brief makes non-negotiable: the protocol must not be able to
///         mint HOODZ while HOODZ is still price-discovering on the PONS curve. The guard holds
///         the vault role - and has no mint function - so supply is frozen until all three
///         release conditions hold at once: the curve graduated, the LP position is locked with
///         no unlock path, and a governor-signed arm is at least `TRANSFER_DELAY` old.
/// @dev    DEPLOYMENT NOTE, and the reason for the `vm.prank(address(guard))` calls below:
///         `releaseToTreasury()` is `onlyGovernor` *and* itself calls `authority.pushVault`,
///         which is also `onlyGovernor`. Both conditions can only hold simultaneously if
///         `authority.governor() == address(guard)` and the guard is the caller. These tests set
///         that up explicitly; a real deployment needs an equivalent arrangement (or the guard
///         needs a caller other than the governor) before the handoff can execute on-chain.
contract PonsLaunchGuardTest is Test {
    HoodzAuthority internal authority;
    MockPonsToken internal hoodz;
    HoodzTreasury internal treasury;
    MockERC20 internal reserve;

    PonsLaunchConfig internal config;
    HoodzLaunchGuard internal guard;
    FeeRouterBuyback internal buyback;

    MockPonsBondingCurve internal curve;
    MockPonsLaunchpad internal launchpad;
    MockPositionLocker internal locker;
    MockUniswapV4PoolManager internal poolManager;
    MockPonsFeeRouter internal feeRouter;
    MockSwapRouter internal swapRouter;

    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");
    address internal lockBeneficiary = makeAddr("lockBeneficiary");
    address internal pool = makeAddr("graduatedPool");

    PoolKey internal key;
    bytes32 internal poolId;

    uint256 internal constant TARGET_RAISE = 1_000_000e18;
    uint256 internal constant GRADUATION_THRESHOLD = 600_000e18;
    uint24 internal constant LP_FEE_TIER = 3000;
    uint128 internal constant LOCKED_LIQUIDITY = 42_000e18;

    /// @dev HOODZ escrowed on the curve before the guard takes the vault role. After that, this
    ///      is the entire supply until graduation - the guard cannot mint another unit.
    uint256 internal constant CURVE_SUPPLY = 1_000_000e9;

    function setUp() public {
        vm.warp(1_700_000_000);

        // The test contract starts as governor, policy and vault so it can wire everything.
        authority = new HoodzAuthority(address(this), guardian, address(this), address(this));
        IHoodzAuthority auth = IHoodzAuthority(address(authority));

        hoodz = new MockPonsToken("Hoodz", "HOODZ", 9, address(this));
        treasury = new HoodzTreasury(address(hoodz), 0, address(authority));
        reserve = new MockERC20("Mock Reserve", "mRSV", 18);

        curve = new MockPonsBondingCurve(address(hoodz), address(reserve), GRADUATION_THRESHOLD);
        launchpad = new MockPonsLaunchpad();
        locker = new MockPositionLocker();
        poolManager = new MockUniswapV4PoolManager();
        feeRouter = new MockPonsFeeRouter(IERC20(address(reserve)));
        swapRouter = new MockSwapRouter();

        launchpad.register(address(hoodz), address(curve), pool);

        config = new PonsLaunchConfig(
            address(hoodz),
            address(reserve),
            address(curve),
            TARGET_RAISE,
            GRADUATION_THRESHOLD,
            LP_FEE_TIER,
            lockBeneficiary,
            0
        );

        guard = new HoodzLaunchGuard(
            auth,
            config,
            IPonsLaunchpad(address(launchpad)),
            IPositionLocker(address(locker)),
            IUniswapV4PoolManager(address(poolManager)),
            address(treasury)
        );

        buyback = new FeeRouterBuyback(
            auth, config, IPonsFeeRouter(address(feeRouter)), ISwapRouter(address(swapRouter))
        );

        // The v4 pool key the graduated position will be minted against.
        (address c0, address c1) =
            address(hoodz) < address(reserve) ? (address(hoodz), address(reserve)) : (address(reserve), address(hoodz));
        key = PoolKey({currency0: c0, currency1: c1, fee: LP_FEE_TIER, tickSpacing: int24(60), hooks: address(0)});
        poolId = PonsPoolId.toId(key);

        // Mint the supply that goes onto the curve, while the test still holds the vault role,
        // and seed the swap router so a buyback has HOODZ to deliver.
        hoodz.mint(address(swapRouter), CURVE_SUPPLY);

        // Hand the vault role to the guard: from here HOODZ supply is frozen.
        authority.pushVault(address(guard), true);

        // The guard must also be the governor, because `releaseToTreasury` pushes the vault role.
        authority.pushGovernor(address(guard), true);

        vm.label(address(guard), "HoodzLaunchGuard");
        vm.label(address(config), "PonsLaunchConfig");
        vm.label(address(buyback), "FeeRouterBuyback");
    }

    /*//////////////////////////////////////////////////////////////
                              LAUNCH RECORD
    //////////////////////////////////////////////////////////////*/

    function test_LaunchConfigIsTheImmutableRecord() public view {
        assertEq(config.hoodzToken(), address(hoodz));
        assertEq(config.reserveToken(), address(reserve));
        assertEq(config.curve(), address(curve));
        assertEq(config.targetRaise(), TARGET_RAISE);
        assertEq(config.graduationThreshold(), GRADUATION_THRESHOLD);
        assertEq(config.lpFeeTier(), LP_FEE_TIER);
        assertEq(config.lockBeneficiary(), lockBeneficiary);
        assertEq(config.launchTimestamp(), uint64(block.timestamp), "a zero timestamp stamps deployment time");
    }

    function test_RevertWhen_ThresholdExceedsTargetRaise() public {
        vm.expectRevert(); // InvalidThreshold
        new PonsLaunchConfig(
            address(hoodz),
            address(reserve),
            address(curve),
            TARGET_RAISE,
            TARGET_RAISE + 1,
            LP_FEE_TIER,
            lockBeneficiary,
            0
        );
    }

    /*//////////////////////////////////////////////////////////////
                             SUPPLY IS FROZEN
    //////////////////////////////////////////////////////////////*/

    /// @dev The guard holds the vault role and exposes no mint function, so between deployment
    ///      and graduation the HOODZ supply cannot move at all.
    function test_GuardHoldsTheVaultAndFreezesSupply() public {
        assertTrue(guard.holdsVaultRole(), "the guard must hold the vault role");
        assertEq(authority.vault(), address(guard));
        assertEq(hoodz.totalSupply(), CURVE_SUPPLY, "supply is exactly what went onto the curve");

        vm.expectRevert(); // the test contract is no longer the vault
        hoodz.mint(alice, 1);

        vm.prank(address(treasury));
        vm.expectRevert(); // and neither is the treasury, yet
        hoodz.mint(alice, 1);

        assertEq(hoodz.totalSupply(), CURVE_SUPPLY, "supply unchanged");
    }

    /*//////////////////////////////////////////////////////////////
                          GRADUATION VERIFICATION
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_VerifyingBeforeGraduation() public {
        vm.expectRevert(HoodzLaunchGuard.NotGraduated.selector);
        guard.verifyGraduation();
    }

    function test_RevertWhen_VerifyingWithAnUnlockedPosition() public {
        _graduate();
        // Graduated, but nothing was ever locked.
        vm.expectRevert(HoodzLaunchGuard.LpNotLocked.selector);
        guard.verifyGraduation();
    }

    function test_VerifyGraduationRecordsThePool() public {
        _graduateAndLock();

        address verified = guard.verifyGraduation();

        assertEq(verified, pool, "the graduated pool is recorded");
        assertEq(guard.verifiedPool(), pool);
        assertTrue(guard.graduationVerified());
    }

    /// @dev Every branch of the lock check has to fail closed. A position that can be unwound,
    ///      one that holds no liquidity, and one whose pool id does not hash from its own key are
    ///      all ways a "locked" LP could be faked.
    function test_RevertWhen_PositionIsUnlockable() public {
        _graduateAndLock();
        locker.setUnlockable(address(hoodz), true, block.timestamp + 1 days);

        vm.expectRevert(HoodzLaunchGuard.LpNotLocked.selector);
        guard.verifyGraduation();
    }

    function test_RevertWhen_PositionHoldsNoLiquidity() public {
        _graduateAndLock();
        locker.setLiquidity(address(hoodz), 0);

        vm.expectRevert(HoodzLaunchGuard.LpNotLocked.selector);
        guard.verifyGraduation();
    }

    function test_RevertWhen_PoolIdIsSpoofed() public {
        _graduateAndLock();
        locker.setPoolId(address(hoodz), keccak256("not the key"));

        vm.expectRevert(HoodzLaunchGuard.LpNotLocked.selector);
        guard.verifyGraduation();
    }

    /// @dev The v4 singleton is the independent cross-check: a locker claiming liquidity the
    ///      pool manager does not report must not be believed.
    function test_RevertWhen_PoolManagerReportsNoLiquidity() public {
        _graduateAndLock();
        poolManager.setLiquidity(poolId, 0);

        vm.expectRevert(HoodzLaunchGuard.LpNotLocked.selector);
        guard.verifyGraduation();
    }

    /// @dev A launchpad that reverts must read as "not graduated", never as "graduated".
    function test_FailsClosedWhenTheLaunchpadReverts() public {
        _graduateAndLock();
        launchpad.setReverting(true);

        vm.expectRevert(HoodzLaunchGuard.NotGraduated.selector);
        guard.verifyGraduation();
    }

    /*//////////////////////////////////////////////////////////////
                        RELEASE PRECONDITIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev The headline requirement: mint authority cannot move before graduation.
    function test_RevertWhen_ReleasingBeforeGraduation() public {
        vm.prank(address(guard));
        guard.arm();

        vm.warp(block.timestamp + guard.TRANSFER_DELAY());

        vm.prank(address(guard));
        vm.expectRevert(HoodzLaunchGuard.NotGraduated.selector);
        guard.releaseToTreasury();

        assertEq(authority.vault(), address(guard), "the vault role must not have moved");
    }

    function test_RevertWhen_ReleasingWithoutArming() public {
        _graduateAndLock();
        guard.verifyGraduation();

        vm.prank(address(guard));
        vm.expectRevert(HoodzLaunchGuard.NotArmed.selector);
        guard.releaseToTreasury();
    }

    /// @dev The second headline requirement: mint authority cannot move before the delay.
    function test_RevertWhen_ReleasingBeforeTheDelayElapses() public {
        _graduateAndLock();
        guard.verifyGraduation();

        vm.prank(address(guard));
        guard.arm();

        vm.warp(block.timestamp + guard.TRANSFER_DELAY() - 1);

        assertFalse(guard.canRelease(), "canRelease must agree that it is too early");
        assertEq(guard.secondsUntilRelease(), 1, "one second left on the clock");

        vm.prank(address(guard));
        vm.expectRevert(HoodzLaunchGuard.DelayNotElapsed.selector);
        guard.releaseToTreasury();

        assertEq(authority.vault(), address(guard), "the vault role must not have moved");
    }

    /// @dev Graduation is re-checked live at release time, not merely trusted from the earlier
    ///      snapshot - so a curve that somehow un-graduates still blocks the handoff.
    function test_RevertWhen_GraduationIsRevokedAfterVerification() public {
        _graduateAndLock();
        guard.verifyGraduation();

        vm.prank(address(guard));
        guard.arm();
        vm.warp(block.timestamp + guard.TRANSFER_DELAY());

        launchpad.setGraduated(address(hoodz), false);

        vm.prank(address(guard));
        vm.expectRevert(HoodzLaunchGuard.NotGraduated.selector);
        guard.releaseToTreasury();
    }

    /// @dev The LP lock is re-checked live too.
    function test_RevertWhen_LockIsUndoneAfterVerification() public {
        _graduateAndLock();
        guard.verifyGraduation();

        vm.prank(address(guard));
        guard.arm();
        vm.warp(block.timestamp + guard.TRANSFER_DELAY());

        locker.setUnlockable(address(hoodz), true, block.timestamp + 1);

        vm.prank(address(guard));
        vm.expectRevert(HoodzLaunchGuard.LpNotLocked.selector);
        guard.releaseToTreasury();
    }

    function test_RevertWhen_NonGovernorArms() public {
        vm.prank(alice);
        vm.expectRevert();
        guard.arm();
    }

    /*//////////////////////////////////////////////////////////////
                            SUCCESSFUL RELEASE
    //////////////////////////////////////////////////////////////*/

    function test_ReleaseMovesMintAuthorityToTheTreasury() public {
        _armAndWait();

        assertTrue(guard.canRelease(), "every precondition holds");

        vm.prank(address(guard));
        guard.releaseToTreasury();

        assertTrue(guard.released());
        assertEq(authority.vault(), address(treasury), "the treasury is now the mint authority");
        assertFalse(guard.holdsVaultRole(), "the guard has stepped aside");
    }

    function test_ReleaseIsOneShot() public {
        _armAndWait();

        vm.prank(address(guard));
        guard.releaseToTreasury();

        // Still the governor, still refused: `released` never goes back to false.
        vm.prank(address(guard));
        vm.expectRevert(HoodzLaunchGuard.AlreadyReleased.selector);
        guard.releaseToTreasury();

        assertFalse(guard.canRelease(), "and the status view agrees");
    }

    /// @dev After the handoff the treasury - and only the treasury - can mint.
    function test_TreasuryCanMintOnlyAfterRelease() public {
        _armAndWait();

        vm.prank(address(treasury));
        vm.expectRevert();
        hoodz.mint(alice, 1e9); // still frozen: the guard holds the vault

        vm.prank(address(guard));
        guard.releaseToTreasury();

        vm.prank(address(treasury));
        hoodz.mint(alice, 1e9);

        assertEq(hoodz.balanceOf(alice), 1e9);
        assertEq(hoodz.totalSupply(), CURVE_SUPPLY + 1e9);
    }

    /*//////////////////////////////////////////////////////////////
                             ABORT & RE-ARM
    //////////////////////////////////////////////////////////////*/

    /// @dev The guardian's abort is a speed bump, not a veto: it resets the clock, and the
    ///      governor can re-arm and wait out another full delay.
    function test_GuardianCanAbortAndTheGovernorCanReArm() public {
        _graduateAndLock();
        guard.verifyGraduation();

        vm.prank(address(guard));
        guard.arm();

        vm.prank(guardian);
        guard.abort();

        assertEq(guard.armedAt(), 0, "the clock was reset");
        assertFalse(guard.graduationVerified(), "and the verification was cleared");
        assertEq(guard.releaseEligibleAt(), 0);

        vm.warp(block.timestamp + guard.TRANSFER_DELAY() * 2);

        vm.prank(address(guard));
        vm.expectRevert(HoodzLaunchGuard.NotArmed.selector);
        guard.releaseToTreasury();

        // Re-arm and wait it out again.
        guard.verifyGraduation();
        vm.prank(address(guard));
        guard.arm();
        vm.warp(block.timestamp + guard.TRANSFER_DELAY());

        vm.prank(address(guard));
        guard.releaseToTreasury();

        assertEq(authority.vault(), address(treasury));
    }

    function test_ReArmingRestartsTheDelay() public {
        _graduateAndLock();
        guard.verifyGraduation();

        vm.prank(address(guard));
        guard.arm();
        uint256 firstEligible = guard.releaseEligibleAt();

        vm.warp(block.timestamp + 12 hours);

        vm.prank(address(guard));
        guard.arm();

        assertGt(guard.releaseEligibleAt(), firstEligible, "re-arming restarts the countdown");
    }

    function test_RevertWhen_NonGuardianAborts() public {
        vm.prank(alice);
        vm.expectRevert();
        guard.abort();
    }

    /*//////////////////////////////////////////////////////////////
                             STATUS REPORTING
    //////////////////////////////////////////////////////////////*/

    /// @dev `releaseStatus` is the keeper/dashboard view: it must never revert, whatever state
    ///      the launch is in, and must agree with what the release path actually enforces.
    function test_ReleaseStatusTracksEachPrecondition() public {
        (bool graduated_, bool locked_, bool armed_, bool elapsed_, bool released_) = guard.releaseStatus();
        assertFalse(graduated_);
        assertFalse(locked_);
        assertFalse(armed_);
        assertFalse(elapsed_);
        assertFalse(released_);

        _graduateAndLock();
        (graduated_, locked_,,,) = guard.releaseStatus();
        assertTrue(graduated_, "curve graduated");
        assertTrue(locked_, "LP locked forever");

        vm.prank(address(guard));
        guard.arm();
        (,, armed_, elapsed_,) = guard.releaseStatus();
        assertTrue(armed_);
        assertFalse(elapsed_, "the delay has not run yet");

        vm.warp(block.timestamp + guard.TRANSFER_DELAY());
        (,,, elapsed_,) = guard.releaseStatus();
        assertTrue(elapsed_, "the delay has run");

        console2.log("seconds until release:", guard.secondsUntilRelease());
    }

    /*//////////////////////////////////////////////////////////////
                           BUYBACK AND BURN
    //////////////////////////////////////////////////////////////*/

    /// @dev The locked LP position's trading fees are the one cash flow the launch produces
    ///      forever. The buyback turns Hoodz's share of them into destroyed HOODZ.
    function test_BuybackAndBurnDestroysHoodz() public {
        uint256 fees = 10_000e18;
        _accrueFees(fees);

        // 1 reserve buys 1 HOODZ; the router already holds the curve supply as inventory.
        swapRouter.setRate(address(reserve), address(hoodz), 1e18);

        uint256 supplyBefore = hoodz.totalSupply();

        (uint256 spent, uint256 burned) = buyback.buybackAndBurn(1, block.timestamp + 1 hours);

        assertEq(spent, fees, "every reserve token on hand is spent");
        assertEq(burned, 10_000e9, "1:1 into HOODZ at the configured rate");
        assertEq(supplyBefore - hoodz.totalSupply(), burned, "and the HOODZ is gone for good");
        assertEq(buyback.totalBurned(), burned);
        assertEq(hoodz.balanceOf(address(buyback)), 0, "nothing is left behind");
    }

    function test_RevertWhen_BuybackSlippageIsBreached() public {
        _accrueFees(1_000e18);
        swapRouter.setRate(address(reserve), address(hoodz), 1e18);
        swapRouter.setPayoutBps(5_000); // the router delivers half of what it quotes

        vm.expectRevert(); // InsufficientOutput, from the router's own bound
        buyback.buybackAndBurn(1_000e9, block.timestamp + 1 hours);
    }

    function test_RevertWhen_BuybackDeadlinePassed() public {
        _accrueFees(1_000e18);
        swapRouter.setRate(address(reserve), address(hoodz), 1e18);

        vm.expectRevert(FeeRouterBuyback.DeadlineExpired.selector);
        buyback.buybackAndBurn(1, block.timestamp - 1);
    }

    function test_RevertWhen_ThereIsNothingToBuy() public {
        vm.expectRevert(FeeRouterBuyback.NothingToBuy.selector);
        buyback.buybackAndBurn(1, block.timestamp + 1 hours);
    }

    function test_RevertWhen_NonPolicyTriggersBuyback() public {
        _accrueFees(1_000e18);

        vm.prank(alice);
        vm.expectRevert();
        buyback.buybackAndBurn(1, block.timestamp + 1 hours);
    }

    function test_PendingFeesReportsBothSides() public {
        _accrueFees(1_000e18);

        (uint256 held, uint256 claimable) = buyback.pendingFees();
        assertEq(held, 0, "nothing pulled in yet");
        assertEq(claimable, 1_000e18, "but the router owes 1000");

        buyback.claim();

        (held, claimable) = buyback.pendingFees();
        assertEq(held, 1_000e18, "now it is here");
        assertEq(claimable, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Pushes the curve past its threshold and graduates it through the launchpad.
    function _graduate() internal {
        curve.creditReserves(GRADUATION_THRESHOLD);
        launchpad.graduate(address(hoodz));
    }

    /// @dev Graduates, then records a well-formed, permanently locked LP position for HOODZ.
    function _graduateAndLock() internal {
        _graduate();
        locker.lockForever(address(hoodz), pool, key, LOCKED_LIQUIDITY, lockBeneficiary);
        poolManager.setLiquidity(poolId, LOCKED_LIQUIDITY);
    }

    /// @dev Graduates, locks, verifies, arms and waits out the full transfer delay.
    function _armAndWait() internal {
        _graduateAndLock();
        guard.verifyGraduation();

        vm.prank(address(guard));
        guard.arm();

        vm.warp(block.timestamp + guard.TRANSFER_DELAY());
    }

    /// @dev Funds the PONS fee router and books `amount_` as claimable for HOODZ.
    function _accrueFees(uint256 amount_) internal {
        reserve.mint(address(feeRouter), amount_);
        feeRouter.accrue(address(hoodz), amount_);
    }
}
