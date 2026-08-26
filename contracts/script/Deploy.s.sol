// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @dev UNAUDITED. Do not use in production without a full audit.

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {IHoodzAuthority} from "../src/interfaces/IHoodzAuthority.sol";
import {IHOODZ} from "../src/interfaces/IHOODZ.sol";
import {IgHOODZ} from "../src/interfaces/IgHOODZ.sol";
import {IStaking} from "../src/interfaces/IStaking.sol";
import {ITreasury} from "../src/interfaces/ITreasury.sol";
import {IHoodzBondAuctioneer} from "../src/interfaces/IHoodzBondAuctioneer.sol";
import {IPriceFeed} from "../src/interfaces/IPriceFeed.sol";

import {HoodzAuthority} from "../src/HoodzAuthority.sol";
import {HoodzTreasury} from "../src/HoodzTreasury.sol";
import {HoodzStaking} from "../src/HoodzStaking.sol";
import {HoodzBondingCalculator} from "../src/HoodzBondingCalculator.sol";

import {sHOODZ} from "../src/tokens/sHOODZ.sol";
import {gHOODZ} from "../src/tokens/gHOODZ.sol";

import {Distributor} from "../src/policies/Distributor.sol";
import {BondDepository} from "../src/policies/BondDepository.sol";
import {EmissionsManager} from "../src/policies/EmissionsManager.sol";
import {YieldRepurchaseFacility} from "../src/policies/YieldRepurchaseFacility.sol";

import {CoolerFactory} from "../src/loans/CoolerFactory.sol";
import {Clearinghouse} from "../src/loans/Clearinghouse.sol";

import {HoodzTimelock} from "../src/governance/HoodzTimelock.sol";
import {HoodzGovernor} from "../src/governance/HoodzGovernor.sol";

import {PonsLaunchConfig} from "../src/pons/PonsLaunchConfig.sol";
import {HoodzLaunchGuard} from "../src/pons/HoodzLaunchGuard.sol";
import {FeeRouterBuyback, ISwapRouter} from "../src/pons/FeeRouterBuyback.sol";
import {IPonsLaunchpad} from "../src/pons/IPonsLaunchpad.sol";
import {IPonsFeeRouter} from "../src/pons/IPonsFeeRouter.sol";
import {IPositionLocker} from "../src/pons/IPositionLocker.sol";
import {IUniswapV4PoolManager} from "../src/pons/IUniswapV4PoolManager.sol";

