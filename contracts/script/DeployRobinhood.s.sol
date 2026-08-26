// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @dev UNAUDITED. Do not use in production without a full audit.

import {console2} from "forge-std/console2.sol";

import {Deploy} from "./Deploy.s.sol";

/// @title  DeployRobinhood
/// @author Hoodz DAO
/// @notice Thin Robinhood Chain wrapper around {Deploy}. Reads the launch inputs from `.env`
///         (`PRIVATE_KEY`, `RESERVE_TOKEN`, `PONS_LAUNCHPAD`, `PONS_CURVE`), refuses to run on
///         any chain other than Robinhood mainnet (4663) or testnet (46630), and delegates the
///         deployment itself to {Deploy.deploy}.
/// @dev    Testnet:
///
///   forge script script/DeployRobinhood.s.sol:DeployRobinhood \
///     --rpc-url robinhood_testnet --broadcast --slow \
///     --verify --verifier blockscout \
///     --verifier-url https://testnet.robinhoodchain.blockscout.com/api -vvvv
///
///         Mainnet: swap in `--rpc-url robinhood` and
///         `--verifier-url https://robinhoodchain.blockscout.com/api`.
///
///         Dry run first by omitting `--broadcast`.
contract DeployRobinhood is Deploy {
    /// @notice Robinhood Chain mainnet.
    uint256 public constant CHAIN_ID_MAINNET = 4663;
    /// @notice Robinhood Chain testnet.
    uint256 public constant CHAIN_ID_TESTNET = 46630;

    /// @notice Thrown when the active chain is neither Robinhood mainnet nor Robinhood testnet.
    /// @param chainId The chain id the script found.
    error UnsupportedChain(uint256 chainId);

    /// @notice Thrown when a required `.env` value is missing.
    /// @param key The environment variable that must be set.
    error MissingEnv(string key);

    /// @notice Deploys the Hoodz DAO stack onto Robinhood Chain using `.env` inputs.
    /// @return The deployed addresses.
    function run() public override returns (Deployment memory) {
        if (block.chainid != CHAIN_ID_MAINNET && block.chainid != CHAIN_ID_TESTNET) {
            revert UnsupportedChain(block.chainid);
        }

        // `PRIVATE_KEY` is consumed inside Deploy.deploy(); assert it here so a missing key fails
        // with a named error instead of silently simulating from an unfunded default sender.
        if (vm.envOr("PRIVATE_KEY", uint256(0)) == 0) revert MissingEnv("PRIVATE_KEY");

        Config memory cfg = configFromEnv();

        if (cfg.reserveToken == address(0)) revert MissingEnv("RESERVE_TOKEN");
        if (cfg.ponsLaunchpad == address(0)) revert MissingEnv("PONS_LAUNCHPAD");
        if (cfg.ponsCurve == address(0)) revert MissingEnv("PONS_CURVE");

        console2.log(
            block.chainid == CHAIN_ID_MAINNET
                ? string("Robinhood Chain MAINNET  4663 - https://robinhoodchain.blockscout.com")
                : string("Robinhood Chain TESTNET 46630 - https://testnet.robinhoodchain.blockscout.com")
        );

        Deployment memory dep = deploy(cfg);

        console2.log("");
        console2.log("PONS launch checklist:");
        console2.log("  1. Launch HOODZ on PONS against the curve at", cfg.ponsCurve);
        console2.log("  2. Trade the curve until isGraduated(HOODZ) is true");
        console2.log("  3. HoodzLaunchGuard.verifyGraduation()  ->", dep.launchGuard);
        console2.log("  4. HoodzLaunchGuard.arm(), then wait out the 48h transfer delay");
        console2.log("  5. HoodzLaunchGuard.releaseToTreasury() -> vault role moves to", dep.treasury);
        console2.log("  6. FeeRouterBuyback.pointFeesHere()     ->", dep.feeRouterBuyback);
        console2.log("");
        console2.log("Then verify with: forge script script/Verify.s.sol:Verify --rpc-url <net> -vv");

        return dep;
    }
}
