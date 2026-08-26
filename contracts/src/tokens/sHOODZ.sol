// SPDX-License-Identifier: AGPL-3.0-or-later
// UNAUDITED. Do not use in production without a full audit.
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
        X      https://x.com/hoodzdao
        Code   https://github.com/averageballer13/Hoodz

        UNAUDITED. This code has never been audited. Read it before you
        trust it with anything you would miss.
*/

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

import {IsHOODZ} from "../interfaces/IsHOODZ.sol";
import {IgHOODZ} from "../interfaces/IgHOODZ.sol";
import {IHoodzAuthority} from "../interfaces/IHoodzAuthority.sol";
import {HoodzAccessControlled} from "../types/HoodzAccessControlled.sol";

/// @title  sHOODZ
/// @notice Staked HOODZ: a rebasing receipt token (9 decimals) that grows every epoch.
/// @dev    UNAUDITED. Do not use in production without a full audit.
///
///         GONS ACCOUNTING (faithful port of sOHM)
///         --------------------------------------
///         A holder owns a fixed number of "gons" out of a constant TOTAL_GONS. The visible
///         balance is that share of the current supply:
///
///             balanceOf(who)    = _gonBalances[who] / _gonsPerFragment
///             gonsForBalance(a) = a * _gonsPerFragment
///             balanceForGons(g) = g / _gonsPerFragment
///
///         A rebase therefore never touches a single balance: it raises _totalSupply and then
///         recomputes _gonsPerFragment = TOTAL_GONS / _totalSupply, which re-prices every gon at
///         once. Transfers convert the fragment amount into gons at the CURRENT rate before
///         moving it, so a transfer is rebase-neutral.
///
///         TOTAL_GONS is the largest multiple of INITIAL_FRAGMENTS_SUPPLY that fits in a uint256,
///         so _gonsPerFragment starts as an exact integer and stays maximally granular. The
///         MAX_SUPPLY cap keeps amount * _gonsPerFragment inside a uint256 forever.
/// @notice The single view {sHOODZ} needs from the staking contract.
/// @dev Declared locally rather than widening `IStaking`, which every other contract depends on.
///      `supplyInWarmup()` is a pure view over `gonsInWarmup` and never re-enters.
interface IWarmupSupply {
    /// @return sHOODZ held by the staking contract on behalf of depositors still in warmup.
    function supplyInWarmup() external view returns (uint256);
}

