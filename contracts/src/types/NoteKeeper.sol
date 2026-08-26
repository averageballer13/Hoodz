// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @dev UNAUDITED. Do not use in production without a full audit.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IHoodzAuthority} from "../interfaces/IHoodzAuthority.sol";
import {IgHOODZ} from "../interfaces/IgHOODZ.sol";
import {IStaking} from "../interfaces/IStaking.sol";
import {ITreasury} from "../interfaces/ITreasury.sol";
import {INoteKeeper} from "../interfaces/INoteKeeper.sol";
import {FrontEndRewarder} from "./FrontEndRewarder.sol";

/**
 * @title  NoteKeeper
 * @author Hoodz
 * @notice Vesting-note bookkeeping for Hoodz bond markets.
 * @dev    Port of the Olympus V2 NoteKeeper.
 *
 *         Payout is stored in gHOODZ terms: on deposit the HOODZ payout is minted by the
 *         treasury, staked, and held by this contract as gHOODZ, so a vesting bond keeps
 *         earning rebases until it is redeemed.
 *
 *         Hoodz deviation: the shared IStaking surface exposes no unwrap(), so a
 *         redemption with _sendgHOODZ == false unstakes the gHOODZ into liquid HOODZ for
 *         the note owner instead of unwrapping it into sHOODZ.
 */
