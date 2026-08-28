# Hoodz — On-chain Governance

> **UNAUDITED.** Educational re-implementation of the Olympus DAO governance stack, rebranded as
> Hoodz and targeted at **Robinhood Chain** (EVM, chainId `4663` / testnet `46630`).
> Do not deploy with real value at risk before a full audit.

Two contracts live here:

| File | What it is |
| ---- | ---------- |
| `HoodzGovernor.sol` | OpenZeppelin v5 `Governor` over **gHOOD**. Proposal creation, voting, counting, queueing. |
| `HoodzTimelock.sol` | `TimelockController` with a hard-coded **2-day** minimum delay. Executes everything that passes. |

`HoodzGovernor` is the *decision* layer. `HoodzTimelock` is the *execution* layer and the account
that actually owns the protocol: it is the address wired in as the `governor` role of
`HoodzAuthority`, which makes it the ultimate controller of the Hoodz Treasury, staking, bonding,
the distributor and Hoodz Loans.

```
gHOOD holders ──delegate──▶ voting power
                              │
                              ▼
                       HoodzGovernor  ──queue──▶  HoodzTimelock  ──execute──▶  HoodzAuthority
                                                  (2 days)                    │  governor
                                                                              ├─▶ Treasury
                                                                              ├─▶ Staking / Distributor
                                                                              ├─▶ Bonding
                                                                              └─▶ Hoodz Loans
```

---

## 1. Parameters

gHOOD does **not** override `clock()` / `CLOCK_MODE()`, so it uses the ERC-6372 **default
block-number clock** (`mode=blocknumber&from=default`). `GovernorVotes.clock()` mirrors the token,
which means the governor's two windows are denominated in **blocks**, not seconds. Robinhood Chain
produces a block roughly every **2 seconds**:

| Parameter | Value | Wall clock | Source |
| --------- | ----- | ---------- | ------ |
| `votingDelay()` | `43,200` blocks | ~1 day | `GovernorSettings` |
| `votingPeriod()` | `216,000` blocks | ~5 days | `GovernorSettings` |
| `proposalThreshold()` | `1_000e18` gHOOD | — | `GovernorSettings` |
| `quorumNumerator()` / `quorumDenominator()` | `4` / `100` → **4%** of gHOOD supply at the snapshot | — | `GovernorVotesQuorumFraction` |
| `MIN_DELAY` | `2 days` | ~2 days | `HoodzTimelock` (timestamp-based) |

Worst-case time from `propose()` to state change: **~1 day + ~5 days + 2 days ≈ 8 days.**

The timelock delay is the one value here measured in *seconds* — `TimelockController` uses
`block.timestamp`, so it is unaffected by block cadence. The governor's windows are not: if
Robinhood Chain ever changes its block time, the three `GovernorSettings` values must be re-tuned
through a proposal (`setVotingDelay`, `setVotingPeriod`, `setProposalThreshold` — all
`onlyGovernance`, i.e. callable only by the timelock, i.e. only via a passed proposal).

`HoodzGovernor` exposes `votingDelaySeconds()`, `votingPeriodSeconds()` and `currentQuorum()` as
read-only conveniences for the dApp; the block-denominated getters remain authoritative.

---

## 2. Where voting power comes from: HOOD → sHOOD → gHOOD

Voting power is **gHOOD**, never HOOD and never sHOOD.

1. **HOOD** is the bare, permissionless ERC-20 launched on PONS. It has no `ERC20Votes` extension
   and therefore carries **zero** governance weight. Holding HOOD in a wallet, an LP position or
   the PONS curve gives you no vote.
2. **Staking.** `IStaking.stake(to, amount, rebasing, claim)` deposits HOOD into the staking
   contract. Passing `rebasing = true` mints **sHOOD**; passing `rebasing = false` mints **gHOOD**
   directly.
3. **sHOOD** is the rebasing receipt: balance-elastic, always ~1:1 with the HOOD you are owed, and
   it grows every epoch when the distributor calls `rebase()`. sHOOD is *not* an `ERC20Votes`
   token — a rebasing balance cannot be checkpointed coherently, because everyone's balance
   changes in a single write with no transfer event per holder.
