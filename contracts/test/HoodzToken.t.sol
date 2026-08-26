// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @dev UNAUDITED. Do not use in production without a full audit.

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HoodzAuthority} from "../src/HoodzAuthority.sol";
import {IHoodzAuthority} from "../src/interfaces/IHoodzAuthority.sol";
import {HOODZ} from "../src/tokens/HOODZ.sol";

/// @title  HoodzTokenTest
/// @notice HOODZ is the PONS-facing token: a clean, permissionless ERC20 whose only privileged
///         operation is minting, gated to the `vault` role. These tests pin both halves of that -
///         the openness PONS requires, and the gate the protocol depends on.
contract HoodzTokenTest is Test {
    HoodzAuthority internal authority;
    HOODZ internal hoodz;

    address internal guardian = makeAddr("guardian");
    address internal policy = makeAddr("policy");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        // The test contract holds governor and vault, so it can both wire and mint.
        authority = new HoodzAuthority(address(this), guardian, policy, address(this));
        hoodz = new HOODZ(IHoodzAuthority(address(authority)));

        vm.label(address(hoodz), "HOODZ");
        vm.label(address(authority), "HoodzAuthority");
    }

    /*//////////////////////////////////////////////////////////////
                                METADATA
    //////////////////////////////////////////////////////////////*/

    /// @dev HOODZ mirrors OHM at 9 decimals; every treasury valuation is scaled to it.
    function test_Metadata() public view {
        assertEq(hoodz.decimals(), 9, "HOODZ must have 9 decimals");
        assertEq(hoodz.symbol(), "HOODZ", "symbol");
        assertEq(hoodz.name(), "Hoodz", "name");
    }

    function test_StartsWithZeroSupply() public view {
        assertEq(hoodz.totalSupply(), 0, "HOODZ must launch with no supply: PONS mints the curve");
    }

    function test_AuthorityIsWired() public view {
        assertEq(address(hoodz.authority()), address(authority));
        assertEq(authority.vault(), address(this));
    }

    /*//////////////////////////////////////////////////////////////
                                  MINT
    //////////////////////////////////////////////////////////////*/

    function test_VaultCanMint() public {
        hoodz.mint(alice, 1_000e9);

        assertEq(hoodz.balanceOf(alice), 1_000e9);
        assertEq(hoodz.totalSupply(), 1_000e9);
    }

    /// @dev Anyone other than `authority.vault()` must be rejected. The concrete error belongs to
    ///      HoodzAccessControlled, so match any revert rather than couple to its selector.
    function test_RevertWhen_NonVaultMints() public {
        vm.prank(alice);
        vm.expectRevert();
        hoodz.mint(alice, 1e9);
    }

    /// @dev Minting follows the vault role rather than a cached address - this is what makes the
    ///      PONS launch guard work: while the guard holds `vault`, nothing can mint at all.
    function test_MintFollowsTheVaultRole() public {
        authority.pushVault(bob, true);

        vm.prank(bob);
        hoodz.mint(bob, 5e9);
        assertEq(hoodz.balanceOf(bob), 5e9);

        vm.expectRevert(); // the test contract is no longer the vault
        hoodz.mint(alice, 1e9);
    }

    /*//////////////////////////////////////////////////////////////
                                  BURN
    //////////////////////////////////////////////////////////////*/

    function test_HolderCanBurnOwnBalance() public {
        hoodz.mint(alice, 100e9);

        vm.prank(alice);
        hoodz.burn(40e9);

        assertEq(hoodz.balanceOf(alice), 60e9);
        assertEq(hoodz.totalSupply(), 60e9);
    }

    function test_BurnFromSpendsAllowance() public {
        hoodz.mint(alice, 100e9);

        vm.prank(alice);
        hoodz.approve(bob, 30e9);

        vm.prank(bob);
        hoodz.burnFrom(alice, 30e9);

        assertEq(hoodz.balanceOf(alice), 70e9);
        assertEq(hoodz.totalSupply(), 70e9);
        assertEq(hoodz.allowance(alice, bob), 0, "allowance must be consumed");
    }

    function test_RevertWhen_BurnFromExceedsAllowance() public {
        hoodz.mint(alice, 100e9);

        vm.prank(alice);
        hoodz.approve(bob, 10e9);

        vm.prank(bob);
        vm.expectRevert(); // ERC20InsufficientAllowance
        hoodz.burnFrom(alice, 11e9);
    }

    /*//////////////////////////////////////////////////////////////
                          PONS COMPATIBILITY
    //////////////////////////////////////////////////////////////*/

    /// @dev PONS rejects tokens with a transfer tax: a transfer must move the exact amount and
    ///      leave the supply untouched.
    function test_TransfersAreUntaxed() public {
        hoodz.mint(alice, 1_000e9);

        vm.prank(alice);
        hoodz.transfer(bob, 250e9);

        assertEq(hoodz.balanceOf(alice), 750e9);
        assertEq(hoodz.balanceOf(bob), 250e9);
        assertEq(hoodz.totalSupply(), 1_000e9, "supply must not change on transfer");
    }

    /// @dev PONS rejects blocklists and pausable transfers: an arbitrary holder must always be
    ///      able to move its whole balance to an arbitrary recipient.
    function testFuzz_TransferIsPermissionless(address from, address to, uint96 amount) public {
        vm.assume(from != address(0) && to != address(0) && from != to);
        vm.assume(to != address(hoodz) && from != address(hoodz));

        hoodz.mint(from, amount);

        vm.prank(from);
        hoodz.transfer(to, amount);

        assertEq(hoodz.balanceOf(to), amount);
        assertEq(hoodz.balanceOf(from), 0);
    }

    function test_TransferFromSpendsAllowance() public {
        hoodz.mint(alice, 100e9);

        vm.prank(alice);
        hoodz.approve(bob, 100e9);

        vm.prank(bob);
        IERC20(address(hoodz)).transferFrom(alice, bob, 100e9);

        assertEq(hoodz.balanceOf(bob), 100e9);
        assertEq(hoodz.allowance(alice, bob), 0);
    }

    /// @dev ERC20Permit is part of the token, so a wallet can approve gaslessly on the curve.
    function test_PermitDomainIsInitialised() public view {
        assertTrue(hoodz.DOMAIN_SEPARATOR() != bytes32(0), "EIP-712 domain must be set");
        assertEq(hoodz.nonces(alice), 0);
    }

    /*//////////////////////////////////////////////////////////////
                                 SUPPLY
    //////////////////////////////////////////////////////////////*/

    function testFuzz_SupplyTracksMintAndBurn(uint96 mintAmount, uint96 burnAmount) public {
        uint256 toBurn = bound(uint256(burnAmount), 0, uint256(mintAmount));

        hoodz.mint(alice, mintAmount);
        assertEq(hoodz.totalSupply(), mintAmount);

        vm.prank(alice);
        hoodz.burn(toBurn);

        assertEq(hoodz.totalSupply(), uint256(mintAmount) - toBurn);
        assertEq(hoodz.balanceOf(alice), uint256(mintAmount) - toBurn);
    }
}