contract sHOODZ is IsHOODZ, IERC20Metadata, EIP712, Nonces, HoodzAccessControlled {
    /* ========================================= ERRORS ========================================= */

    /// @notice Caller is not the staking contract.
    error sHOODZ_OnlyStaking(address caller);
    /// @notice Caller is not the treasury.
    error sHOODZ_OnlyTreasury(address caller);
    /// @notice A zero address was supplied where a real address is required.
    error sHOODZ_ZeroAddress();
    /// @notice A one-shot setter was called twice.
    error sHOODZ_AlreadySet();
    /// @notice Balance is too small for the requested operation.
    error sHOODZ_InsufficientBalance(address from, uint256 balance, uint256 needed);
    /// @notice Allowance is too small for the requested transferFrom.
    error sHOODZ_InsufficientAllowance(address spender, uint256 currentAllowance, uint256 needed);
    /// @notice The operation would leave the account unable to cover its treasury debt.
    error sHOODZ_DebtOutstanding(address account, uint256 debt);
    /// @notice The permit signature is past its deadline.
    error sHOODZ_ExpiredSignature(uint256 deadline);
    /// @notice The permit signature does not belong to the owner.
    error sHOODZ_InvalidSigner(address signer, address owner);

    /* ========================================= EVENTS ========================================= */

    /// @notice Emitted after every rebase with the resulting supply.
    event LogSupply(uint256 indexed epoch, uint256 totalSupply);
    /// @notice Emitted after every rebase with the growth rate (18 decimals) and the new index.
    event LogRebase(uint256 indexed epoch, uint256 rebase, uint256 index);
    /// @notice Emitted once when the staking contract is wired in.
    event LogStakingContractUpdated(address stakingContract);
    /// @notice Emitted when the treasury moves an account debt balance.
    event LogDebtChanged(address indexed debtor, uint256 amount, bool add);

    /* ========================================= STRUCTS ======================================== */

    /// @notice One historical rebase.
    struct Rebase {
        uint256 epoch;
        uint256 rebase; // 18 decimals: profit / circulating supply before the rebase
        uint256 totalStakedBefore;
        uint256 totalStakedAfter;
        uint256 amountRebased;
        uint256 index;
        uint256 blockNumberOccured;
    }

    /* ======================================== CONSTANTS ======================================= */

    /// @dev sHOODZ mirrors HOODZ: 9 decimals.
    uint8 private constant DECIMALS = 9;

    uint256 private constant MAX_UINT256 = type(uint256).max;

    /// @dev Genesis supply: 5,000,000 sHOODZ at 9 decimals (same seed as sOHM).
    uint256 private constant INITIAL_FRAGMENTS_SUPPLY = 5_000_000 * 10 ** 9;

    /// @dev Largest multiple of INITIAL_FRAGMENTS_SUPPLY representable in a uint256.
    uint256 private constant TOTAL_GONS = MAX_UINT256 - (MAX_UINT256 % INITIAL_FRAGMENTS_SUPPLY);

    /// @dev Supply ceiling, keeps every gons conversion inside a uint256.
    uint256 private constant MAX_SUPPLY = type(uint128).max;

    /// @dev EIP-2612 permit type hash.
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    /* ========================================== STATE ========================================= */

    /// @notice The staking contract: the only rebase caller, holder of the unstaked supply.
    address public stakingContract;

    /// @notice The Hoodz Treasury, allowed to record debt against staked balances.
    address public treasury;

    /// @notice The non-rebasing wrapper minted against sHOODZ held by the staking contract.
    IgHOODZ public gHOODZ;

    /// @notice Every rebase ever executed, oldest first.
    Rebase[] public rebases;

    /// @dev Gons value of one index unit; index() = balanceForGons(INDEX).
    uint256 private INDEX;

    uint256 private _totalSupply;
    uint256 private _gonsPerFragment;

    mapping(address => uint256) private _gonBalances;
    mapping(address => mapping(address => uint256)) private _allowedValue;

    /// @notice HOODZ-denominated debt each account owes the treasury against its staked balance.
    mapping(address => uint256) public debtBalances;

    /* ======================================== MODIFIERS ======================================= */

    /// @dev Restricts to the staking contract.
    modifier onlyStakingContract() {
        if (msg.sender != stakingContract) revert sHOODZ_OnlyStaking(msg.sender);
        _;
    }

    /* ======================================= CONSTRUCTOR ====================================== */

    /// @param _authority Address of the HoodzAuthority.
    constructor(IHoodzAuthority _authority) EIP712("Staked Hoodz", "1") HoodzAccessControlled(_authority) {
        _totalSupply = INITIAL_FRAGMENTS_SUPPLY;
        _gonsPerFragment = TOTAL_GONS / _totalSupply;
    }

    /* ===================================== INITIALISATION ===================================== */

    /// @notice Set the genesis index, once. Stored in gons so index() tracks rebase growth.
    /// @param _index Starting index in sHOODZ terms, 9 decimals (1e9 for a fresh launch).
    function setIndex(uint256 _index) external onlyGovernor {
        if (INDEX != 0) revert sHOODZ_AlreadySet();
        INDEX = gonsForBalance(_index);
    }

    /// @notice Set the gHOODZ wrapper, once.
    /// @param _gHOODZ Address of the gHOODZ token.
    function setgHOODZ(address _gHOODZ) external onlyGovernor {
        if (address(gHOODZ) != address(0)) revert sHOODZ_AlreadySet();
        if (_gHOODZ == address(0)) revert sHOODZ_ZeroAddress();
        gHOODZ = IgHOODZ(_gHOODZ);
    }

    /// @notice Hand the entire supply to the staking contract and wire the treasury, once.
    /// @param _stakingContract Address of the Hoodz staking contract.
    /// @param _treasury        Address of the Hoodz Treasury.
    /// @return The total supply now held by the staking contract, 9 decimals.
    function initialize(address _stakingContract, address _treasury) external onlyGovernor returns (uint256) {
        if (stakingContract != address(0)) revert sHOODZ_AlreadySet();
        if (_stakingContract == address(0) || _treasury == address(0)) revert sHOODZ_ZeroAddress();

        stakingContract = _stakingContract;
        treasury = _treasury;
        _gonBalances[_stakingContract] = TOTAL_GONS;

        emit Transfer(address(0), _stakingContract, _totalSupply);
        emit LogStakingContractUpdated(_stakingContract);

        return _totalSupply;
    }

    /* ========================================= REBASE ========================================= */

    /// @notice Increase the supply by profit_, distributing it pro-rata to every sHOODZ holder.
    /// @dev    Only the staking contract may call this, once per epoch.
    /// @param profit_ HOODZ added to the staked pool this epoch, 9 decimals.
    /// @param epoch_  Epoch number this rebase belongs to.
    /// @return The new total supply, 9 decimals.
    function rebase(uint256 profit_, uint256 epoch_) public override onlyStakingContract returns (uint256) {
        uint256 rebaseAmount;
        uint256 circulatingSupply_ = circulatingSupply();

        if (profit_ == 0) {
            emit LogSupply(epoch_, _totalSupply);
            emit LogRebase(epoch_, 0, index());
            return _totalSupply;
        } else if (circulatingSupply_ > 0) {
            // Scale the profit up so holders - not the staking contract reserve - capture it.
            rebaseAmount = (profit_ * _totalSupply) / circulatingSupply_;
        } else {
            rebaseAmount = profit_;
        }

        _totalSupply += rebaseAmount;
        if (_totalSupply > MAX_SUPPLY) _totalSupply = MAX_SUPPLY;

        // Re-price every gon in a single division: this IS the rebase.
        _gonsPerFragment = TOTAL_GONS / _totalSupply;

        _storeRebase(circulatingSupply_, profit_, epoch_);

        return _totalSupply;
    }

    /// @dev Append the rebase to history and emit the supply / growth logs.
    function _storeRebase(uint256 previousCirculating_, uint256 profit_, uint256 epoch_) internal {
        // 18-decimal growth rate. Guarded: at genesis the circulating supply can still be zero.
        uint256 rebasePercent = previousCirculating_ > 0 ? (profit_ * 1e18) / previousCirculating_ : 0;

        rebases.push(
            Rebase({
                epoch: epoch_,
                rebase: rebasePercent,
                totalStakedBefore: previousCirculating_,
                totalStakedAfter: circulatingSupply(),
                amountRebased: profit_,
                index: index(),
                blockNumberOccured: block.number
            })
        );

        emit LogSupply(epoch_, _totalSupply);
        emit LogRebase(epoch_, rebasePercent, index());
    }

    /* ========================================== VIEWS ========================================= */

    /// @notice Token name.
    /// @return The token name.
    function name() public pure override returns (string memory) {
        return "Staked Hoodz";
    }

    /// @notice Token symbol.
    /// @return The token symbol.
    function symbol() public pure override returns (string memory) {
        return "sHOODZ";
    }

    /// @notice Number of decimals used by sHOODZ.
    /// @return Always 9.
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }

    /// @notice Total sHOODZ supply, including the reserve held by the staking contract.
    /// @return The total supply, 9 decimals.
    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    /// @notice Balance of an account, derived from its gons at the current rate.
    /// @param who_ Account to query.
    /// @return The balance, 9 decimals.
    function balanceOf(address who_) public view override returns (uint256) {
        return _gonBalances[who_] / _gonsPerFragment;
    }

    /// @notice Raw gon balance of an account, immune to rebases.
    /// @param who_ Account to query.
    /// @return The gon balance.
    function scaledBalanceOf(address who_) external view returns (uint256) {
        return _gonBalances[who_];
    }

    /// @notice Convert an sHOODZ amount into gons at the current rate.
    /// @param amount_ sHOODZ amount, 9 decimals.
    /// @return The equivalent number of gons.
    function gonsForBalance(uint256 amount_) public view override returns (uint256) {
        return amount_ * _gonsPerFragment;
    }

    /// @notice Convert gons into an sHOODZ amount at the current rate.
    /// @param gons_ Number of gons.
    /// @return The equivalent sHOODZ amount, 9 decimals.
    function balanceForGons(uint256 gons_) public view override returns (uint256) {
        return gons_ / _gonsPerFragment;
    }

    /// @notice Supply owned by users rather than parked in the staking contract.
    /// @dev    Two slices live inside `balanceOf(stakingContract)` but are economically owned by
    ///         users, so both are added back:
    ///           - sHOODZ wrapped into gHOODZ, which is transferred TO the staking contract;
    ///           - sHOODZ sitting in warmup, still credited to the depositor.
    ///         Omitting the warmup slice would make {HoodzStaking.rebase} read every warmup deposit
    ///         as distributable surplus and hand it to existing stakers, leaving the depositor's
    ///         principal unbacked. This mirrors sOHM exactly.
    /// @return The circulating sHOODZ supply, 9 decimals.
    function circulatingSupply() public view override returns (uint256) {
        uint256 wrapped = address(gHOODZ) == address(0) ? 0 : gHOODZ.balanceFrom(gHOODZ.totalSupply());
        uint256 warmup = stakingContract == address(0) ? 0 : IWarmupSupply(stakingContract).supplyInWarmup();
        return _totalSupply - balanceOf(stakingContract) + wrapped + warmup;
    }

    /// @notice Growth-adjusted index: what one sHOODZ staked at genesis is worth today.
    /// @return The index, 9 decimals.
    function index() public view override returns (uint256) {
        return balanceForGons(INDEX);
    }

    /// @notice Convert an sHOODZ amount (9 decimals) into gHOODZ terms (18 decimals).
    /// @param amount_ sHOODZ amount.
    /// @return The equivalent gHOODZ amount.
    function toG(uint256 amount_) external view override returns (uint256) {
        return gHOODZ.balanceTo(amount_);
    }

    /// @notice Convert a gHOODZ amount (18 decimals) into sHOODZ terms (9 decimals).
    /// @param amount_ gHOODZ amount.
    /// @return The equivalent sHOODZ amount.
    function fromG(uint256 amount_) external view override returns (uint256) {
        return gHOODZ.balanceFrom(amount_);
    }

    /// @notice Remaining allowance of a spender over an owner balance.
    /// @param owner_   Token owner.
    /// @param spender_ Approved spender.
    /// @return The remaining allowance, 9 decimals.
    function allowance(address owner_, address spender_) public view override returns (uint256) {
        return _allowedValue[owner_][spender_];
    }

    /// @notice EIP-712 domain separator of this token.
    /// @return The domain separator.
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /* ======================================== TRANSFERS ======================================= */

    /// @notice Move sHOODZ from the caller to another account.
    /// @param to_    Recipient.
    /// @param value_ Amount, 9 decimals.
    /// @return Always true; reverts otherwise.
    function transfer(address to_, uint256 value_) public override returns (bool) {
        _transfer(msg.sender, to_, value_);
        return true;
    }

    /// @notice Move sHOODZ on behalf of an owner, debiting the caller allowance.
    /// @param from_  Token owner.
    /// @param to_    Recipient.
    /// @param value_ Amount, 9 decimals.
    /// @return Always true; reverts otherwise.
    function transferFrom(address from_, address to_, uint256 value_) public override returns (bool) {
        uint256 currentAllowance = _allowedValue[from_][msg.sender];
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < value_) {
                revert sHOODZ_InsufficientAllowance(msg.sender, currentAllowance, value_);
            }
            unchecked {
                _allowedValue[from_][msg.sender] = currentAllowance - value_;
            }
            emit Approval(from_, msg.sender, _allowedValue[from_][msg.sender]);
        }

        _transfer(from_, to_, value_);
        return true;
    }

    /// @dev Convert the fragment amount into gons at the CURRENT rate, then move the gons.
    function _transfer(address from_, address to_, uint256 value_) internal {
        if (to_ == address(0)) revert sHOODZ_ZeroAddress();

        uint256 gonValue = gonsForBalance(value_);
        uint256 fromGons = _gonBalances[from_];
        if (fromGons < gonValue) revert sHOODZ_InsufficientBalance(from_, balanceForGons(fromGons), value_);

        unchecked {
            _gonBalances[from_] = fromGons - gonValue;
        }
        _gonBalances[to_] += gonValue;

        uint256 debt = debtBalances[from_];
        if (debt != 0 && balanceOf(from_) < debt) revert sHOODZ_DebtOutstanding(from_, debt);

        emit Transfer(from_, to_, value_);
    }

    /* ======================================== ALLOWANCES ====================================== */

    /// @notice Approve a spender for an exact amount.
    /// @param spender_ Spender to approve.
    /// @param value_   Allowance, 9 decimals.
    /// @return Always true.
    function approve(address spender_, uint256 value_) public override returns (bool) {
        _approve(msg.sender, spender_, value_);
        return true;
    }

    /// @notice Raise a spender allowance.
    /// @param spender_    Spender to approve.
    /// @param addedValue_ Amount to add, 9 decimals.
    /// @return Always true.
    function increaseAllowance(address spender_, uint256 addedValue_) external returns (bool) {
        _approve(msg.sender, spender_, _allowedValue[msg.sender][spender_] + addedValue_);
        return true;
    }

    /// @notice Lower a spender allowance, flooring at zero.
    /// @param spender_         Spender to reduce.
    /// @param subtractedValue_ Amount to remove, 9 decimals.
    /// @return Always true.
    function decreaseAllowance(address spender_, uint256 subtractedValue_) external returns (bool) {
        uint256 oldValue = _allowedValue[msg.sender][spender_];
        if (subtractedValue_ >= oldValue) {
            _approve(msg.sender, spender_, 0);
        } else {
            unchecked {
                _approve(msg.sender, spender_, oldValue - subtractedValue_);
            }
        }
        return true;
    }

    /// @dev Write an allowance and log it.
    function _approve(address owner_, address spender_, uint256 value_) internal {
        if (owner_ == address(0) || spender_ == address(0)) revert sHOODZ_ZeroAddress();
        _allowedValue[owner_][spender_] = value_;
        emit Approval(owner_, spender_, value_);
    }

    /// @notice EIP-2612: approve a spender with an off-chain signature.
    /// @param owner_    Token owner who signed the permit.
    /// @param spender_  Spender being approved.
    /// @param value_    Allowance, 9 decimals.
    /// @param deadline_ Timestamp after which the signature is void.
    /// @param v_        Signature recovery byte.
    /// @param r_        Signature r value.
    /// @param s_        Signature s value.
    function permit(
        address owner_,
        address spender_,
        uint256 value_,
        uint256 deadline_,
        uint8 v_,
        bytes32 r_,
        bytes32 s_
    ) external {
        if (block.timestamp > deadline_) revert sHOODZ_ExpiredSignature(deadline_);

        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner_, spender_, value_, _useNonce(owner_), deadline_));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), v_, r_, s_);
        if (signer != owner_) revert sHOODZ_InvalidSigner(signer, owner_);

        _approve(owner_, spender_, value_);
    }

    /* ========================================== DEBT ========================================== */

    /// @notice Record or clear treasury debt taken against a staked balance.
    /// @dev    Only the treasury may call this. A debtor cannot transfer below its debt.
    /// @param amount_ Debt delta in HOODZ terms, 9 decimals.
    /// @param debtor_ Account carrying the debt.
    /// @param add_    True to add debt, false to repay it.
    function changeDebt(uint256 amount_, address debtor_, bool add_) external {
        if (msg.sender != treasury) revert sHOODZ_OnlyTreasury(msg.sender);

        uint256 debt = debtBalances[debtor_];
        if (add_) {
            debt += amount_;
        } else {
            if (debt < amount_) revert sHOODZ_InsufficientBalance(debtor_, debt, amount_);
            unchecked {
                debt -= amount_;
            }
        }
        if (debt > balanceOf(debtor_)) revert sHOODZ_DebtOutstanding(debtor_, debt);

        debtBalances[debtor_] = debt;
        emit LogDebtChanged(debtor_, amount_, add_);
    }
}