abstract contract NoteKeeper is INoteKeeper, FrontEndRewarder {
    using SafeERC20 for IERC20;

    /* ========== ERRORS ========== */

    /// @notice Thrown when a caller is neither governor, guardian nor policy.
    error NoteKeeper_NotAuthorized();

    /// @notice Thrown when the referenced note does not exist.
    error NoteKeeper_NoteNotFound(address owner, uint256 index);

    /// @notice Thrown when pulling a note that was never pushed to the caller.
    error NoteKeeper_TransferNotFound(address owner, uint256 index);

    /// @notice Thrown when pulling a note that has already been redeemed.
    error NoteKeeper_NoteRedeemed(address owner, uint256 index);

    /// @notice Thrown when the zero address is passed where a real address is required.
    error NoteKeeper_ZeroAddress();

    /* ========== EVENTS ========== */

    /// @notice Emitted when the treasury pointer is re-synced with the authority vault.
    event TreasuryUpdated(address indexed treasury);

    /* ========== STATE ========== */

    /// @notice Every note ever created, per owner.
    mapping(address => Note[]) public notes;

    /// @dev Owner => note index => address approved to pull the note.
    mapping(address => mapping(uint256 => address)) private noteTransfers;

    /// @notice gHOODZ, the vesting denomination of every note.
    IgHOODZ internal immutable gHOODZ;

    /// @notice Staking contract used to stake payouts and unstake redemptions.
    IStaking internal immutable staking;

    /// @notice Treasury that mints bond payouts. Re-syncable via updateTreasury.
    ITreasury internal treasury;

    /* ========== CONSTRUCTOR ========== */

    /**
     * @param _authority Hoodz authority contract.
     * @param _hoodz      HOODZ token.
     * @param _gHOODZ     gHOODZ token.
     * @param _staking   Hoodz staking contract.
     * @param _treasury  Hoodz treasury.
     */
    constructor(
        IHoodzAuthority _authority,
        IERC20 _hoodz,
        IgHOODZ _gHOODZ,
        IStaking _staking,
        ITreasury _treasury
    ) FrontEndRewarder(_authority, _hoodz) {
        if (address(_gHOODZ) == address(0) || address(_staking) == address(0) || address(_treasury) == address(0)) {
            revert NoteKeeper_ZeroAddress();
        }
        gHOODZ = _gHOODZ;
        staking = _staking;
        treasury = _treasury;
    }

    /* ========== TREASURY ========== */

    /**
     * @notice Re-point the treasury at the current authority vault.
     * @dev    Callable by governor, guardian or policy. Mirrors the Olympus escape hatch
     *         for when the vault address changes on the authority.
     */
    function updateTreasury() external {
        if (
            msg.sender != authority.governor() && msg.sender != authority.guardian()
                && msg.sender != authority.policy()
        ) revert NoteKeeper_NotAuthorized();

        address vault = authority.vault();
        treasury = ITreasury(vault);

        emit TreasuryUpdated(vault);
    }

    /* ========== ADD ========== */

    /**
     * @notice Create a note for a user, mint the payout plus front end rewards, and stake the payout.
     * @dev    Internal: called by the bond depository once a deposit has been priced.
     * @param _user     Owner of the new note.
     * @param _payout   HOODZ owed to the user.
     * @param _expiry   Timestamp the note matures.
     * @param _marketID Market the deposit came from.
     * @param _referral Front end operator credited for the deposit.
     * @return index_ Index of the new note in the user note array.
     */
    function addNote(address _user, uint256 _payout, uint48 _expiry, uint48 _marketID, address _referral)
        internal
        returns (uint256 index_)
    {
        if (_user == address(0)) revert NoteKeeper_ZeroAddress();

        index_ = notes[_user].length;

        // payout is denominated in gHOODZ so the note keeps compounding while it vests
        uint256 payoutInG = gHOODZ.balanceTo(_payout);

        notes[_user].push(
            Note({
                payout: payoutInG,
                created: uint48(block.timestamp),
                matured: _expiry,
                redeemed: 0,
                marketID: _marketID
            })
        );

        // front end operators and the DAO earn a share of every payout
        uint256 rewards_ = _giveRewards(_payout, _referral);

        // mint payout + rewards, then stake only the payout (rewards stay liquid HOODZ)
        treasury.mint(address(this), _payout + rewards_);
        staking.stake(address(this), _payout, false, true);

        emit NoteCreated(_user, _marketID, index_, payoutInG, _expiry);
    }

    /* ========== REDEEM ========== */

    /**
     * @notice Redeem a specific set of matured notes for a user.
     * @dev    Non-matured indexes are skipped rather than reverting, matching Olympus.
     * @param _user      Owner of the notes.
     * @param _indexes   Indexes to redeem.
     * @param _sendgHOODZ True to receive gHOODZ, false to unstake into liquid HOODZ.
     * @return payout_   Total gHOODZ credited.
     */
    function redeem(address _user, uint256[] memory _indexes, bool _sendgHOODZ)
        public
        override
        returns (uint256 payout_)
    {
        uint48 time = uint48(block.timestamp);
        uint256 length = _indexes.length;

        for (uint256 i; i < length; ++i) {
            (uint256 pay, bool matured) = pendingFor(_user, _indexes[i]);

            if (matured) {
                notes[_user][_indexes[i]].redeemed = time;
                payout_ += pay;
            }
        }

        if (payout_ != 0) {
            if (_sendgHOODZ) {
                IERC20(address(gHOODZ)).safeTransfer(_user, payout_);
            } else {
                // burn the gHOODZ held here and forward the underlying HOODZ to the owner
                staking.unstake(_user, payout_, false, false);
            }
        }

        emit NoteRedeemed(_user, payout_, _sendgHOODZ);
    }

    /**
     * @notice Redeem every outstanding note held by a user.
     * @param _user      Owner of the notes.
     * @param _sendgHOODZ True to receive gHOODZ, false to unstake into liquid HOODZ.
     * @return payout_   Total gHOODZ credited.
     */
    function redeemAll(address _user, bool _sendgHOODZ) external override returns (uint256 payout_) {
        payout_ = redeem(_user, indexesFor(_user), _sendgHOODZ);
    }

    /* ========== TRANSFER ========== */

    /**
     * @notice Offer one of the caller notes to a new owner.
     * @dev    The recipient completes the transfer with pullNote.
     * @param _to    Address allowed to pull the note.
     * @param _index Index of the caller note.
     */
    function pushNote(address _to, uint256 _index) external override {
        if (_index >= notes[msg.sender].length || notes[msg.sender][_index].created == 0) {
            revert NoteKeeper_NoteNotFound(msg.sender, _index);
        }
        if (_to == address(0)) revert NoteKeeper_ZeroAddress();

        noteTransfers[msg.sender][_index] = _to;

        emit NotePushed(msg.sender, _to, _index);
    }

    /**
     * @notice Claim a note that was pushed to the caller.
     * @param _from  Current owner of the note.
     * @param _index Index of the note in the owner array.
     * @return newIndex_ Index of the note in the caller array.
     */
    function pullNote(address _from, uint256 _index) external override returns (uint256 newIndex_) {
        if (noteTransfers[_from][_index] != msg.sender) revert NoteKeeper_TransferNotFound(_from, _index);
        if (notes[_from][_index].redeemed != 0) revert NoteKeeper_NoteRedeemed(_from, _index);

        newIndex_ = notes[msg.sender].length;
        notes[msg.sender].push(notes[_from][_index]);

        delete noteTransfers[_from][_index];
        delete notes[_from][_index];

        emit NotePulled(_from, msg.sender, _index, newIndex_);
    }

    /* ========== VIEW ========== */

    /**
     * @notice All indexes of a user notes that have not been redeemed yet.
     * @param _user Note owner.
     * @return Array of live note indexes.
     */
    function indexesFor(address _user) public view override returns (uint256[] memory) {
        Note[] memory info = notes[_user];
        uint256 total = info.length;

        uint256 length;
        for (uint256 i; i < total; ++i) {
            if (info[i].redeemed == 0 && info[i].payout != 0) ++length;
        }

        uint256[] memory indexes = new uint256[](length);
        uint256 position;

        for (uint256 i; i < total; ++i) {
            if (info[i].redeemed == 0 && info[i].payout != 0) {
                indexes[position] = i;
                ++position;
            }
        }

        return indexes;
    }

    /**
     * @notice Payout and maturity status of a single note.
     * @param _user  Note owner.
     * @param _index Index of the note.
     * @return payout_  gHOODZ owed by the note.
     * @return matured_ True when the note is redeemable right now.
     */
    function pendingFor(address _user, uint256 _index) public view override returns (uint256 payout_, bool matured_) {
        Note memory note = notes[_user][_index];

        payout_ = note.payout;
        matured_ = note.redeemed == 0 && note.matured <= block.timestamp && note.payout != 0;
    }
}
