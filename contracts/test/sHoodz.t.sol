// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @dev UNAUDITED. Do not use in production without a full audit.

import {Test} from "forge-std/Test.sol";

import {HoodzAuthority} from "../src/HoodzAuthority.sol";
import {IHoodzAuthority} from "../src/interfaces/IHoodzAuthority.sol";
import {sHOODZ} from "../src/tokens/sHOODZ.sol";
import {gHOODZ} from "../src/tokens/gHOODZ.sol";

import {MockStaking} from "./mocks/MockStaking.sol";

/// @title  sHoodzTest
/// @notice sHOODZ is a gons-based rebasing token: a balance is a view over a fixed gon supply.
///         These tests pin the two things that must never break - the gon invariant (a holder's
///         gons do not move on rebase, only what they are worth) and the index (it grows by
///         exactly the rebase ratio, which is what makes gHOODZ worth more sHOODZ over time).
/// @dev    Deliberately isolated from staking and the treasury: a {MockStaking} owns the unstaked
///         float and drives `rebase()`, so the maths is measured without protocol noise.
contract sHoodzTest is Test {
    HoodzAuthority internal authority;
    sHOODZ internal sHoodz;
    gHOODZ internal gHoodz;
    MockStaking internal stakingMock;

    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    /// @dev One sHOODZ per gHOODZ at launch, in sHOODZ's 9 decimals.
    uint256 internal constant INITIAL_INDEX = 1e9;

    function setUp() public {
        vm.warp(1_700_000_000);

        authority = new HoodzAuthority(address(this), guardian, address(this), address(this));
        IHoodzAuthority auth = IHoodzAuthority(address(authority));

        sHoodz = new sHOODZ(auth);
        gHoodz = new gHOODZ(auth, address(sHoodz));
        stakingMock = new MockStaking();
        stakingMock.setSHoodz(address(sHoodz));

        sHoodz.setIndex(INITIAL_INDEX);
        sHoodz.setgHOODZ(address(gHoodz));
        sHoodz.initialize(address(stakingMock), treasury);
        gHoodz.migrate(address(stakingMock), address(sHoodz));

        vm.label(address(sHoodz), "sHOODZ");
        vm.label(address(gHoodz), "gHOODZ");
        vm.label(address(stakingMock), "MockStaking");
    }

    /*//////////////////////////////////////////////////////////////
                              INITIAL STATE
    //////////////////////////////////////////////////////////////*/

    function test_Metadata() public view {
        assertEq(sHoodz.decimals(), 9, "sHOODZ tracks HOODZ at 9 decimals");
        assertEq(sHoodz.symbol(), "sHOODZ");
    }

    /// @dev On `initialize` the whole gon supply is parked with the staking contract, so nothing
    ///      is circulating and no rebase can reach anyone.
    function test_InitialSupplyIsHeldByStaking() public view {
        uint256 supply = sHoodz.totalSupply();

        assertGt(supply, 0, "sHOODZ must launch with a non-zero fragment supply");
        assertEq(sHoodz.balanceOf(address(stakingMock)), supply, "staking holds the whole float");
        assertEq(sHoodz.circulatingSupply(), 0, "nothing circulates before anyone stakes");
        assertEq(sHoodz.index(), INITIAL_INDEX, "index starts at 1");
    }

    function test_RevertWhen_IndexSetTwice() public {
        vm.expectRevert();
        sHoodz.setIndex(2e9);
    }

    function test_RevertWhen_InitializedTwice() public {
        vm.expectRevert();
        sHoodz.initialize(address(stakingMock), treasury);
    }

    function test_RevertWhen_NonStakingRebases() public {
        _distribute(alice, 1_000e9);

        vm.prank(alice);
        vm.expectRevert(); // rebase is gated to the staking contract
        sHoodz.rebase(10e9, 1);
    }

    /*//////////////////////////////////////////////////////////////
                             GONS INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev `balanceForGons(gonsForBalance(x)) == x` for any balance the token can express.
    function testFuzz_GonBalanceRoundTrip(uint96 amount) public view {
        uint256 a = bound(uint256(amount), 0, sHoodz.totalSupply());
        assertEq(sHoodz.balanceForGons(sHoodz.gonsForBalance(a)), a, "gon round trip must be lossless");
    }

    /// @dev The point of a gons ledger: a rebase re-prices gons, it never moves them between or
    ///      out of accounts.
    function test_GonsAreInvariantAcrossRebase() public {
        _distribute(alice, 1_000e9);

        uint256 gonsBefore = sHoodz.gonsForBalance(sHoodz.balanceOf(alice));

        _rebasePercent(1);
        uint256 gonsAfterOne = sHoodz.gonsForBalance(sHoodz.balanceOf(alice));

        _rebasePercent(1);
        uint256 gonsAfterTwo = sHoodz.gonsForBalance(sHoodz.balanceOf(alice));

        // Relative tolerance: 1e18 == 100%, so 1e9 == 1e-9. Real rounding here is ~1e-12.
        assertApproxEqRel(gonsAfterOne, gonsBefore, 1e9, "gons moved on the first rebase");
        assertApproxEqRel(gonsAfterTwo, gonsBefore, 2e9, "gons moved on the second rebase");
    }

    /// @dev Holder balances may never sum past the total supply, at any index.
    function test_BalancesNeverExceedTotalSupply() public {
        _distribute(alice, 1_000e9);
        _distribute(bob, 3_000e9);

        _rebasePercent(5);

        uint256 sum = sHoodz.balanceOf(alice) + sHoodz.balanceOf(bob) + sHoodz.balanceOf(address(stakingMock));
        assertLe(sum, sHoodz.totalSupply(), "balances over-issued");
    }

    /*//////////////////////////////////////////////////////////////
                               REBASE MATH
    //////////////////////////////////////////////////////////////*/

    /// @dev A rebase distributing `profit` over a circulating supply of `c` grows every
    ///      circulating balance by exactly `profit / c`.
    function test_RebaseGrowsCirculatingBalancesProRata() public {
        _distribute(alice, 1_000e9);
        _distribute(bob, 3_000e9);
        assertEq(sHoodz.circulatingSupply(), 4_000e9);

        _rebasePercent(1);

        assertApproxEqAbs(sHoodz.balanceOf(alice), 1_010e9, 1e3, "alice +1%");
        assertApproxEqAbs(sHoodz.balanceOf(bob), 3_030e9, 1e3, "bob +1%");
        assertApproxEqAbs(sHoodz.circulatingSupply(), 4_040e9, 1e4, "circulating +1%");
    }

    /// @dev The float still held by the staking contract is not circulating, so it is diluted
    ///      rather than rewarded. That asymmetry is precisely what funds the rebase.
    function test_StakingFloatIsDilutedNotRewarded() public {
        _distribute(alice, 1_000e9);

        uint256 supplyBefore = sHoodz.totalSupply();

        _rebasePercent(10);

        assertGt(sHoodz.totalSupply(), supplyBefore, "supply must grow");
        assertApproxEqAbs(sHoodz.balanceOf(alice) - 1_000e9, 100e9, 1e3, "alice earns the full 10%");
    }

    function test_IndexTracksTheRebaseRatio() public {
        _distribute(alice, 1_000e9);

        uint256 indexBefore = sHoodz.index();
        _rebasePercent(1);

        assertApproxEqRel(sHoodz.index(), (indexBefore * 101) / 100, 1e14, "index must track the rebase");
    }

    /// @dev Ten consecutive 1% rebases must compound, not accumulate linearly: 1.01^10 = 1.1046221.
    function test_RebaseCompoundsOverEpochs() public {
        _distribute(alice, 1_000e9);

        for (uint256 i; i < 10; ++i) {
            _rebasePercent(1);
        }

        assertApproxEqRel(sHoodz.balanceOf(alice), 1_104_622_100_000, 1e15, "1% compounded ten times");
        assertApproxEqRel(sHoodz.index(), 1_104_622_100, 1e15, "index compounded ten times");
    }

    function test_ZeroProfitRebaseIsANoop() public {
        _distribute(alice, 1_000e9);

        uint256 supply = sHoodz.totalSupply();
        uint256 index = sHoodz.index();

        stakingMock.rebase(0, 1);

        assertEq(sHoodz.totalSupply(), supply, "supply moved on a zero rebase");
        assertEq(sHoodz.index(), index, "index moved on a zero rebase");
        assertEq(sHoodz.balanceOf(alice), 1_000e9);
    }

    /// @dev Warmup balances count as circulating: they are entitled to the rebase, so they dilute
    ///      the share every other staker receives.
    function test_WarmupSupplyDilutesTheRebase() public {
        _distribute(alice, 1_000e9);
        stakingMock.setSupplyInWarmup(1_000e9);

        assertEq(sHoodz.circulatingSupply(), 2_000e9, "warmup counts as circulating");

        // 20 sHOODZ over 2000 circulating is +1% for everyone, alice included.
        stakingMock.rebase(20e9, 1);

        assertApproxEqAbs(sHoodz.balanceOf(alice), 1_010e9, 1e3, "alice grows with the ratio");
    }

    /*//////////////////////////////////////////////////////////////
                                TRANSFERS
    //////////////////////////////////////////////////////////////*/

    /// @dev A transfer moves gons; the recipient earns on the full amount at the next rebase.
    function test_TransferMovesGonsAndKeepsEarning() public {
        _distribute(alice, 1_000e9);

        vm.prank(alice);
        sHoodz.transfer(bob, 400e9);

        assertApproxEqAbs(sHoodz.balanceOf(alice), 600e9, 1, "sender balance");
        assertApproxEqAbs(sHoodz.balanceOf(bob), 400e9, 1, "receiver balance");

        _rebasePercent(1);

        assertApproxEqAbs(sHoodz.balanceOf(alice), 606e9, 1e3);
        assertApproxEqAbs(sHoodz.balanceOf(bob), 404e9, 1e3);
    }

    function test_TransferFromSpendsAllowance() public {
        _distribute(alice, 1_000e9);

        vm.prank(alice);
        sHoodz.approve(bob, 400e9);

        vm.prank(bob);
        sHoodz.transferFrom(alice, bob, 400e9);

        assertApproxEqAbs(sHoodz.balanceOf(bob), 400e9, 1);
        assertEq(sHoodz.allowance(alice, bob), 0);
    }

    /*//////////////////////////////////////////////////////////////
                              gHOODZ BRIDGE
    //////////////////////////////////////////////////////////////*/

    /// @dev `toG` / `fromG` are the only bridge between the rebasing and the non-rebasing view of
    ///      the same position, so they must round-trip at any index.
    function testFuzz_ToGFromGRoundTrip(uint96 amount) public {
        uint256 a = bound(uint256(amount), 1e9, 1_000_000e9);

        _distribute(alice, 1e9); // put something in circulation so a rebase does something
        _rebasePercent(7); // move the index off 1.0 so the conversion is non-trivial

        uint256 back = sHoodz.fromG(sHoodz.toG(a));

        assertApproxEqRel(back, a, 1e12, "toG/fromG must round trip");
    }

    /// @dev gHOODZ is index-denominated: the same gHOODZ is worth more sHOODZ after a rebase.
    function test_gHoodzBalanceFromFollowsTheIndex() public {
        _distribute(alice, 1_000e9);

        uint256 oneG = 1e18;
        uint256 valueBefore = gHoodz.balanceFrom(oneG);

        _rebasePercent(1);

        assertApproxEqRel(gHoodz.balanceFrom(oneG), (valueBefore * 101) / 100, 1e14, "gHOODZ must appreciate");
    }

    function test_gHoodzIndexMirrorsSHoodz() public {
        _distribute(alice, 1_000e9);
        _rebasePercent(3);

        assertEq(gHoodz.index(), sHoodz.index(), "gHOODZ reads its index straight from sHOODZ");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Moves sHOODZ out of the staking float into circulation, simulating a stake.
    function _distribute(address to_, uint256 amount_) internal {
        stakingMock.transferTo(to_, amount_);
    }

    /// @dev Rebases by `pct_` percent of the current circulating supply.
    function _rebasePercent(uint256 pct_) internal {
        stakingMock.rebase((sHoodz.circulatingSupply() * pct_) / 100, 1);
    }
}
