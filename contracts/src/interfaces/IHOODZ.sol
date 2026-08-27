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
        X      https://x.com/Hoodzfinancial
        Code   https://github.com/averageballer13/Hoodz

        UNAUDITED. This code has never been audited. Read it before you
        trust it with anything you would miss.
*/

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title  IHOODZ
/// @notice The HOODZ token as the protocol sees it: a plain ERC20 and nothing more.
/// @dev    HOODZ is NOT deployed by this repository. The PONS launchpad deploys it from its own
///         factory when the launch form is submitted: fixed supply of 1,000,000,000, the entire
///         amount minted straight to the bonding curve, no creator allocation, no owner, no mint
///         function and no burn function.
///
///         That is why this interface is bare. Anywhere the Olympus design would have minted, this
///         protocol pays out of treasury inventory instead ({ITreasury.payout}); anywhere it would
///         have burned, it transfers to the dead address ({HoodzBurn}). Do not add `mint` here -
///         there is nothing on the other side to call.
interface IHOODZ is IERC20 {}