4. **gHOOD** is the index-bearing wrapper: balance-static, value-elastic. Conversion uses the
   staking index:

   ```
   gHOOD = sHOOD / index      // IgHOOD.balanceTo(sHOODAmount)
   sHOOD = gHOOD * index      // IgHOOD.balanceFrom(gHOODAmount)
   ```

   `index()` only ever increases (each rebase raises it), so **1 gHOOD is a permanently constant
   share of the staking pool**. That is precisely the property `ERC20Votes` needs: balances change
   only on mint, burn and transfer, so every change is checkpointable.

The consequence worth internalising: **rebases do not dilute or inflate anyone's vote.** A holder
who wraps into gHOOD and never touches it again keeps exactly the same fraction of total voting
power forever, while the HOOD value behind those gHOOD compounds with the index. Sitting in sHOOD
instead means you have a growing token balance and *no vote at all* until you wrap.

### Getting a vote, step by step

```solidity
// 1. stake HOOD, receiving gHOOD directly (rebasing = false, claim = true)
hoodz.approve(address(staking), amount);
staking.stake(msg.sender, amount, false, true);

// 2. ACTIVATE the voting power — gHOOD balance alone counts for nothing
ghoodz.delegate(msg.sender);            // self-delegate, or delegate(someoneElse)
```

> **`delegate()` is not optional.** `ERC20Votes` tracks *delegated* votes. An undelegated gHOOD
> balance reports `getVotes(holder) == 0`. Self-delegation is a one-time transaction per address;
> after it, transfers in and out of the address move voting power automatically. Delegation is
> also revocable and re-assignable at any time, and it never moves the tokens themselves.

`delegateBySig(delegatee, nonce, expiry, v, r, s)` is available for gasless delegation, using the
`Nonces` counter that gHOOD inherits.

### Snapshots

Voting weight for a proposal is read with `getPastVotes(account, proposalSnapshot(proposalId))`,
where `proposalSnapshot = <creation block> + votingDelay`. Two implications:

* Delegating (or acquiring gHOOD) **after** the snapshot block does nothing for that proposal.
  The ~1-day `votingDelay` exists exactly so holders have time to wrap and delegate before the
  snapshot locks.
* Quorum is `4%` of `getPastTotalSupply(snapshot)` — the gHOOD supply at that same block, not the
  current one.

---

## 3. Proposal lifecycle

A proposal is an array of calls: `targets[]`, `values[]`, `calldatas[]`, plus a human-readable
`description`. Its id is deterministic:

```
proposalId = getProposalId(targets, values, calldatas, keccak256(bytes(description)))
```

Because the id is a hash of the *content*, the same batch with the same description can only ever
exist once.

```
propose()                     castVote()                  queue()            execute()
   │                              │                          │                   │
   ▼        43,200 blocks         ▼      216,000 blocks      ▼     2 days        ▼
Pending ─────────────────────▶ Active ──────────────────▶ Succeeded ───────▶ Queued ───▶ Executed
                                  │                          │                   │
                                  └──────────────────────▶ Defeated              │
                                                                                 │
   cancel() (proposer, while Pending) / timelock CANCELLER ─────────────────▶ Canceled
```

| State | Meaning |
| ----- | ------- |
| `Pending` | Created; the snapshot block has not been reached. No votes accepted yet. |
| `Active` | Snapshot passed, deadline not reached. `castVote` / `castVoteWithReason` / `castVoteBySig` accepted. |
| `Defeated` | Deadline passed and either quorum was missed or `For <= Against`. Terminal. |
| `Succeeded` | Deadline passed, quorum reached, `For > Against`. Waiting to be queued. |
| `Queued` | Scheduled on `HoodzTimelock`; `proposalEta()` is the timestamp it becomes executable. |
| `Executed` | The timelock ran the batch. Terminal. |
| `Canceled` | Cancelled by the proposer while `Pending`, or by a timelock `CANCELLER_ROLE` holder after queueing. Terminal. |

(`Expired` exists in the OZ enum but is unreachable in this configuration: `TimelockController`
has no grace period, so a ready operation stays executable indefinitely.)

