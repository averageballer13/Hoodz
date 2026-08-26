// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @dev UNAUDITED. Do not use in production without a full audit.

import {HoodzTreasury} from "../src/HoodzTreasury.sol";

import {HoodzStackSetup} from "./utils/HoodzStackSetup.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title  TreasuryTest
/// @notice Deposit / withdraw / manage accounting, plus the decimal normalisation every backing
///         number in the protocol rests on.
/// @dev    `tokenValue` converts a reserve amount into HOODZ's 9 decimals. Get it wrong and the
///         treasury either over-mints by a factor of 10^9 or refuses to mint at all, so it is
///         exercised here against 6, 8, 9 and 18 decimal reserves.
contract TreasuryTest is HoodzStackSetup {
    MockERC20 internal usdc; // 6 decimals
    MockERC20 internal wbtc; // 8 decimals
    MockERC20 internal nine; // 9 decimals, same as HOODZ

    function setUp() public {
        _deployHoodzStack();

        usdc = new MockERC20("Mock USDC", "mUSDC", 6);
        wbtc = new MockERC20("Mock WBTC", "mWBTC", 8);
        nine = new MockERC20("Mock Nine", "mNINE", 9);

        treasury.enable(HoodzTreasury.STATUS.RESERVETOKEN, address(usdc), address(0));
        treasury.enable(HoodzTreasury.STATUS.RESERVETOKEN, address(wbtc), address(0));
        treasury.enable(HoodzTreasury.STATUS.RESERVETOKEN, address(nine), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                            DECIMAL HANDLING
    //////////////////////////////////////////////////////////////*/

    /// @dev One whole unit of any reserve token is worth 1e9 - one whole HOODZ of backing.
    function test_TokenValueNormalisesToNineDecimals() public view {
        assertEq(treasury.tokenValue(address(reserve), 1e18), 1e9, "18 decimals");
        assertEq(treasury.tokenValue(address(usdc), 1e6), 1e9, "6 decimals");
        assertEq(treasury.tokenValue(address(wbtc), 1e8), 1e9, "8 decimals");
        assertEq(treasury.tokenValue(address(nine), 1e9), 1e9, "9 decimals");
    }

    function test_TokenValueIsLinear() public view {
        assertEq(treasury.tokenValue(address(usdc), 2_500e6), 2_500e9);
        assertEq(treasury.tokenValue(address(reserve), 0), 0);
    }

    /// @dev Sub-unit amounts of a low-decimal token must not round away, and the rounding
    ///      direction on an 18-decimal token must be down - never in the depositor's favour.
    function test_TokenValueRoundsDown() public view {
        assertEq(treasury.tokenValue(address(usdc), 1), 1e3, "1 wei of a 6-decimal token is 1e3");
        assertEq(treasury.tokenValue(address(reserve), 1), 0, "1 wei of an 18-decimal token rounds to 0");
        assertEq(treasury.tokenValue(address(reserve), 1e9 - 1), 0, "still below one unit of HOODZ");
        assertEq(treasury.tokenValue(address(reserve), 1e9), 1, "exactly one unit of HOODZ");
    }

    function testFuzz_TokenValueMatchesTheScalingFactor(uint96 amount) public view {
        uint256 a = uint256(amount);
        assertEq(treasury.tokenValue(address(usdc), a), a * 1e3);
        assertEq(treasury.tokenValue(address(wbtc), a), a * 10);
        assertEq(treasury.tokenValue(address(reserve), a), a / 1e9);
    }

    /*//////////////////////////////////////////////////////////////
                                 DEPOSIT
    //////////////////////////////////////////////////////////////*/

    function test_DepositMintsValueMinusProfit() public {
        uint256 minted = _depositForHoodz(1_000e18, 400e9);

        assertEq(minted, 600e9, "the depositor receives value - profit");
        assertEq(hoodz.balanceOf(address(this)), 600e9);
        assertEq(treasury.totalReserves(), 1_000e9, "reserves are booked at full value");
        assertEq(reserve.balanceOf(address(treasury)), 1_000e18, "the tokens are custodied");
    }

    function test_DepositWithFullProfitMintsNothing() public {
        uint256 value = _fundTreasury(1_000e18);

        assertEq(value, 1_000e9);
        assertEq(hoodz.totalSupply(), 0, "no HOODZ issued");
        assertEq(treasury.totalReserves(), 1_000e9);
    }

    /// @dev A 6-decimal reserve must produce exactly the same backing as an 18-decimal one.
    function test_DepositOfLowDecimalTokenBacksTheSame() public {
        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(treasury), 1_000e6);
        uint256 minted = treasury.deposit(1_000e6, address(usdc), 0);

        assertEq(minted, 1_000e9, "1000 USDC backs 1000 HOODZ");
        assertEq(treasury.totalReserves(), 1_000e9);
    }

    function test_RevertWhen_DepositorNotApproved() public {
        reserve.mint(alice, 100e18);

        vm.startPrank(alice);
        reserve.approve(address(treasury), 100e18);
        vm.expectRevert(); // alice is not a RESERVEDEPOSITOR
        treasury.deposit(100e18, address(reserve), 0);
        vm.stopPrank();
    }

    function test_RevertWhen_TokenNotAccepted() public {
        MockERC20 rando = new MockERC20("Rando", "RND", 18);
        rando.mint(address(this), 100e18);
        rando.approve(address(treasury), 100e18);

        vm.expectRevert(); // RND was never enabled as a RESERVETOKEN
        treasury.deposit(100e18, address(rando), 0);
    }

    /*//////////////////////////////////////////////////////////////
                            EXCESS RESERVES
    //////////////////////////////////////////////////////////////*/

    /// @dev Excess reserves are backing beyond the circulating HOODZ - exactly the profit taken.
    function test_ExcessReservesEqualTakenProfit() public {
        assertEq(treasury.excessReserves(), 0, "an empty treasury has no excess");

        _depositForHoodz(1_000e18, 250e9);
        assertEq(treasury.excessReserves(), 250e9, "profit is the excess");

        _depositForHoodz(1_000e18, 250e9);
        assertEq(treasury.excessReserves(), 500e9, "profit accumulates");
    }

    function test_ExcessReservesFallAsHoodzIsMinted() public {
        _fundTreasury(1_000e18); // 1000e9 of excess

        treasury.mint(alice, 400e9);

        assertEq(hoodz.balanceOf(alice), 400e9);
        assertEq(treasury.excessReserves(), 600e9, "minting spends excess");
    }

    /// @dev The invariant that keeps HOODZ backed: you may never mint past the excess.
    function test_RevertWhen_MintExceedsExcessReserves() public {
        _fundTreasury(100e18); // 100e9 of excess

        vm.expectRevert();
        treasury.mint(alice, 101e9);
    }

    function test_RevertWhen_RewardManagerNotApproved() public {
        _fundTreasury(1_000e18);

        vm.prank(alice);
        vm.expectRevert(); // alice is not a REWARDMANAGER
        treasury.mint(alice, 1e9);
    }

    /// @dev `baseSupply` is what excess reserves are measured against, and what the distributor
    ///      sizes each epoch's emission from.
    function test_BaseSupplyTracksHoodz() public {
        assertEq(treasury.baseSupply(), hoodz.totalSupply(), "base supply starts at total supply");

        _depositForHoodz(1_000e18, 0);

        assertEq(treasury.baseSupply(), hoodz.totalSupply());
        assertEq(treasury.baseSupply(), 1_000e9);
    }

    /*//////////////////////////////////////////////////////////////
                                WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function test_WithdrawBurnsHoodzAndReturnsReserve() public {
        _depositForHoodz(1_000e18, 0); // 1000e9 HOODZ here, 1000e9 of reserves booked

        hoodz.approve(address(treasury), 400e9);
        treasury.withdraw(400e18, address(reserve));

        assertEq(reserve.balanceOf(address(this)), 400e18, "reserve returned");
        assertEq(hoodz.balanceOf(address(this)), 600e9, "HOODZ burned 1:1 with the value taken");
        assertEq(hoodz.totalSupply(), 600e9);
        assertEq(treasury.totalReserves(), 600e9, "reserves debited at value");
    }

    function test_RevertWhen_SpenderNotApproved() public {
        _depositForHoodz(1_000e18, 0);
        hoodz.transfer(alice, 100e9);

        vm.startPrank(alice);
        hoodz.approve(address(treasury), 100e9);
        vm.expectRevert(); // alice is not a RESERVESPENDER
        treasury.withdraw(100e18, address(reserve));
        vm.stopPrank();
    }

    /// @dev Deposit then withdraw the same amount must leave the balance sheet exactly as it
    ///      started - no dust stranded in either direction.
    function testFuzz_DepositWithdrawRoundTrip(uint96 amount) public {
        uint256 a = bound(uint256(amount), 1e9, 1_000_000e18);

        uint256 minted = _depositForHoodz(a, 0);
        hoodz.approve(address(treasury), minted);
        treasury.withdraw(a, address(reserve));

        assertEq(treasury.totalReserves(), 0, "reserves settled back to zero");
        assertEq(hoodz.totalSupply(), 0, "HOODZ settled back to zero");
        assertEq(reserve.balanceOf(address(treasury)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                                 MANAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev `manage` lets an approved policy pull idle reserves out without burning HOODZ - but
    ///      only as far as the excess allows, so circulating HOODZ stays fully backed.
    function test_ManageMovesIdleReservesWithinExcess() public {
        _fundTreasury(1_000e18); // pure excess

        treasury.manage(address(reserve), 400e18);

        assertEq(reserve.balanceOf(address(this)), 400e18, "the manager received the reserve");
        assertEq(treasury.totalReserves(), 600e9, "reserves debited");
        assertEq(treasury.excessReserves(), 600e9);
    }

    function test_RevertWhen_ManageExceedsExcessReserves() public {
        _depositForHoodz(1_000e18, 0); // fully backed, so excess == 0

        vm.expectRevert();
        treasury.manage(address(reserve), 1e18);
    }

    function test_RevertWhen_ManagerNotApproved() public {
        _fundTreasury(1_000e18);

        vm.prank(alice);
        vm.expectRevert(); // alice is not a RESERVEMANAGER
        treasury.manage(address(reserve), 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                              PERMISSIONS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_NonGovernorEnablesPermission() public {
        vm.prank(alice);
        vm.expectRevert();
        treasury.enable(HoodzTreasury.STATUS.RESERVEDEPOSITOR, alice, address(0));
    }

    function test_DisableRevokesAPermission() public {
        _fundTreasury(100e18);

        treasury.disable(HoodzTreasury.STATUS.REWARDMANAGER, address(this));

        vm.expectRevert();
        treasury.mint(alice, 1e9);
    }

    function test_PermissionsAreRegistered() public view {
        assertTrue(treasury.permissions(HoodzTreasury.STATUS.RESERVETOKEN, address(reserve)));
        assertTrue(treasury.permissions(HoodzTreasury.STATUS.REWARDMANAGER, address(distributor)));
        assertFalse(treasury.permissions(HoodzTreasury.STATUS.RESERVEDEPOSITOR, alice));
    }
}
