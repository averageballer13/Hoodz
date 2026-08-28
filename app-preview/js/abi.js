/* ============================================================================
   HOOD — minimal ABIs + address book
   No build step, no modules: everything hangs off window.HOOD_ABI / HOOD_NET.
   Addresses are 0x0 placeholders until deployment writes docs/deploy.json.
   ========================================================================== */
(function (global) {
  "use strict";

  /* --------------------------------------------------------------- helpers */
  var ZERO = "0x0000000000000000000000000000000000000000";

  function fn(name, inputs, outputs, mutability) {
    return {
      type: "function",
      name: name,
      inputs: inputs || [],
      outputs: outputs || [],
      stateMutability: mutability || "nonpayable"
    };
  }
  function ev(name, inputs) {
    return { type: "event", name: name, inputs: inputs || [], anonymous: false };
  }
  function p(name, type, indexed) {
    var o = { name: name, type: type };
    if (indexed === true) o.indexed = true;
    return o;
  }

  var A = "address", U256 = "uint256", U48 = "uint48", U64 = "uint64",
      U32 = "uint32", U16 = "uint16", U8 = "uint8", B = "bool",
      B32 = "bytes32", BYTES = "bytes", STR = "string";

  /* ERC20 surface shared by HOOD / sHOOD / gHOOD */
  var ERC20 = [
    fn("name", [], [p("", STR)], "view"),
    fn("symbol", [], [p("", STR)], "view"),
    fn("decimals", [], [p("", U8)], "view"),
    fn("totalSupply", [], [p("", U256)], "view"),
    fn("balanceOf", [p("account", A)], [p("", U256)], "view"),
    fn("allowance", [p("owner", A), p("spender", A)], [p("", U256)], "view"),
    fn("approve", [p("spender", A), p("value", U256)], [p("", B)]),
    fn("transfer", [p("to", A), p("value", U256)], [p("", B)]),
    fn("transferFrom", [p("from", A), p("to", A), p("value", U256)], [p("", B)]),
    ev("Transfer", [p("from", A, true), p("to", A, true), p("value", U256)]),
    ev("Approval", [p("owner", A, true), p("spender", A, true), p("value", U256)])
  ];

  function extend(base, extra) { return base.concat(extra); }

  /* ------------------------------------------------------------ 1. HOOD */
  /* IHOOD = IERC20 + mint/burn/burnFrom (9 decimals, like OHM) */
  var HOOD = extend(ERC20, [
    fn("mint", [p("account_", A), p("amount_", U256)]),
    fn("burn", [p("amount", U256)]),
    fn("burnFrom", [p("account_", A), p("amount_", U256)]),
    fn("vault", [], [p("", A)], "view")
  ]);

  /* ----------------------------------------------------------- 2. sHOOD */
  /* Rebasing staked HOOD. Balances are gon-denominated internally. */
  var sHOOD = extend(ERC20, [
    fn("rebase", [p("profit_", U256), p("epoch_", U256)], [p("", U256)]),
    fn("circulatingSupply", [], [p("", U256)], "view"),
    fn("gonsForBalance", [p("amount", U256)], [p("", U256)], "view"),
    fn("balanceForGons", [p("gons", U256)], [p("", U256)], "view"),
    fn("index", [], [p("", U256)], "view"),
    fn("toG", [p("amount", U256)], [p("", U256)], "view"),
    fn("fromG", [p("amount", U256)], [p("", U256)], "view"),
    ev("LogRebase", [p("epoch", U256, true), p("rebase", U256), p("index", U256)])
  ]);

  /* ----------------------------------------------------------- 3. gHOOD */
  /* Non-rebasing wrapper + ERC20Votes governance surface. */
  var gHOOD = extend(ERC20, [
    fn("mint", [p("_to", A), p("_amount", U256)]),
    fn("burn", [p("_from", A), p("_amount", U256)]),
    fn("index", [], [p("", U256)], "view"),
    fn("balanceFrom", [p("_amount", U256)], [p("", U256)], "view"),
    fn("balanceTo", [p("_amount", U256)], [p("", U256)], "view"),
    /* ERC20Votes (OpenZeppelin v5) */
    fn("delegate", [p("delegatee", A)]),
    fn("delegates", [p("account", A)], [p("", A)], "view"),
    fn("getVotes", [p("account", A)], [p("", U256)], "view"),
    fn("getPastVotes", [p("account", A), p("timepoint", U256)], [p("", U256)], "view"),
    fn("nonces", [p("owner", A)], [p("", U256)], "view"),
    ev("DelegateChanged", [p("delegator", A, true), p("fromDelegate", A, true), p("toDelegate", A, true)]),
    ev("DelegateVotesChanged", [p("delegate", A, true), p("previousVotes", U256), p("newVotes", U256)])
  ]);

  /* --------------------------------------------------------- 4. Staking */
  var Staking = [
    fn("stake", [p("_to", A), p("_amount", U256), p("_rebasing", B), p("_claim", B)], [p("", U256)]),
    fn("unstake", [p("_to", A), p("_amount", U256), p("_trigger", B), p("_rebasing", B)], [p("", U256)]),
    fn("claim", [p("_to", A), p("_rebasing", B)], [p("", U256)]),
    fn("forfeit", [], [p("", U256)]),
    fn("toggleLock", []),
    fn("wrap", [p("_to", A), p("_amount", U256)], [p("gBalance_", U256)]),
    fn("unwrap", [p("_to", A), p("_amount", U256)], [p("sBalance_", U256)]),
    fn("rebase", []),
    fn("index", [], [p("", U256)], "view"),
    fn("secondsToNextEpoch", [], [p("", U256)], "view"),
    fn("warmupPeriod", [], [p("", U256)], "view"),
    fn("supplyInWarmup", [], [p("", U256)], "view"),
    fn("epoch", [], [
      p("length", U256), p("number", U256), p("end", U256), p("distribute", U256)
    ], "view"),
    fn("warmupInfo", [p("", A)], [
      p("deposit", U256), p("gons", U256), p("expiry", U256), p("lock", B)
    ], "view"),
    ev("Stake", [p("who", A, true), p("amount", U256), p("rebasing", B)]),
    ev("Unstake", [p("who", A, true), p("amount", U256), p("rebasing", B)])
  ];

  /* -------------------------------------------------------- 5. Treasury */
  var Treasury = [
    fn("deposit", [p("_amount", U256), p("_token", A), p("_profit", U256)], [p("send_", U256)]),
    fn("withdraw", [p("_amount", U256), p("_token", A)]),
    fn("mint", [p("_recipient", A), p("_amount", U256)]),
    fn("manage", [p("_token", A), p("_amount", U256)]),
    fn("tokenValue", [p("_token", A), p("_amount", U256)], [p("value_", U256)], "view"),
    fn("baseSupply", [], [p("", U256)], "view"),
    fn("excessReserves", [], [p("", U256)], "view"),
    fn("totalReserves", [], [p("", U256)], "view"),
    ev("Deposit", [p("token", A, true), p("amount", U256), p("value", U256)]),
    ev("Withdrawal", [p("token", A, true), p("amount", U256), p("value", U256)])
  ];

  /* -------------------------------------------------- 6. BondDepository */
  /* Olympus-style sequential-auction depository (bond markets by id). */
  var BondDepository = [
    fn("deposit", [
      p("_id", U256), p("_amount", U256), p("_maxPrice", U256),
      p("_user", A), p("_referral", A)
    ], [p("payout_", U256), p("expiry_", U256), p("index_", U256)]),
    fn("create", [
      p("_quoteToken", A),
      { name: "_market", type: "uint256[3]" },
      { name: "_booleans", type: "bool[2]" },
      { name: "_terms", type: "uint256[2]" },
      { name: "_intervals", type: "uint32[2]" }
    ], [p("id_", U256)]),
    fn("close", [p("_id", U256)]),
    fn("marketPrice", [p("_id", U256)], [p("price_", U256)], "view"),
    fn("payoutFor", [p("_amount", U256), p("_id", U256)], [p("payout_", U256)], "view"),
    fn("isLive", [p("_id", U256)], [p("", B)], "view"),
    fn("liveMarkets", [], [{ name: "", type: "uint256[]" }], "view"),
    fn("liveMarketsFor", [p("_token", A)], [{ name: "", type: "uint256[]" }], "view"),
    fn("currentDebt", [p("_id", U256)], [p("", U256)], "view"),
    fn("markets", [p("", U256)], [
      p("capacity", U256), p("quoteToken", A), p("capacityInQuote", B),
      p("totalDebt", U64), p("maxPayout", U64), p("sold", U64), p("purchased", U256)
    ], "view"),
    fn("terms", [p("", U256)], [
      p("fixedTerm", B), p("controlVariable", U64), p("vesting", U48),
      p("conclusion", U48), p("maxDebt", U64)
    ], "view"),
    ev("CreateMarket", [
      p("id", U256, true), p("baseToken", A, true), p("quoteToken", A, true), p("initialPrice", U256)
    ]),
    ev("Bond", [p("id", U256, true), p("amount", U256), p("price", U256)])
  ];

  /* ------------------------------------------- 7. Clearinghouse (Hoodz Loans) */
  /* Cooler-style: gHOOD collateral, reserve debt, fixed rate, no liquidation. */
  var Clearinghouse = [
    fn("lendToCooler", [p("cooler_", A), p("amount_", U256)], [p("", U256)]),
    fn("extendLoan", [p("cooler_", A), p("loanID_", U256), p("times_", U8)]),
    fn("claimDefaulted", [
      { name: "coolers_", type: "address[]" }, { name: "loans_", type: "uint256[]" }
    ]),
    fn("getLoanForCollateral", [p("collateral_", U256)], [
      p("debt_", U256), p("interest_", U256)
    ], "view"),
    fn("interestForLoan", [p("principal_", U256), p("duration_", U256)], [p("", U256)], "view"),
    fn("INTEREST_RATE", [], [p("", U256)], "view"),
    fn("LOAN_TO_COLLATERAL", [], [p("", U256)], "view"),
    fn("DURATION", [], [p("", U256)], "view"),
    fn("active", [], [p("", B)], "view"),
    fn("principalReceivables", [], [p("", U256)], "view"),
    fn("collateral", [], [p("", A)], "view"),
    fn("debt", [], [p("", A)], "view"),
    ev("Lend", [p("cooler", A, true), p("loanID", U256, true), p("amount", U256)]),
    ev("Rollover", [p("cooler", A, true), p("loanID", U256, true)]),
    ev("Repay", [p("cooler", A, true), p("loanID", U256, true), p("amount", U256)])
  ];

  /* ------------------------------------------------- 7b. Cooler (escrow) */
  var Cooler = [
    fn("requestLoan", [
      p("amount_", U256), p("interest_", U256), p("loanToCollateral_", U256), p("duration_", U256)
    ], [p("reqID_", U256)]),
    fn("repayLoan", [p("loanID_", U256), p("repayment_", U256)], [p("", U256)]),
    fn("getLoan", [p("loanID_", U256)], [
      p("principal", U256), p("interestDue", U256), p("collateral", U256),
      p("expiry", U256), p("lender", A), p("recipient", A), p("callback", B)
    ], "view"),
    fn("collateralFor", [p("principal_", U256), p("loanToCollateral_", U256)], [p("", U256)], "view"),
    fn("owner", [], [p("", A)], "view")
  ];

  /* -------------------------------------------------------- 8. Governor */
  /* OpenZeppelin v5 Governor surface. */
  var Governor = [
    fn("propose", [
      { name: "targets", type: "address[]" },
      { name: "values", type: "uint256[]" },
      { name: "calldatas", type: "bytes[]" },
      p("description", STR)
    ], [p("proposalId", U256)]),
    fn("queue", [
      { name: "targets", type: "address[]" },
      { name: "values", type: "uint256[]" },
      { name: "calldatas", type: "bytes[]" },
      p("descriptionHash", B32)
    ], [p("", U256)]),
    fn("execute", [
      { name: "targets", type: "address[]" },
      { name: "values", type: "uint256[]" },
      { name: "calldatas", type: "bytes[]" },
      p("descriptionHash", B32)
    ], [p("", U256)], "payable"),
    fn("cancel", [
      { name: "targets", type: "address[]" },
      { name: "values", type: "uint256[]" },
      { name: "calldatas", type: "bytes[]" },
      p("descriptionHash", B32)
    ], [p("", U256)]),
    fn("castVote", [p("proposalId", U256), p("support", U8)], [p("", U256)]),
    fn("castVoteWithReason", [
      p("proposalId", U256), p("support", U8), p("reason", STR)
    ], [p("", U256)]),
    fn("castVoteWithReasonAndParams", [
      p("proposalId", U256), p("support", U8), p("reason", STR), p("params", BYTES)
    ], [p("", U256)]),
    fn("state", [p("proposalId", U256)], [p("", U8)], "view"),
    fn("proposalVotes", [p("proposalId", U256)], [
      p("againstVotes", U256), p("forVotes", U256), p("abstainVotes", U256)
    ], "view"),
    fn("proposalSnapshot", [p("proposalId", U256)], [p("", U256)], "view"),
    fn("proposalDeadline", [p("proposalId", U256)], [p("", U256)], "view"),
    fn("proposalProposer", [p("proposalId", U256)], [p("", A)], "view"),
    fn("proposalEta", [p("proposalId", U256)], [p("", U256)], "view"),
    fn("hasVoted", [p("proposalId", U256), p("account", A)], [p("", B)], "view"),
    fn("quorum", [p("timepoint", U256)], [p("", U256)], "view"),
    fn("votingDelay", [], [p("", U256)], "view"),
    fn("votingPeriod", [], [p("", U256)], "view"),
    fn("proposalThreshold", [], [p("", U256)], "view"),
    fn("getVotes", [p("account", A), p("timepoint", U256)], [p("", U256)], "view"),
    fn("clock", [], [p("", U48)], "view"),
    fn("hashProposal", [
      { name: "targets", type: "address[]" },
      { name: "values", type: "uint256[]" },
      { name: "calldatas", type: "bytes[]" },
      p("descriptionHash", B32)
    ], [p("", U256)], "pure"),
    ev("ProposalCreated", [
      p("proposalId", U256), p("proposer", A), { name: "targets", type: "address[]" },
      { name: "values", type: "uint256[]" }, { name: "signatures", type: "string[]" },
      { name: "calldatas", type: "bytes[]" }, p("voteStart", U256), p("voteEnd", U256),
      p("description", STR)
    ]),
    ev("VoteCast", [
      p("voter", A, true), p("proposalId", U256), p("support", U8),
      p("weight", U256), p("reason", STR)
    ])
  ];

  /* --------------------------------------------------- 9. address book */
  /* Placeholders. The deploy script rewrites these from docs/deploy.json. */
  function book() {
    return {
      authority:      ZERO,
      HOOD:           ZERO,
      sHOOD:          ZERO,
      gHOOD:          ZERO,
      staking:        ZERO,
      distributor:    ZERO,
      treasury:       ZERO,
      bondDepository: ZERO,
      clearinghouse:  ZERO,
      coolerFactory:  ZERO,
      governor:       ZERO,
      timelock:       ZERO,
      reserve:        ZERO,
      ponsLaunchpad:  ZERO,
      ponsCurve:      ZERO,
      feeRouter:      ZERO
    };
  }

  var ADDRESSES = {
    4663:  book(),   /* Robinhood Chain mainnet */
    46630: book()    /* Robinhood Chain testnet */
  };

  /* Network facts — docs/BRIEF.md §2. Verified, do not edit casually. */
  var NETWORKS = {
    4663: {
      chainId: 4663,
      chainIdHex: "0x1237",
      chainName: "Robinhood Chain",
      shortName: "Robinhood",
      rpcUrls: ["https://rpc.mainnet.chain.robinhood.com"],
      blockExplorerUrls: ["https://robinhoodchain.blockscout.com"],
      nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
      testnet: false
    },
    46630: {
      chainId: 46630,
      chainIdHex: "0xb626",
      chainName: "Robinhood Chain Testnet",
      shortName: "Robinhood Testnet",
      rpcUrls: ["https://rpc.testnet.chain.robinhood.com"],
      blockExplorerUrls: ["https://testnet.robinhoodchain.blockscout.com"],
      nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
      testnet: true
    }
  };

  var DECIMALS = { HOOD: 9, sHOOD: 9, gHOOD: 18, reserve: 18 };

  /* OpenZeppelin Governor ProposalState enum → label */
  var PROPOSAL_STATE = [
    "Pending", "Active", "Canceled", "Defeated",
    "Succeeded", "Queued", "Expired", "Executed"
  ];

  global.HOOD_ABI = {
    HOOD: HOOD,
    sHOOD: sHOOD,
    gHOOD: gHOOD,
    Staking: Staking,
    Treasury: Treasury,
    BondDepository: BondDepository,
    Clearinghouse: Clearinghouse,
    Cooler: Cooler,
    Governor: Governor,
    ERC20: ERC20
  };

  global.HOOD_NET = {
    ZERO_ADDRESS: ZERO,
    DEFAULT_CHAIN_ID: 4663,
    ADDRESSES: ADDRESSES,
    NETWORKS: NETWORKS,
    DECIMALS: DECIMALS,
    PROPOSAL_STATE: PROPOSAL_STATE,
    /** Address book for a chain id, falling back to mainnet. */
    addressesFor: function (chainId) {
      return ADDRESSES[Number(chainId)] || ADDRESSES[4663];
    },
    /** Explorer deep link for an address or tx hash. */
    explorerLink: function (chainId, kind, value) {
      var net = NETWORKS[Number(chainId)] || NETWORKS[4663];
      return net.blockExplorerUrls[0] + "/" + (kind === "tx" ? "tx" : "address") + "/" + value;
    }
  };
})(window);
