/**
 * Hoodz - Hardhat configuration.
 *
 * Foundry is the primary toolchain (see foundry.toml); this config exists so that
 * hardhat-based tooling (deploy scripts, ethers.js integration tests, verification
 * plugins) works against the exact same compiler settings.
 *
 * Optional dev deps (not installed by default, keep the base install lean):
 *   npm i -D hardhat @nomicfoundation/hardhat-toolbox dotenv
 */

"use strict";

// Optional requires - the config must still parse when these are not installed.
function optional(mod) {
  try {
    // eslint-disable-next-line global-require, import/no-dynamic-require
    return require(mod);
  } catch (_) {
    return null;
  }
}

const dotenv = optional("dotenv");
if (dotenv && typeof dotenv.config === "function") {
  dotenv.config();
}
optional("@nomicfoundation/hardhat-toolbox");

const MAINNET_RPC =
  process.env.ROBINHOOD_RPC_URL || "https://rpc.mainnet.chain.robinhood.com";
const TESTNET_RPC =
  process.env.ROBINHOOD_TESTNET_RPC_URL ||
  "https://rpc.testnet.chain.robinhood.com";

// Never hardcode a key. Export PRIVATE_KEY in .env (see .env.example).
const accounts = process.env.PRIVATE_KEY
  ? [process.env.PRIVATE_KEY.startsWith("0x") ? process.env.PRIVATE_KEY : "0x" + process.env.PRIVATE_KEY]
  : [];

/** @type {import('hardhat/config').HardhatUserConfig} */
module.exports = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: { enabled: true, runs: 200 },
      evmVersion: "cancun",
      metadata: { bytecodeHash: "none" },
      viaIR: false
    }
  },

  paths: {
    sources: "./src",
    tests: "./test",
    cache: "./cache-hardhat",
    artifacts: "./artifacts"
  },

  networks: {
    hardhat: {
      chainId: 31337,
      hardfork: "cancun",
      allowUnlimitedContractSize: false
    },
    // Robinhood Chain mainnet
    robinhood: {
      url: MAINNET_RPC,
      chainId: 4663,
      accounts
    },
    // Robinhood Chain testnet
    robinhoodTestnet: {
      url: TESTNET_RPC,
      chainId: 46630,
      accounts
    }
  },

  // Blockscout is Etherscan-API compatible.
  etherscan: {
    apiKey: {
      robinhood: process.env.BLOCKSCOUT_API_KEY || "blockscout",
      robinhoodTestnet: process.env.BLOCKSCOUT_API_KEY || "blockscout"
    },
    customChains: [
      {
        network: "robinhood",
        chainId: 4663,
        urls: {
          apiURL: "https://robinhoodchain.blockscout.com/api",
          browserURL: "https://robinhoodchain.blockscout.com"
        }
      },
      {
        network: "robinhoodTestnet",
        chainId: 46630,
        urls: {
          apiURL: "https://testnet.robinhoodchain.blockscout.com/api",
          browserURL: "https://testnet.robinhoodchain.blockscout.com"
        }
      }
    ]
  },

  sourcify: { enabled: false },

  mocha: { timeout: 120000 }
};
