// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @dev UNAUDITED. Do not use in production without a full audit.

import {console2} from "forge-std/console2.sol";

import {HoodzStackSetup} from "./utils/HoodzStackSetup.sol";

/// @title  StakingTest
/// @notice Stake -> warmup -> rebase -> unstake, over many epochs.
/// @dev    Uses the real {Distributor} rather than a stub, because the one-epoch lag matters:
///         `HoodzStaking.rebase()` first pays out `epoch.distribute`, then calls the distributor,
///         which mints the next epoch's emission out of treasury excess reserves and sets
///         `epoch.distribute` for the following rebase. The first rebase after a stake therefore
///         funds rather than pays. These tests encode that rather than paper over it.
contract StakingTest is HoodzStackSetup {
    function setUp() public {
        _deployHoodzStack();
        // 10m reserve booked entirely as profit -> 10m HOODZ of excess reserves to emit from.
        _fundTreasury(10_000_000e18);
    }

    /*//////////////////////////////////////////////////////////////
                                 STAKING
    //////////////////////////////////////////////////////////////*/

    function test_StakeMintsRebasingSHoodz() public {
        uint256 received = _stake(alice, 1_000e9);

        assertEq(received, 1_000e9, "stake returns the sHOODZ credited");
        assertEq(sHoodz.balanceOf(alice), 1_000e9, "alice holds sHOODZ 1:1 with HOODZ");
        assertEq(hoodz.balanceOf(alice), 0, "the HOODZ was consumed");
        assertEq(hoodz.balanceOf(address(staking)), 1_000e9, "staking custodies the HOODZ");
        assertEq(sHoodz.circulatingSupply(), 1_000e9, "the stake is now circulating");
    }

    function test_StakeMintsNonRebasingGHoodz() public {
        uint256 received = _stakeToG(alice, 1_000e9);

        assertEq(received, sHoodz.toG(1_000e9), "gHOODZ is index-denominated");
        assertEq(gHoodz.balanceOf(alice), received);
        assertEq(sHoodz.balanceOf(alice), 0, "no sHOODZ when staking straight to gHOODZ");
        // At an index of 1.0, 1000 HOODZ (9 dec) is 1000 gHOODZ (18 dec).
        assertApproxEqRel(received, 1_000e18, 1e12);
    }

    function test_UnstakeReturnsHoodz() public {
        _stake(alice, 1_000e9);

        vm.startPrank(alice);
        sHoodz.approve(address(staking), 1_000e9);
        uint256 returned = staking.unstake(alice, 1_000e9, false, true);
        vm.stopPrank();

        assertEq(returned, 1_000e9);
        assertEq(hoodz.balanceOf(alice), 1_000e9, "HOODZ came back");
        assertEq(sHoodz.balanceOf(alice), 0);
    }

    function test_UnstakeFromGHoodz() public {
        uint256 g = _stakeToG(alice, 1_000e9);

        vm.startPrank(alice);
        gHoodz.approve(address(staking), g);
        uint256 returned = staking.unstake(alice, g, false, false);
        vm.stopPrank();

        assertApproxEqAbs(returned, 1_000e9, 1, "gHOODZ unwinds to the same HOODZ at a flat index");
        assertEq(gHoodz.balanceOf(alice), 0);
    }

    function test_WrapAndUnwrapPreserveValue() public {
        _stake(alice, 1_000e9);

        vm.startPrank(alice);
        sHoodz.approve(address(staking), 1_000e9);
        uint256 g = staking.wrap(alice, 1_000e9);
        gHoodz.approve(address(staking), g);
        uint256 s = staking.unwrap(alice, g);
        vm.stopPrank();

        assertApproxEqAbs(s, 1_000e9, 1, "wrap/unwrap must be value neutral");
        assertEq(gHoodz.balanceOf(alice), 0);
    }

    /*//////////////////////////////////////////////////////////////
                                 WARMUP
    //////////////////////////////////////////////////////////////*/

    function test_WarmupWithholdsSHoodzUntilExpiry() public {
        staking.setWarmupLength(2);

        _mintHoodz(alice, 1_000e9);
        vm.startPrank(alice);
        hoodz.approve(address(staking), 1_000e9);
        staking.stake(alice, 1_000e9, true, false); // _claim == false -> straight into warmup
        vm.stopPrank();

        assertEq(sHoodz.balanceOf(alice), 0, "nothing is released during warmup");
        assertEq(staking.supplyInWarmup(), 1_000e9, "the deposit is parked in warmup");

        // Claiming before expiry must release nothing at all.
        vm.prank(alice);
        staking.claim(alice, true);
        assertEq(sHoodz.balanceOf(alice), 0, "claim before expiry released funds");

        _rollEpochs(2);

        vm.prank(alice);
        uint256 claimed = staking.claim(alice, true);

        assertGe(claimed, 1_000e9, "claim releases at least the deposit");
        assertGe(sHoodz.balanceOf(alice), 1_000e9);
        assertEq(staking.supplyInWarmup(), 0, "warmup drained");
    }

    function test_ForfeitDuringWarmupReturnsHoodz() public {
        staking.setWarmupLength(3);

        _mintHoodz(alice, 1_000e9);
        vm.startPrank(alice);
        hoodz.approve(address(staking), 1_000e9);
        staking.stake(alice, 1_000e9, true, false);
        uint256 returned = staking.forfeit();
        vm.stopPrank();

        assertEq(returned, 1_000e9, "forfeit returns the original deposit");
        assertEq(hoodz.balanceOf(alice), 1_000e9);
        assertEq(staking.supplyInWarmup(), 0);
    }

    /// @dev `toggleLock` protects a warmup position from third-party deposits.
    function test_LockBlocksThirdPartyDeposits() public {
        staking.setWarmupLength(2);

        vm.prank(alice);
        staking.toggleLock();

        _mintHoodz(bob, 500e9);
        vm.startPrank(bob);
        hoodz.approve(address(staking), 500e9);
        vm.expectRevert(); // external deposits into a locked warmup are rejected
        staking.stake(alice, 500e9, true, false);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                 REBASE
    //////////////////////////////////////////////////////////////*/

    function test_SecondsToNextEpochCountsDown() public {
        assertEq(staking.secondsToNextEpoch(), EPOCH_LENGTH, "the first epoch ends one length out");

        vm.warp(block.timestamp + EPOCH_LENGTH / 2);
        assertEq(staking.secondsToNextEpoch(), EPOCH_LENGTH / 2);
    }

    function test_RebaseIsANoopBeforeTheEpochEnds() public {
        _stake(alice, 1_000e9);

        uint256 index = staking.index();
        vm.warp(block.timestamp + EPOCH_LENGTH - 1);
        staking.rebase();

        assertEq(staking.index(), index, "index moved inside an epoch");
    }

    /// @dev The first rebase after a stake funds the next one; the second pays it out.
    function test_RebaseDistributesFromTheSecondEpoch() public {
        _stake(alice, 1_000e9);

        _rollEpochs(1);
        assertEq(sHoodz.balanceOf(alice), 1_000e9, "epoch 1 funds, it does not pay");
        assertGt(hoodz.balanceOf(address(staking)), 1_000e9, "the emission was minted into staking");

        _rollEpochs(1);
        // REWARD_RATE 3000 / 1e6 == 0.30% per epoch
        assertApproxEqRel(sHoodz.balanceOf(alice), 1_003e9, 1e15, "epoch 2 pays 0.30%");
    }

    /// @dev The emission is `treasury.baseSupply() * rate / 1e6`, minted out of excess reserves.
    ///      Base supply - not staked supply - is the denominator, exactly as in Olympus.
    function test_EmissionMatchesTheConfiguredRate() public {
        _stake(alice, 1_000e9);

        uint256 expected = (treasury.baseSupply() * REWARD_RATE) / RATE_DENOMINATOR;
        assertEq(distributor.nextRewardFor(address(staking)), expected, "reward rate must be honoured");
        assertEq(expected, 3e9, "0.30% of a 1000 HOODZ base supply");

        uint256 excessBefore = treasury.excessReserves();
        uint256 stakingBefore = hoodz.balanceOf(address(staking));

        _rollEpochs(1);

        assertEq(excessBefore - treasury.excessReserves(), expected, "the emission is minted from excess reserves");
        assertEq(hoodz.balanceOf(address(staking)) - stakingBefore, expected, "and lands in staking");
    }

    /// @dev Rewards compound epoch over epoch, and the index tracks them exactly.
    function test_RebaseCompoundsOverManyEpochs() public {
        _stake(alice, 1_000e9);

        uint256 indexStart = staking.index();
        _rollEpochs(1); // priming epoch

        uint256 previous = sHoodz.balanceOf(alice);
        for (uint256 i; i < 10; ++i) {
            _rollEpochs(1);
            uint256 current = sHoodz.balanceOf(alice);
            assertGt(current, previous, "every epoch must pay");
            previous = current;
        }

        // 1.003^10 == 1.030408...
        assertApproxEqRel(sHoodz.balanceOf(alice), 1_030_400_000_000, 5e15, "ten epochs of 0.30%");
        assertApproxEqRel(staking.index(), (indexStart * 10_304) / 10_000, 5e15, "the index tracks the payout");

        console2.log("index after 11 epochs:", staking.index());
    }

    /// @dev A gHOODZ holder earns the same yield as an sHOODZ holder, through the index rather
    ///      than through a growing balance.
    function test_GHoodzHolderEarnsTheSameYield() public {
        _stake(alice, 1_000e9);
        uint256 g = _stakeToG(bob, 1_000e9);

        _rollEpochs(6);

        assertEq(gHoodz.balanceOf(bob), g, "gHOODZ balances never rebase");
        assertApproxEqRel(gHoodz.balanceFrom(g), sHoodz.balanceOf(alice), 1e14, "gHOODZ and sHOODZ yield alike");
    }

    function test_UnstakeAfterRebasesReturnsMoreHoodz() public {
        _stake(alice, 1_000e9);
        _rollEpochs(6);

        uint256 balance = sHoodz.balanceOf(alice);
        assertGt(balance, 1_000e9, "yield accrued");

        vm.startPrank(alice);
        sHoodz.approve(address(staking), balance);
        uint256 returned = staking.unstake(alice, balance, false, true);
        vm.stopPrank();

        assertEq(returned, balance, "unstake is 1:1 with the rebased balance");
        assertGt(hoodz.balanceOf(alice), 1_000e9, "yield realised as HOODZ");
    }

    /// @dev Staking must stay fully backed: the HOODZ held by the staking contract can never be
    ///      less than the sHOODZ it owes to circulating holders.
    function test_StakingStaysSolventAcrossEpochs() public {
        _stake(alice, 5_000e9);
        _stake(bob, 2_500e9);

        for (uint256 i; i < 12; ++i) {
            _rollEpochs(1);
            assertGe(
                hoodz.balanceOf(address(staking)),
                sHoodz.circulatingSupply(),
                "staking must hold at least the sHOODZ it owes"
            );
        }
    }

    /// @dev Two stakers who enter together must always hold the same proportional share.
    function testFuzz_YieldIsProRata(uint96 aliceAmount, uint96 bobAmount) public {
        uint256 a = bound(uint256(aliceAmount), 1e9, 1_000_000e9);
        uint256 b = bound(uint256(bobAmount), 1e9, 1_000_000e9);

        _stake(alice, a);
        _stake(bob, b);

        _rollEpochs(4);

        // aOut / a == bOut / b, cross-multiplied to stay in integer arithmetic.
        assertApproxEqRel(sHoodz.balanceOf(alice) * b, sHoodz.balanceOf(bob) * a, 1e12, "yield must be pro rata");
    }

    /*//////////////////////////////////////////////////////////////
                              PERMISSIONS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_NonGovernorSetsDistributor() public {
        vm.prank(alice);
        vm.expectRevert();
        staking.setDistributor(address(0xDEAD));
    }

    function test_RevertWhen_NonGovernorSetsWarmup() public {
        vm.prank(alice);
        vm.expectRevert();
        staking.setWarmupLength(5);
    }

    function test_RevertWhen_NonStakingCallsDistribute() public {
        vm.prank(alice);
        vm.expectRevert(); // distribute() is gated to the staking contract
        distributor.distribute();
    }
}
