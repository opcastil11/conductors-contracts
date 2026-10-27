require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

const {
  PRIVATE_KEY,
  BASE_RPC_URL,
  BASE_SEPOLIA_RPC_URL,
  ARBITRUM_RPC_URL,
  ARBITRUM_SEPOLIA_RPC_URL,
  ROBINHOOD_RPC_URL,
  BASESCAN_API_KEY,
  ARBISCAN_API_KEY,
} = process.env;
const accounts = PRIVATE_KEY ? [PRIVATE_KEY] : [];

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: { enabled: true, runs: 200 },
    },
  },
  networks: {
    base: {
      url: BASE_RPC_URL || "https://mainnet.base.org",
      chainId: 8453,
      accounts,
    },
    baseSepolia: {
      url: BASE_SEPOLIA_RPC_URL || "https://sepolia.base.org",
      chainId: 84532,
      accounts,
    },
    arbitrumOne: {
      url: ARBITRUM_RPC_URL || "https://arb1.arbitrum.io/rpc",
      chainId: 42161,
      accounts,
    },
    arbitrumSepolia: {
      url: ARBITRUM_SEPOLIA_RPC_URL || "https://sepolia-rollup.arbitrum.io/rpc",
      chainId: 421614,
      accounts,
    },
    // Robinhood Chain mainnet (Arbitrum Orbit). DobProtocol issues B here too, so A and B can share it.
    robinhood: {
      url: ROBINHOOD_RPC_URL || "https://rpc.mainnet.chain.robinhood.com",
      chainId: 4663,
      accounts,
    },
  },
  etherscan: {
    apiKey: {
      base: BASESCAN_API_KEY || "",
      baseSepolia: BASESCAN_API_KEY || "",
      arbitrumOne: ARBISCAN_API_KEY || "",
      arbitrumSepolia: ARBISCAN_API_KEY || "",
    },
  },
};