/// @title  Deploy
/// @author Hoodz DAO
/// @notice Deploys and wires the full Hoodz DAO stack in dependency order, then writes a JSON
///         manifest to `deployments/<chainid>.json` and a PONS launch manifest to
///         `deployments/pons-launch.json`.
/// @dev    `forge script script/Deploy.s.sol:Deploy --rpc-url robinhood --broadcast`
///
///         Requires `fs_permissions = [{ access = "read-write", path = "./" }]` in foundry.toml,
///         otherwise the manifest writes revert.
///
///         Two parts of the stack are optional and are skipped - with a log line, never silently -
///         when their external dependencies are not configured:
///           * `EmissionsManager` + `YieldRepurchaseFacility` need a bond auctioneer and a HOODZ
///             price feed (`HOODZ_BOND_AUCTIONEER`, `HOODZ_PRICE_FEED`);
///           * `Clearinghouse` needs the reserve token and its ERC-4626 savings vault;
///           * the PONS trio needs the launchpad, curve, position locker, fee router and a swap
///             router for the graduated pool.
contract Deploy is Script {
    /// @notice HOODZ_TOKEN was not set. Launch on PONS first, then deploy against that address.
    error HoodzTokenNotSet();

    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Everything the deployment needs that is not derived on-chain.
    struct Config {
        // --- HoodzAuthority roles ---
        address governor;
        address guardian;
        address policy;
        // --- protocol ---
        address hoodzToken; // the PONS-deployed HOODZ. Required: this repo never deploys it.
        address reserveToken; // treasury / bonding reserve asset
        address savingsVault; // ERC-4626 wrapper of `reserveToken`; its asset() must match
        uint256 epochLength; // seconds per rebase epoch (Olympus used 28800 = 8h)
        uint256 firstEpochNumber;
        uint256 firstEpochTime; // 0 => now + epochLength
        uint256 initialIndex; // sHOODZ launch index, 9 decimals
        uint256 warmupLength; // staking warmup, in epochs
        uint256 stakingRewardRate; // per-epoch emission, 1e6 denominator (3000 = 0.30%)
        uint256 treasuryTimelock; // blocks a queued treasury permission must wait
        // --- automated monetary policy (optional) ---
        address bondAuctioneer;
        address priceFeed;
        uint48 maxPriceAge;
        // --- PONS (optional as a group) ---
        address ponsLaunchpad;
        address ponsCurve;
        address ponsFeeRouter;
        address ponsLocker;
        address poolManager; // address(0) skips the v4 liquidity cross-check
        address swapRouter;
        uint256 targetRaise;
        uint256 graduationThreshold;
        uint24 lpFeeTier;
        address lockBeneficiary;
        uint64 launchTimestamp; // 0 => stamp deployment time
        // --- switches ---
        bool graduated; // true => hand the vault role straight to the treasury
        bool transferGovernance; // true => hand the governor role to the timelock at the end
    }

    /// @notice Every address produced by a run. Zero means "not deployed on this run".
    struct Deployment {
        address authority;
        address hoodz;
        address sHoodz;
        address gHoodz;
        address treasury;
        address bondingCalculator;
        address staking;
        address distributor;
        address bondDepository;
        address emissionsManager;
        address yieldRepurchaseFacility;
        address coolerFactory;
        address clearinghouse;
        address timelock;
        address governor;
        address launchConfig;
        address launchGuard;
        address feeRouterBuyback;
    }

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev Held in storage so the deploy steps below never hit "stack too deep".
    Deployment internal d;

    /// @dev abi-encoded constructor arguments, serialised into the manifest for `Verify.s.sol`.
    mapping(string => bytes) internal ctorArgs;
    string[] internal ctorArgKeys;

    address internal deployer;

    // Typed handles; `d` mirrors them as plain addresses for the manifest.
    HoodzAuthority internal authority;
    IHOODZ internal hoodz;
    sHOODZ internal sHoodz;
    gHOODZ internal gHoodz;
    HoodzTreasury internal treasury;
    HoodzBondingCalculator internal bondingCalculator;
    HoodzStaking internal staking;
    Distributor internal distributor;
    BondDepository internal bondDepository;
    EmissionsManager internal emissionsManager;
    YieldRepurchaseFacility internal yrf;
    CoolerFactory internal coolerFactory;
    Clearinghouse internal clearinghouse;
    HoodzTimelock internal timelock;
    HoodzGovernor internal governorContract;
    PonsLaunchConfig internal launchConfig;
    HoodzLaunchGuard internal launchGuard;
    FeeRouterBuyback internal feeRouterBuyback;

    /*//////////////////////////////////////////////////////////////
                                  ENTRY
    //////////////////////////////////////////////////////////////*/

    /// @notice Reads configuration from the environment and deploys the whole stack.
    /// @return The deployed addresses.
    function run() public virtual returns (Deployment memory) {
        return deploy(configFromEnv());
    }

    /// @notice Deploys and wires the whole stack from an explicit configuration.
    /// @param cfg The deployment configuration.
    /// @return The deployed addresses.
    function deploy(Config memory cfg) public returns (Deployment memory) {
        cfg = _normalize(cfg);
        _logHeader(cfg);

        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk == 0) {
            deployer = msg.sender;
            vm.startBroadcast();
        } else {
            deployer = vm.addr(pk);
            vm.startBroadcast(pk);
        }

        _deployCore(cfg);
        _deployPolicies(cfg);
        _deployLoans(cfg);
        _deployGovernance();
        _deployPons(cfg);
        _wireTokens(cfg);
        _wireTreasury(cfg);
        _wireGovernance(cfg);
        _wireVaultRole(cfg);

        vm.stopBroadcast();

        _logAddresses();
        _writeManifest(cfg);
        _writePonsManifest(cfg);

        return d;
    }

    /*//////////////////////////////////////////////////////////////
                              CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Builds a {Config} from environment variables, falling back to sane defaults.
    /// @return cfg The resolved configuration.
    function configFromEnv() public view returns (Config memory cfg) {
        address self = vm.envOr("DEPLOYER_ADDRESS", msg.sender);

        cfg.governor = vm.envOr("HOODZ_GOVERNOR", self);
        cfg.guardian = vm.envOr("HOODZ_GUARDIAN", self);
        cfg.policy = vm.envOr("HOODZ_POLICY", self);

        cfg.hoodzToken = vm.envOr("HOODZ_TOKEN", address(0));
        cfg.reserveToken = vm.envOr("RESERVE_TOKEN", vm.envOr("PONS_RESERVE_TOKEN", address(0)));
        cfg.savingsVault = vm.envOr("RESERVE_SAVINGS_VAULT", address(0));

        cfg.epochLength = vm.envOr("HOODZ_EPOCH_LENGTH", uint256(28800));
        cfg.firstEpochNumber = vm.envOr("HOODZ_FIRST_EPOCH_NUMBER", uint256(1));
        cfg.firstEpochTime = vm.envOr("HOODZ_FIRST_EPOCH_TIME", uint256(0));
        cfg.initialIndex = vm.envOr("HOODZ_INITIAL_INDEX", uint256(1e9));
        cfg.warmupLength = vm.envOr("HOODZ_WARMUP_LENGTH", uint256(0));
        // Per-epoch emission, 1e6 denominator. Default 3058 = 0.3058%/epoch, the tier-1 rate of
        // Olympus's OIP-18 reward framework. With 8h epochs that is 1095 compounds a year:
        //
        //   supply band        rate   %/epoch    APY
        //   bootstrap          5750   0.5750%    53,184%   <- the 2021 launch rate
        //   < 1M HOODZ         3058   0.3058%     2,732%   <- default
        //   1M - 10M           1587   0.1587%       468%
        //   10M - 100M         1186   0.1186%       266%
        //   100M - 1B           793   0.0793%       138%
        //   1B - 10B            397   0.0397%        54%
        //   > 10B               198   0.0198%        24%
        //
        // Set HOODZ_REWARD_RATE=0 to run with rebasing switched off, which is what Olympus itself
        // does today. Above 0 you are running the original 2021 model: the APY is paid in newly
        // minted HOODZ, so it only creates value while the treasury grows faster than supply.
        cfg.stakingRewardRate = vm.envOr("HOODZ_REWARD_RATE", uint256(3058));
        cfg.treasuryTimelock = vm.envOr("HOODZ_TREASURY_TIMELOCK", uint256(0));

        cfg.bondAuctioneer = vm.envOr("HOODZ_BOND_AUCTIONEER", address(0));
        cfg.priceFeed = vm.envOr("HOODZ_PRICE_FEED", address(0));
        cfg.maxPriceAge = uint48(vm.envOr("HOODZ_MAX_PRICE_AGE", uint256(1 days)));

        cfg.ponsLaunchpad = vm.envOr("PONS_LAUNCHPAD", address(0));
        cfg.ponsCurve = vm.envOr("PONS_CURVE", vm.envOr("PONS_BONDING_CURVE", address(0)));
        cfg.ponsFeeRouter = vm.envOr("PONS_FEE_ROUTER", address(0));
        cfg.ponsLocker = vm.envOr("PONS_POSITION_LOCKER", address(0));
        cfg.poolManager = vm.envOr("PONS_POOL_MANAGER", address(0));
        cfg.swapRouter = vm.envOr("PONS_SWAP_ROUTER", address(0));
        cfg.targetRaise = vm.envOr("PONS_TARGET_RAISE", uint256(0));
        cfg.graduationThreshold = vm.envOr("PONS_GRADUATION_THRESHOLD", uint256(0));
        cfg.lpFeeTier = uint24(vm.envOr("PONS_LP_FEE_TIER", uint256(3000)));
        cfg.lockBeneficiary = vm.envOr("PONS_LOCK_BENEFICIARY", cfg.governor);
        cfg.launchTimestamp = uint64(vm.envOr("PONS_LAUNCH_TIMESTAMP", uint256(0)));

        cfg.graduated = vm.envOr("PONS_GRADUATED", false);
        cfg.transferGovernance = vm.envOr("HOODZ_TRANSFER_GOVERNANCE", false);
    }

    /// @dev Fills in derived defaults. Never invents an external dependency.
    function _normalize(Config memory cfg) internal view returns (Config memory) {
        if (cfg.governor == address(0)) cfg.governor = msg.sender;
        if (cfg.guardian == address(0)) cfg.guardian = cfg.governor;
        if (cfg.policy == address(0)) cfg.policy = cfg.governor;
        if (cfg.lockBeneficiary == address(0)) cfg.lockBeneficiary = cfg.governor;
        if (cfg.epochLength == 0) cfg.epochLength = 28800;
        if (cfg.firstEpochNumber == 0) cfg.firstEpochNumber = 1;
        if (cfg.firstEpochTime == 0) cfg.firstEpochTime = block.timestamp + cfg.epochLength;
        if (cfg.initialIndex == 0) cfg.initialIndex = 1e9;
        if (cfg.lpFeeTier == 0) cfg.lpFeeTier = 3000;
        if (cfg.maxPriceAge == 0) cfg.maxPriceAge = uint48(1 days);
        return cfg;
    }

    /// @dev True when the automated monetary policies have everything they need.
    function _hasMonetaryPolicyDeps(Config memory cfg) internal pure returns (bool) {
        return cfg.reserveToken != address(0) && cfg.savingsVault != address(0) && cfg.bondAuctioneer != address(0)
            && cfg.priceFeed != address(0);
    }

    /// @dev True when the PONS launch trio has everything it needs.
    function _hasPonsDeps(Config memory cfg) internal pure returns (bool) {
        return cfg.reserveToken != address(0) && cfg.ponsLaunchpad != address(0) && cfg.ponsCurve != address(0)
            && cfg.ponsLocker != address(0) && cfg.ponsFeeRouter != address(0) && cfg.swapRouter != address(0)
            && cfg.targetRaise != 0 && cfg.graduationThreshold != 0;
    }

    /*//////////////////////////////////////////////////////////////
                                  STEPS
    //////////////////////////////////////////////////////////////*/

    /// @dev 1. Authority, the token trio, treasury, bonding calculator, staking.
    function _deployCore(Config memory cfg) internal {
        // The deployer holds `governor` and `vault` for the length of the run; both are placed
        // in {_wireVaultRole} once every consumer exists.
        authority = new HoodzAuthority(deployer, cfg.guardian, cfg.policy, deployer);
        _record("HoodzAuthority", abi.encode(deployer, cfg.guardian, cfg.policy, deployer));
        d.authority = address(authority);

        IHoodzAuthority auth = IHoodzAuthority(address(authority));

        // HOODZ is NOT deployed here. The PONS launchpad deploys it from its own factory when
        // the launch form is submitted - fixed 1B supply, the whole amount sold on the bonding
        // curve, no mint function, no owner. This repo only ever holds a reference to it.
        if (cfg.hoodzToken == address(0)) revert HoodzTokenNotSet();
        hoodz = IHOODZ(cfg.hoodzToken);
        d.hoodz = cfg.hoodzToken;

        sHoodz = new sHOODZ(auth);
        _record("sHOODZ", abi.encode(address(authority)));
        d.sHoodz = address(sHoodz);

        gHoodz = new gHOODZ(auth, address(sHoodz));
        _record("gHOODZ", abi.encode(address(authority), address(sHoodz)));
        d.gHoodz = address(gHoodz);

        treasury = new HoodzTreasury(address(hoodz), cfg.treasuryTimelock, address(authority));
        _record("HoodzTreasury", abi.encode(address(hoodz), cfg.treasuryTimelock, address(authority)));
        d.treasury = address(treasury);

        bondingCalculator = new HoodzBondingCalculator(address(hoodz));
        _record("HoodzBondingCalculator", abi.encode(address(hoodz)));
        d.bondingCalculator = address(bondingCalculator);

        staking = new HoodzStaking(
            address(hoodz),
            address(sHoodz),
            address(gHoodz),
            cfg.epochLength,
            cfg.firstEpochNumber,
            cfg.firstEpochTime,
            address(authority)
        );
        _record(
            "HoodzStaking",
            abi.encode(
                address(hoodz),
                address(sHoodz),
                address(gHoodz),
                cfg.epochLength,
                cfg.firstEpochNumber,
                cfg.firstEpochTime,
                address(authority)
            )
        );
        d.staking = address(staking);
    }

    /// @dev 2. Distributor, bond depository, and - if configured - the automated policies.
    function _deployPolicies(Config memory cfg) internal {
        distributor = new Distributor(address(treasury), address(hoodz), address(staking), address(authority));
        _record("Distributor", abi.encode(address(treasury), address(hoodz), address(staking), address(authority)));
        d.distributor = address(distributor);

        bondDepository = new BondDepository(
            IHoodzAuthority(address(authority)),
            IHOODZ(address(hoodz)),
            IgHOODZ(address(gHoodz)),
            IStaking(address(staking)),
            ITreasury(address(treasury))
        );
        _record(
            "BondDepository",
            abi.encode(address(authority), address(hoodz), address(gHoodz), address(staking), address(treasury))
        );
        d.bondDepository = address(bondDepository);

        if (!_hasMonetaryPolicyDeps(cfg)) {
            console2.log("!! EmissionsManager + YieldRepurchaseFacility skipped.");
            console2.log("   Set RESERVE_TOKEN, RESERVE_SAVINGS_VAULT, HOODZ_BOND_AUCTIONEER, HOODZ_PRICE_FEED.");
            return;
        }

        emissionsManager = new EmissionsManager(
            IHoodzAuthority(address(authority)),
            IHOODZ(address(hoodz)),
            IERC20(cfg.reserveToken),
            ITreasury(address(treasury)),
            IHoodzBondAuctioneer(cfg.bondAuctioneer),
            IPriceFeed(cfg.priceFeed),
            cfg.maxPriceAge
        );
        _record(
            "EmissionsManager",
            abi.encode(
                address(authority),
                address(hoodz),
                cfg.reserveToken,
                address(treasury),
                cfg.bondAuctioneer,
                cfg.priceFeed,
                cfg.maxPriceAge
            )
        );
        d.emissionsManager = address(emissionsManager);

        yrf = new YieldRepurchaseFacility(
            IHoodzAuthority(address(authority)),
            IHOODZ(address(hoodz)),
            IERC20(cfg.reserveToken),
            IERC4626(cfg.savingsVault),
            ITreasury(address(treasury)),
            IHoodzBondAuctioneer(cfg.bondAuctioneer),
            IPriceFeed(cfg.priceFeed),
            cfg.maxPriceAge
        );
        _record(
            "YieldRepurchaseFacility",
            abi.encode(
                address(authority),
                address(hoodz),
                cfg.reserveToken,
                cfg.savingsVault,
                address(treasury),
                cfg.bondAuctioneer,
                cfg.priceFeed,
                cfg.maxPriceAge
            )
        );
        d.yieldRepurchaseFacility = address(yrf);
    }

    /// @dev 3. Hoodz Loans: the escrow factory and the clearinghouse that lends against gHOODZ.
    function _deployLoans(Config memory cfg) internal {
        coolerFactory = new CoolerFactory();
        _record("CoolerFactory", "");
        d.coolerFactory = address(coolerFactory);

        if (cfg.reserveToken == address(0) || cfg.savingsVault == address(0)) {
            console2.log("!! Clearinghouse skipped: RESERVE_TOKEN / RESERVE_SAVINGS_VAULT not set.");
            return;
        }

        clearinghouse = new Clearinghouse(
            address(gHoodz),
            address(hoodz),
            address(staking),
            cfg.reserveToken,
            cfg.savingsVault,
            address(treasury),
            address(coolerFactory),
            IHoodzAuthority(address(authority))
        );
        _record(
            "Clearinghouse",
            abi.encode(
                address(gHoodz),
                address(hoodz),
                address(staking),
                cfg.reserveToken,
                cfg.savingsVault,
                address(treasury),
                address(coolerFactory),
                address(authority)
            )
        );
        d.clearinghouse = address(clearinghouse);
    }

    /// @dev 4. Timelock + Governor over gHOODZ voting power.
    ///      `HoodzTimelock` demands at least one proposer at construction and the governor does
    ///      not exist yet, so the deployer is bootstrapped in and swapped out in {_wireGovernance}.
    function _deployGovernance() internal {
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = address(0); // anyone may execute a matured batch

        timelock = new HoodzTimelock(proposers, executors, deployer);
        _record("HoodzTimelock", abi.encode(proposers, executors, deployer));
        d.timelock = address(timelock);

        governorContract = new HoodzGovernor(IVotes(address(gHoodz)), timelock);
        _record("HoodzGovernor", abi.encode(address(gHoodz), address(timelock)));
        d.governor = address(governorContract);
    }

    /// @dev 5. PONS launch: the immutable launch record, the mint-authority guard, the buyback router.
    function _deployPons(Config memory cfg) internal {
        if (!_hasPonsDeps(cfg)) {
            console2.log("!! PONS trio skipped: set PONS_LAUNCHPAD, PONS_CURVE, PONS_POSITION_LOCKER,");
            console2.log("   PONS_FEE_ROUTER, PONS_SWAP_ROUTER, PONS_TARGET_RAISE, PONS_GRADUATION_THRESHOLD.");
            return;
        }

        launchConfig = new PonsLaunchConfig(
            address(hoodz),
            cfg.reserveToken,
            cfg.ponsCurve,
            cfg.targetRaise,
            cfg.graduationThreshold,
            cfg.lpFeeTier,
            cfg.lockBeneficiary,
            cfg.launchTimestamp
        );
        _record(
            "PonsLaunchConfig",
            abi.encode(
                address(hoodz),
                cfg.reserveToken,
                cfg.ponsCurve,
                cfg.targetRaise,
                cfg.graduationThreshold,
                cfg.lpFeeTier,
                cfg.lockBeneficiary,
                cfg.launchTimestamp
            )
        );
        d.launchConfig = address(launchConfig);

        launchGuard = new HoodzLaunchGuard(
            IHoodzAuthority(address(authority)),
            launchConfig,
            IPonsLaunchpad(cfg.ponsLaunchpad),
            IPositionLocker(cfg.ponsLocker),
            IUniswapV4PoolManager(cfg.poolManager),
            address(treasury)
        );
        _record(
            "HoodzLaunchGuard",
            abi.encode(
                address(authority),
                address(launchConfig),
                cfg.ponsLaunchpad,
                cfg.ponsLocker,
                cfg.poolManager,
                address(treasury)
            )
        );
        d.launchGuard = address(launchGuard);

        feeRouterBuyback = new FeeRouterBuyback(
            IHoodzAuthority(address(authority)),
            launchConfig,
            IPonsFeeRouter(cfg.ponsFeeRouter),
            ISwapRouter(cfg.swapRouter)
        );
        _record(
            "FeeRouterBuyback",
            abi.encode(address(authority), address(launchConfig), cfg.ponsFeeRouter, cfg.swapRouter)
        );
        d.feeRouterBuyback = address(feeRouterBuyback);
    }

    /// @dev 6a. Index, gHOODZ/staking links, distributor recipient.
    function _wireTokens(Config memory cfg) internal {
        sHoodz.setIndex(cfg.initialIndex);
        sHoodz.setgHOODZ(address(gHoodz));
        sHoodz.initialize(address(staking), address(treasury));
        gHoodz.migrate(address(staking), address(sHoodz));

        staking.setDistributor(address(distributor));
        if (cfg.warmupLength != 0) staking.setWarmupLength(cfg.warmupLength);
        distributor.addRecipient(address(staking), cfg.stakingRewardRate);
    }

    /// @dev 6b. Treasury permissions. Everything that mints, spends or manages is registered here.
    function _wireTreasury(Config memory cfg) internal {
        treasury.enable(HoodzTreasury.STATUS.SHOODZ, address(sHoodz), address(0));
        treasury.enable(HoodzTreasury.STATUS.REWARDMANAGER, address(distributor), address(0));
        treasury.enable(HoodzTreasury.STATUS.REWARDMANAGER, address(bondDepository), address(0));

        if (cfg.reserveToken != address(0)) {
            treasury.enable(HoodzTreasury.STATUS.RESERVETOKEN, cfg.reserveToken, address(0));
            treasury.enable(HoodzTreasury.STATUS.RESERVEDEPOSITOR, cfg.policy, address(0));
        }
        if (cfg.savingsVault != address(0)) {
            treasury.enable(HoodzTreasury.STATUS.RESERVETOKEN, cfg.savingsVault, address(0));
        }

        if (d.emissionsManager != address(0)) {
            treasury.enable(HoodzTreasury.STATUS.REWARDMANAGER, d.emissionsManager, address(0));
        }
        if (d.yieldRepurchaseFacility != address(0)) {
            treasury.enable(HoodzTreasury.STATUS.RESERVESPENDER, d.yieldRepurchaseFacility, address(0));
            treasury.enable(HoodzTreasury.STATUS.RESERVEMANAGER, d.yieldRepurchaseFacility, address(0));
            treasury.enable(HoodzTreasury.STATUS.RESERVEDEPOSITOR, d.yieldRepurchaseFacility, address(0));
        }
        if (d.clearinghouse != address(0)) {
            // `rebalance` pulls with `manage` and pushes back with `deposit`, so the
            // clearinghouse needs permissions on both sides of the balance sheet.
            treasury.enable(HoodzTreasury.STATUS.RESERVEMANAGER, d.clearinghouse, address(0));
            treasury.enable(HoodzTreasury.STATUS.RESERVEDEPOSITOR, d.clearinghouse, address(0));
            treasury.enable(HoodzTreasury.STATUS.RESERVEDEBTOR, d.clearinghouse, address(0));
        }

        console2.log("note: register LP tokens later with");
        console2.log("      treasury.enable(STATUS.LIQUIDITYTOKEN, <pair>, <bondingCalculator>)");
        console2.log("      bondingCalculator ->", d.bondingCalculator);
    }

    /// @dev 6c. Hand the timelock to the governor and drop the deployer's bootstrap roles.
    function _wireGovernance(Config memory cfg) internal {
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governorContract));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governorContract));
        timelock.grantRole(timelock.CANCELLER_ROLE(), cfg.guardian);

        timelock.revokeRole(timelock.PROPOSER_ROLE(), deployer);
        timelock.revokeRole(timelock.CANCELLER_ROLE(), deployer);
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);
    }

    /// @dev 6d. Place the vault (mint) role, then hand over the governor role.
    ///      Per §4 of the brief the protocol must not be able to mint HOODZ while the token is
    ///      still price-discovering on the PONS curve, so before graduation the vault role goes
    ///      to {HoodzLaunchGuard}, which has no mint function - HOODZ supply is frozen at exactly
    ///      what the curve escrows.
    function _wireVaultRole(Config memory cfg) internal {
        if (cfg.graduated || d.launchGuard == address(0)) {
            authority.pushVault(address(treasury), true);
            console2.log("vault role -> HoodzTreasury (minting live)");
        } else {
            // lockVaultToGuard, not pushVault: it installs the guard as the vault AND disables
            // pushVault, so from here the ONLY way mint authority can reach the treasury is
            // HoodzLaunchGuard.releaseToTreasury(), which checks graduation and the LP lock live.
            // Using pushVault here would leave the governor free to skip the guard entirely.
            authority.lockVaultToGuard(d.launchGuard);
            console2.log("vault role -> HoodzLaunchGuard, escrowed (HOODZ supply frozen)");
            console2.log("  authority.pushVault is now disabled until the guard releases");
            console2.log("  post-graduation: verifyGraduation() -> arm() -> wait 48h -> releaseToTreasury()");
        }

        if (cfg.transferGovernance) {
            authority.pushGovernor(address(timelock), true);
            console2.log("governor role -> HoodzTimelock", address(timelock));
        } else {
            authority.pushGovernor(cfg.governor, true);
            console2.log("governor role ->", cfg.governor);
            console2.log("  set HOODZ_TRANSFER_GOVERNANCE=true to hand it to the timelock instead");
        }
    }

    /*//////////////////////////////////////////////////////////////
                                MANIFESTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Remembers abi-encoded constructor args so `Verify.s.sol` can print runnable commands.
    function _record(string memory name, bytes memory args) internal {
        ctorArgs[name] = args;
        ctorArgKeys.push(name);
    }

    function _writeManifest(Config memory cfg) internal {
        string memory argsObj = "hoodz.ctorArgs";
        string memory argsJson = "{}";
        uint256 n = ctorArgKeys.length;
        for (uint256 i; i < n; ++i) {
            argsJson = vm.serializeBytes(argsObj, ctorArgKeys[i], ctorArgs[ctorArgKeys[i]]);
        }

        string memory rolesObj = "hoodz.roles";
        vm.serializeAddress(rolesObj, "governor", authority.governor());
        vm.serializeAddress(rolesObj, "guardian", authority.guardian());
        vm.serializeAddress(rolesObj, "policy", authority.policy());
        string memory rolesJson = vm.serializeAddress(rolesObj, "vault", authority.vault());

        string memory obj = "hoodz";
        vm.serializeString(obj, "name", "Hoodz DAO");
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeUint(obj, "deployedAt", block.timestamp);
        vm.serializeAddress(obj, "deployer", deployer);
        vm.serializeAddress(obj, "reserveToken", cfg.reserveToken);
        vm.serializeAddress(obj, "savingsVault", cfg.savingsVault);

        vm.serializeAddress(obj, "HoodzAuthority", d.authority);
        vm.serializeAddress(obj, "HOODZ", d.hoodz);
        vm.serializeAddress(obj, "sHOODZ", d.sHoodz);
        vm.serializeAddress(obj, "gHOODZ", d.gHoodz);
        vm.serializeAddress(obj, "HoodzTreasury", d.treasury);
        vm.serializeAddress(obj, "HoodzBondingCalculator", d.bondingCalculator);
        vm.serializeAddress(obj, "HoodzStaking", d.staking);
        vm.serializeAddress(obj, "Distributor", d.distributor);
        vm.serializeAddress(obj, "BondDepository", d.bondDepository);
        vm.serializeAddress(obj, "EmissionsManager", d.emissionsManager);
        vm.serializeAddress(obj, "YieldRepurchaseFacility", d.yieldRepurchaseFacility);
        vm.serializeAddress(obj, "CoolerFactory", d.coolerFactory);
        vm.serializeAddress(obj, "Clearinghouse", d.clearinghouse);
        vm.serializeAddress(obj, "HoodzTimelock", d.timelock);
        vm.serializeAddress(obj, "HoodzGovernor", d.governor);
        vm.serializeAddress(obj, "PonsLaunchConfig", d.launchConfig);
        vm.serializeAddress(obj, "HoodzLaunchGuard", d.launchGuard);
        vm.serializeAddress(obj, "FeeRouterBuyback", d.feeRouterBuyback);
        vm.serializeString(obj, "roles", rolesJson);
        string memory json = vm.serializeString(obj, "constructorArgs", argsJson);

        vm.createDir("deployments", true);
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);
        console2.log("manifest ->", path);
    }

    /// @dev The PONS-ready launch manifest. `make deploy-*` copies it to docs/pons-launch.json.
    function _writePonsManifest(Config memory cfg) internal {
        string memory obj = "pons";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeString(obj, "network", block.chainid == 4663 ? string("robinhood") : string("robinhood-testnet"));
        vm.serializeString(obj, "tokenName", "Hoodz");
        vm.serializeString(obj, "tokenSymbol", "HOODZ");
        vm.serializeUint(obj, "tokenDecimals", 9);
        vm.serializeAddress(obj, "token", d.hoodz);
        vm.serializeAddress(obj, "launchpad", cfg.ponsLaunchpad);
        vm.serializeAddress(obj, "bondingCurve", cfg.ponsCurve);
        vm.serializeAddress(obj, "feeRouter", cfg.ponsFeeRouter);
        vm.serializeAddress(obj, "positionLocker", cfg.ponsLocker);
        vm.serializeAddress(obj, "poolManager", cfg.poolManager);
        vm.serializeAddress(obj, "swapRouter", cfg.swapRouter);
        vm.serializeAddress(obj, "reserveToken", cfg.reserveToken);
        vm.serializeUint(obj, "targetRaise", cfg.targetRaise);
        vm.serializeUint(obj, "graduationThreshold", cfg.graduationThreshold);
        vm.serializeUint(obj, "lpFeeTier", uint256(cfg.lpFeeTier));
        vm.serializeAddress(obj, "lockBeneficiary", cfg.lockBeneficiary);
        vm.serializeAddress(obj, "launchConfig", d.launchConfig);
        vm.serializeAddress(obj, "launchGuard", d.launchGuard);
        vm.serializeAddress(obj, "feeRouterBuyback", d.feeRouterBuyback);
        vm.serializeAddress(obj, "pendingVault", d.treasury);
        vm.serializeAddress(obj, "currentVault", authority.vault());
        vm.serializeUint(obj, "transferDelaySeconds", 48 hours);
        string memory json = vm.serializeBool(obj, "graduated", cfg.graduated);

        vm.createDir("deployments", true);
        vm.writeJson(json, "deployments/pons-launch.json");
        console2.log("pons manifest -> deployments/pons-launch.json");
    }

    /*//////////////////////////////////////////////////////////////
                                 LOGGING
    //////////////////////////////////////////////////////////////*/

    function _logHeader(Config memory cfg) internal view {
        console2.log("=====================================================================");
        console2.log(" Hoodz DAO deployment - UNAUDITED");
        console2.log("  chainId        ", block.chainid);
        console2.log("  governor       ", cfg.governor);
        console2.log("  guardian       ", cfg.guardian);
        console2.log("  policy         ", cfg.policy);
        console2.log("  reserveToken   ", cfg.reserveToken);
        console2.log("  savingsVault   ", cfg.savingsVault);
        console2.log("  epochLength    ", cfg.epochLength);
        console2.log("  initialIndex   ", cfg.initialIndex);
        console2.log("  rewardRate/1e6 ", cfg.stakingRewardRate);
        console2.log("  bondAuctioneer ", cfg.bondAuctioneer);
        console2.log("  priceFeed      ", cfg.priceFeed);
        console2.log("  ponsLaunchpad  ", cfg.ponsLaunchpad);
        console2.log("  ponsCurve      ", cfg.ponsCurve);
        console2.log("  graduated      ", cfg.graduated);
        console2.log("=====================================================================");
    }

    function _logAddresses() internal view {
        console2.log("---------------------------- addresses ------------------------------");
        console2.log("  HoodzAuthority         ", d.authority);
        console2.log("  HOODZ                  ", d.hoodz);
        console2.log("  sHOODZ                 ", d.sHoodz);
        console2.log("  gHOODZ                 ", d.gHoodz);
        console2.log("  HoodzTreasury          ", d.treasury);
        console2.log("  HoodzBondingCalculator ", d.bondingCalculator);
        console2.log("  HoodzStaking           ", d.staking);
        console2.log("  Distributor            ", d.distributor);
        console2.log("  BondDepository         ", d.bondDepository);
        console2.log("  EmissionsManager       ", d.emissionsManager);
        console2.log("  YieldRepurchaseFacility", d.yieldRepurchaseFacility);
        console2.log("  CoolerFactory          ", d.coolerFactory);
        console2.log("  Clearinghouse          ", d.clearinghouse);
        console2.log("  HoodzTimelock          ", d.timelock);
        console2.log("  HoodzGovernor          ", d.governor);
        console2.log("  PonsLaunchConfig       ", d.launchConfig);
        console2.log("  HoodzLaunchGuard       ", d.launchGuard);
        console2.log("  FeeRouterBuyback       ", d.feeRouterBuyback);
        console2.log("---------------------------------------------------------------------");
    }
}
