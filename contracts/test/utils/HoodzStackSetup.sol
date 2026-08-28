// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @dev UNAUDITED. Do not use in production without a full audit.

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HoodzAuthority} from "../../src/HoodzAuthority.sol";
import {HoodzTreasury} from "../../src/HoodzTreasury.sol";
import {HoodzStaking} from "../../src/HoodzStaking.sol";
import {IHOOD} from "../../src/interfaces/IHOOD.sol";
import {MockPonsToken} from "../mocks/MockPonsToken.sol";
import {sHOOD} from "../../src/tokens/sHOOD.sol";
import {gHOOD} from "../../src/tokens/gHOOD.sol";
import {Distributor} from "../../src/policies/Distributor.sol";
import {IHoodzAuthority} from "../../src/interfaces/IHoodzAuthority.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockSavingsVault} from "../mocks/MockSavingsVault.sol";

/// @title  HoodzStackSetup
/// @notice Shared fixture: deploys and wires HoodzAuthority + HOOD/sHOOD/gHOOD + treasury +
///         staking + distributor in the same order and with the same arguments as
///         `script/Deploy.s.sol`, so the tests and the deploy script can only ever drift together.
/// @dev    The test contract itself holds `governor` and `policy`, which keeps the permissioned
///         calls readable - no prank noise around the wiring. `guardian` is a separate address so
///         guardian-gated paths are actually exercised rather than accidentally satisfied.
abstract contract HoodzStackSetup is Test {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev 8 hours, the Olympus epoch length.
    uint256 internal constant EPOCH_LENGTH = 28_800;
    uint256 internal constant FIRST_EPOCH_NUMBER = 1;

    /// @dev sHOOD launch index: one sHOOD per gHOOD, in sHOOD's 9 decimals.
    uint256 internal constant INITIAL_INDEX = 1e9;

    /// @dev Per-epoch staking emission, 1e6 denominator. 3000 == 0.30% per epoch.
    uint256 internal constant REWARD_RATE = 3_000;
    uint256 internal constant RATE_DENOMINATOR = 1e6;

    /// @dev A deterministic start time; several contracts key off `block.timestamp`.
    uint256 internal constant START_TIME = 1_700_000_000;

    /*//////////////////////////////////////////////////////////////
                                 ACTORS
    //////////////////////////////////////////////////////////////*/

    address internal governor; // == address(this)
    address internal policy; // == address(this)
    address internal guardian;
    address internal alice;
    address internal bob;

    /*//////////////////////////////////////////////////////////////
                                CONTRACTS
    //////////////////////////////////////////////////////////////*/

    HoodzAuthority internal authority;
    MockPonsToken internal hoodz;
    sHOOD internal sHoodz;
    gHOOD internal gHoodz;
    HoodzTreasury internal treasury;
    HoodzStaking internal staking;
    Distributor internal distributor;

    /// @notice 18-decimal reserve asset, the DAI-shaped default.
    MockERC20 internal reserve;

    /// @notice ERC-4626 wrapper of {reserve}, the sDAI-shaped savings vault.
    MockSavingsVault internal savings;

    /*//////////////////////////////////////////////////////////////
                                 FIXTURE
    //////////////////////////////////////////////////////////////*/

    /// @dev Deploys and wires the core stack. Call this first from a test's `setUp()`.
    function _deployHoodzStack() internal {
        vm.warp(START_TIME);

        governor = address(this);
        policy = address(this);
        guardian = makeAddr("guardian");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // The deployer keeps `vault` until the treasury exists, exactly as Deploy.s.sol does.
        authority = new HoodzAuthority(governor, guardian, policy, address(this));
        IHoodzAuthority auth = IHoodzAuthority(address(authority));

        // Stands in for the PONS-deployed token: fixed supply, no mint. The whole supply lands
        // on this fixture, which then plays the part of the curve and of buyers.
        hoodz = new MockPonsToken("Hoodz", "HOOD", 9, address(this));
        sHoodz = new sHOOD(auth);
        gHoodz = new gHOOD(auth, address(sHoodz));

        reserve = new MockERC20("Mock Reserve", "mRSV", 18);
        savings = new MockSavingsVault(IERC20(address(reserve)), "Mock Savings Reserve", "msRSV");

        // `timelock == 0` so treasury permissions take effect immediately in tests.
        treasury = new HoodzTreasury(address(hoodz), 0, address(authority));

        staking = new HoodzStaking(
            address(hoodz),
            address(sHoodz),
            address(gHoodz),
            EPOCH_LENGTH,
            FIRST_EPOCH_NUMBER,
            block.timestamp + EPOCH_LENGTH,
            address(authority)
        );

        distributor = new Distributor(address(treasury), address(hoodz), address(staking), address(authority));

        // --- token trio ---
        sHoodz.setIndex(INITIAL_INDEX);
        sHoodz.setgHOOD(address(gHoodz));
        sHoodz.initialize(address(staking), address(treasury));
        gHoodz.migrate(address(staking), address(sHoodz));

        // --- staking ---
        staking.setDistributor(address(distributor));
        distributor.addRecipient(address(staking), REWARD_RATE);

        // --- the treasury becomes the sole mint authority (post-graduation state) ---
        authority.pushVault(address(treasury), true);

        // --- treasury permissions ---
        treasury.enable(HoodzTreasury.STATUS.RESERVETOKEN, address(reserve), address(0));
        treasury.enable(HoodzTreasury.STATUS.RESERVETOKEN, address(savings), address(0));
        treasury.enable(HoodzTreasury.STATUS.RESERVEDEPOSITOR, address(this), address(0));
        treasury.enable(HoodzTreasury.STATUS.RESERVESPENDER, address(this), address(0));
        treasury.enable(HoodzTreasury.STATUS.RESERVEMANAGER, address(this), address(0));
        treasury.enable(HoodzTreasury.STATUS.REWARDMANAGER, address(this), address(0));
        treasury.enable(HoodzTreasury.STATUS.REWARDMANAGER, address(distributor), address(0));
        treasury.enable(HoodzTreasury.STATUS.SHOOD, address(sHoodz), address(0));

        vm.label(address(authority), "HoodzAuthority");
        vm.label(address(hoodz), "HOOD");
        vm.label(address(sHoodz), "sHOOD");
        vm.label(address(gHoodz), "gHOOD");
        vm.label(address(treasury), "HoodzTreasury");
        vm.label(address(staking), "HoodzStaking");
        vm.label(address(distributor), "Distributor");
        vm.label(address(reserve), "Reserve");
        vm.label(address(savings), "SavingsVault");
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Deposits reserve into the treasury booking the whole value as profit, so nothing is
    ///      minted and the entire value lands in excess reserves.
    /// @param amount_ Reserve amount, in the reserve's own decimals.
    /// @return value The HOOD-denominated (9 decimal) value credited.
    function _fundTreasury(uint256 amount_) internal returns (uint256 value) {
        reserve.mint(address(this), amount_);
        reserve.approve(address(treasury), amount_);
        value = treasury.tokenValue(address(reserve), amount_);
        treasury.deposit(amount_, address(reserve), value);
    }

    /// @dev Deposits reserve taking only `profit_`, so `value - profit_` is minted to this contract.
    /// @param amount_ Reserve amount, in the reserve's own decimals.
    /// @param profit_ HOOD-denominated profit retained by the treasury.
    /// @return minted HOOD minted to this contract.
    function _depositForHoodz(uint256 amount_, uint256 profit_) internal returns (uint256 minted) {
        reserve.mint(address(this), amount_);
        reserve.approve(address(treasury), amount_);
        minted = treasury.deposit(amount_, address(reserve), profit_);
    }

    /// @dev Mints HOOD to `to_` out of treasury excess reserves. Requires a prior {_fundTreasury}.
    /// @param to_ Recipient.
    /// @param amount_ HOOD amount, 9 decimals.
    function _mintHoodz(address to_, uint256 amount_) internal {
        treasury.mint(to_, amount_);
    }

    /// @dev Stakes HOOD for `user_` and returns rebasing sHOOD immediately.
    /// @param user_ The staker.
    /// @param amount_ HOOD amount, 9 decimals.
    /// @return The sHOOD received.
    function _stake(address user_, uint256 amount_) internal returns (uint256) {
        _mintHoodz(user_, amount_);
        vm.startPrank(user_);
        hoodz.approve(address(staking), amount_);
        uint256 out = staking.stake(user_, amount_, true, true);
        vm.stopPrank();
        return out;
    }

    /// @dev Stakes HOOD for `user_` and returns non-rebasing gHOOD.
    /// @param user_ The staker.
    /// @param amount_ HOOD amount, 9 decimals.
    /// @return The gHOOD received.
    function _stakeToG(address user_, uint256 amount_) internal returns (uint256) {
        _mintHoodz(user_, amount_);
        vm.startPrank(user_);
        hoodz.approve(address(staking), amount_);
        uint256 out = staking.stake(user_, amount_, false, true);
        vm.stopPrank();
        return out;
    }

    /// @dev Warps to the end of the current epoch and rebases, `epochs_` times.
    /// @param epochs_ How many epochs to roll forward.
    function _rollEpochs(uint256 epochs_) internal {
        for (uint256 i; i < epochs_; ++i) {
            vm.warp(block.timestamp + EPOCH_LENGTH);
            staking.rebase();
        }
    }
}