### 3.1 Propose

```solidity
uint256 id = governor.propose(targets, values, calldatas, "HIP-1: raise the reward rate to 0.30%");
```

* Requires `governor.getVotes(msg.sender, clock() - 1) >= proposalThreshold()` — **1,000 gHOOD** of
  *delegated* voting power at the previous block.
* The description may end with `#proposer=0x<address>` to lock proposal submission to a single
  address (OZ v5 `_isValidDescriptionForProposer`), which is useful when the batch is front-runnable.
* Emits `ProposalCreated` with the snapshot and deadline blocks.

### 3.2 Vote

`GovernorCountingSimple` — three options:

| `support` | Meaning | Counts toward quorum? | Counts toward success? |
| --------- | ------- | --------------------- | ---------------------- |
| `0` | Against | no | yes (against) |
| `1` | For | yes | yes (for) |
| `2` | Abstain | yes | no |

```solidity
governor.castVote(id, 1);
governor.castVoteWithReason(id, 0, "treasury runway is too short for this");
governor.castVoteBySig(id, 1, voter, signature);   // EIP-712 domain: "Hoodz Governor"
```

Success requires **both**: `For + Abstain >= quorum(snapshot)` **and** `For > Against`. One vote
per address per proposal — `hasVoted(id, account)` is permanent, and votes cannot be changed.

### 3.3 Queue

```solidity
governor.queue(targets, values, calldatas, descriptionHash);
```

Permissionless once the proposal is `Succeeded`. It calls `scheduleBatch` on `HoodzTimelock` with
`delay = timelock.getMinDelay()` (2 days) and a salt derived from `address(governor)` and the
description hash. `proposalEta(id)` then returns the earliest execution timestamp.

The 2-day window is the **exit window**: it is the last moment for the guardian to cancel a
malicious batch, and for stakers to unstake before a hostile parameter change lands.

### 3.4 Execute

```solidity
governor.execute(targets, values, calldatas, descriptionHash);   // payable
```

Permissionless once the ETA has passed (assuming `EXECUTOR_ROLE` is open — see §4). The calls are
forwarded through `HoodzTimelock.executeBatch`, so from the protocol's point of view **`msg.sender`
is the timelock**, which is why the timelock — not the governor — must hold the `governor` role in
`HoodzAuthority`.

### 3.5 Cancel

* `governor.cancel(...)` — the proposer only, and only while the proposal is `Pending`.
* `timelock.cancel(operationId)` — any `CANCELLER_ROLE` holder, on an already-queued batch. Give
  this role to the governor and to the Hoodz guardian multisig so an emergency stop exists inside
  the 2-day window.

---

## 4. Deployment and role wiring

Order matters: the governor needs the timelock's address at construction, and the timelock needs
the governor's address as its proposer, so one of the two links is set after deployment by the
bootstrap admin.

```solidity
// 1. timelock, with the deployer as temporary proposer + admin and an open executor set.
//    HoodzTimelock reverts with HoodzTimelock__NoProposer() on an empty proposer set, so the
//    deployer takes the seat and hands it to the governor in step 3.
address[] memory proposers = new address[](1);
proposers[0] = deployer;
address[] memory executors = new address[](1);
executors[0] = address(0);                       // anyone may execute a ready batch
HoodzTimelock timelock = new HoodzTimelock(proposers, executors, deployer);

// 2. governor over gHOOD
HoodzGovernor governor = new HoodzGovernor(IVotes(address(gHOOD)), timelock);

// 3. the governor becomes the only proposer / canceller
timelock.grantRole(timelock.PROPOSER_ROLE(),  address(governor));
timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
timelock.grantRole(timelock.CANCELLER_ROLE(), guardianMultisig);   // emergency stop

// 4. drop the bootstrap keys — the constructor granted the deployer BOTH proposer and canceller
timelock.revokeRole(timelock.PROPOSER_ROLE(),      deployer);
timelock.revokeRole(timelock.CANCELLER_ROLE(),     deployer);
timelock.revokeRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);      // timelock is now self-administered

// 5. hand the protocol over: the TIMELOCK is the governor of HoodzAuthority
authority.pushGovernor(address(timelock), true);
```

