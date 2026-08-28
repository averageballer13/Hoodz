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

/**
 * @title  INoteKeeper
 * @author Hoodz
 * @notice Vesting-note bookkeeping shared by every Hoodz bond market.
 * @dev    Port of the Olympus V2 `INoteKeeper`. A Note is an isolated vesting position
 *         created when a user deposits into a bond market. Payout is denominated in
 *         gHOOD so that a maturing bond keeps compounding at the staking index while
 *         it vests.
 *
 *         Extra bond-market types that do not belong in `IBondDepository` live here.
 */
interface INoteKeeper {
    /* ========== TYPES ========== */

    /// @notice A single vesting position owned by a user.
    /// @param payout   gHOOD amount remaining to be paid out.
    /// @param created  Timestamp the note was minted.
    /// @param matured  Timestamp the note becomes redeemable.
    /// @param redeemed Timestamp the note was redeemed (0 while outstanding).
    /// @param marketID ID of the bond market the note originated from.
    struct Note {
        uint256 payout;
        uint48 created;
        uint48 matured;
        uint48 redeemed;
        uint48 marketID;
    }

    /* ========== EVENTS ========== */

    /// @notice Emitted when a note is created for `user`.
    event NoteCreated(address indexed user, uint256 indexed marketID, uint256 index, uint256 payout, uint48 expiry);

    /// @notice Emitted when notes are redeemed for `user`.
    event NoteRedeemed(address indexed user, uint256 payout, bool sentAsG);

    /// @notice Emitted when a note is offered for transfer.
    event NotePushed(address indexed from, address indexed to, uint256 index);

    /// @notice Emitted when an offered note is claimed by its new owner.
    event NotePulled(address indexed from, address indexed to, uint256 oldIndex, uint256 newIndex);

    /* ========== MUTATIVE ========== */

    /// @notice Redeem a specific set of matured notes for `_user`.
    /// @param _user     Owner of the notes.
    /// @param _indexes  Indexes (into the owner's note array) to redeem.
    /// @param _sendgHOOD True to receive gHOOD, false to unstake into HOOD.
    /// @return payout_  Total gHOOD credited (before an optional unstake).
    function redeem(address _user, uint256[] memory _indexes, bool _sendgHOOD) external returns (uint256 payout_);

    /// @notice Redeem every outstanding note held by `_user`.
    /// @param _user     Owner of the notes.
    /// @param _sendgHOOD True to receive gHOOD, false to unstake into HOOD.
    /// @return payout_  Total gHOOD credited (before an optional unstake).
    function redeemAll(address _user, bool _sendgHOOD) external returns (uint256 payout_);

    /// @notice Offer one of the caller's notes to `_to`.
    /// @param _to    Address allowed to pull the note.
    /// @param _index Index of the caller's note.
    function pushNote(address _to, uint256 _index) external;

    /// @notice Claim a note that `_from` offered to the caller.
    /// @param _from  Current owner of the note.
    /// @param _index Index of the note in the owner's array.
    /// @return newIndex_ Index of the note in the caller's array.
    function pullNote(address _from, uint256 _index) external returns (uint256 newIndex_);

    /* ========== VIEW ========== */

    /// @notice All indexes of `_user` notes that have not been redeemed yet.
    /// @param _user Note owner.
    /// @return Array of live note indexes.
    function indexesFor(address _user) external view returns (uint256[] memory);

    /// @notice Payout and maturity status of a single note.
    /// @param _user  Note owner.
    /// @param _index Index of the note.
    /// @return payout_  gHOOD owed by the note.
    /// @return matured_ True when the note is redeemable right now.
    function pendingFor(address _user, uint256 _index) external view returns (uint256 payout_, bool matured_);
}