Verify with `timelock.isSelfAdministered(deployer) == true` and
`timelock.isOpenExecutor() == true`.

| Role | Holder | Why |
| ---- | ------ | --- |
| `PROPOSER_ROLE` | `HoodzGovernor` only | Nothing reaches the timelock except through a passed vote. |
| `CANCELLER_ROLE` | `HoodzGovernor` + guardian multisig | Emergency stop inside the 2-day window. |
| `EXECUTOR_ROLE` | `address(0)` (open) | Anyone can push a ready batch; no keeper liveness assumption. |
| `DEFAULT_ADMIN_ROLE` | nobody, after step 4 | Role changes must themselves go through a proposal. |
| `HoodzAuthority.governor` | `HoodzTimelock` | Proposals execute *from* the timelock, so it is the caller the protocol sees. |

The `guardian` / `policy` / `vault` roles of `HoodzAuthority` stay with their multisigs — governance
does not replace them, it owns the right to *change* them. `vault` in particular is the HOOD mint
authority, and per the PONS launch rules it may only move to the Treasury **after** the bonding
curve has graduated (`HoodzLaunchGuard` enforces this on-chain).

---

## 5. Frontend integration notes

Everything the governance page needs is on-chain:

```solidity
governor.name();                              // "Hoodz Governor"
governor.token();                             // gHOOD
governor.timelock();                          // HoodzTimelock
governor.clock();                             // current block number
governor.CLOCK_MODE();                        // "mode=blocknumber&from=default"
governor.COUNTING_MODE();                     // "support=bravo&quorum=for,abstain"

governor.state(id);                           // enum above
governor.proposalSnapshot(id);                // snapshot block
governor.proposalDeadline(id);                // last block that accepts votes
governor.proposalEta(id);                     // timestamp executable (0 until queued)
governor.proposalVotes(id);                   // (against, for, abstain)
governor.quorum(governor.proposalSnapshot(id));
governor.hasVoted(id, account);

ghoodz.getVotes(account);                      // 0 until delegate() is called
ghoodz.delegates(account);                     // address(0) == not delegated, warn the user
ghoodz.getPastVotes(account, snapshot);        // weight for a specific proposal
```

Block numbers are not timestamps: to render "voting ends in ~3 days", convert with
`(deadlineBlock - currentBlock) * 2` seconds, or read `governor.votingPeriodSeconds()`. Treat the
result as an estimate and label it as one.

Two UX rules that prevent most support tickets:

1. If `ghoodz.delegates(user) == address(0)`, show a **"Activate voting power"** call-to-action
   before showing any vote button — the user has gHOOD but zero votes.
2. If the user holds sHOOD, show **"Wrap to gHOOD to vote"** with the live conversion
   (`ghoodz.balanceTo(sHOODAmount)`), and be explicit that wrapping does not unstake and does not
   forfeit rebase yield.

---

## 6. Known properties and limitations

* **Flash-loan resistance.** Voting weight is read at a past block via checkpoints, and the
  proposal threshold at `clock() - 1`, so a same-block borrow cannot create voting power.
* **Vote buying is not prevented.** Delegation is free and revocable; gHOOD lending markets can
  rent voting power. This is inherent to `ERC20Votes`, not specific to Hoodz.
* **No quorum decay, no vote weighting by lock time.** Quorum is a flat 4% of gHOOD supply at the
  snapshot. If gHOOD supply is small at launch, 4% is a small absolute number — consider raising
  the numerator by proposal once the staking pool matures.
* **The 2-day timelock is the only forced delay on execution.** A proposal that changes the
  timelock delay itself still has to serve the *current* delay first.
* **Governor upgrades are migrations, not upgrades.** Neither contract is proxied. Replacing the
  governor means deploying a new one, granting it `PROPOSER_ROLE` on the existing timelock and
  revoking the old one — all through a proposal executed by the current governor.
* **UNAUDITED.** Both files carry the banner. Treat every number above as a starting point to be
  reviewed, not as a validated production configuration.
