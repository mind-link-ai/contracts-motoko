import * as dotenv from "dotenv";
import { Actor, HttpAgent } from "@dfinity/agent";
import { Principal } from "@dfinity/principal";
import { idlFactory } from "../.dfx/playground/canisters/guarantee/service.did.js";

// Load environment variables
dotenv.config();

// Test configuration
const config = {
  // Test parameters
  stakeDuration: BigInt(60 * 60 * 24), // 1 day
  tradeDuration: BigInt(60 * 60 * 24 * 7), // 7 days
  participantA: {
    solanaAddress: "ParticipantA_SolanaAddress",
    shouldStakeAmount: BigInt(1000 * 1_000_000),
  },
  participantB: {
    solanaAddress: "ParticipantB_SolanaAddress",
    shouldStakeAmount: BigInt(1000 * 1_000_000),
  },
  verifier: {
    solanaAddress: "Verifier_SolanaAddress",
  },
  arbitrator: {
    solanaAddress: "Arbitrator_SolanaAddress",
  },
  stakeVault: {
    solanaAddress: "StakeVault_SolanaAddress",
  },
};

// Mock signature
const mockSignature = "MockSignature";

// Delay function
const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

// Helper function to get current timestamp in seconds
const getCurrentTimestampInSeconds = () =>
  BigInt(Math.floor(Date.now() / 1000));

// Main test function
async function runTests() {
  try {
    console.log("Starting guarantee contract tests...");

    const canisterId = process.env.CANISTER_ID_GUARANTEE;
    if (!canisterId) throw new Error("Contract ID not found");

    // Create agent and actor
    const agent = new HttpAgent({ host: "https://icp0.io" });

    const actor = Actor.createActor(idlFactory, {
      agent,
      canisterId,
    });

    // 1. Test initialization
    console.log("\n1. Testing contract initialization...");
    await actor.initialize(
      config.stakeDuration,
      config.tradeDuration,
      config.participantA.solanaAddress,
      config.participantB.solanaAddress,
      config.participantA.shouldStakeAmount,
      config.participantB.shouldStakeAmount,
      config.verifier.solanaAddress,
      config.arbitrator.solanaAddress,
      "Initial transaction"
    );

    // Verify status
    let status = await actor.getTransactionStatus();
    console.log("Transaction status:", status);

    // 2. Test staking confirmation
    console.log("\n2. Testing staking confirmation...");
    // ParticipantA staking
    await actor.confirmStakingComplete(
      config.stakeVault.solanaAddress,
      config.participantA.solanaAddress,
      getCurrentTimestampInSeconds(),
      mockSignature
    );
    status = await actor.getTransactionStatus();
    console.log("Status after ParticipantA staking:", status);

    // ParticipantB staking
    await actor.confirmStakingComplete(
      config.stakeVault.solanaAddress,
      config.participantB.solanaAddress,
      getCurrentTimestampInSeconds(),
      mockSignature
    );
    status = await actor.getTransactionStatus();
    console.log("Status after ParticipantB staking:", status);

    // 3. Test trading completion confirmation
    console.log("\n3. Testing trading completion confirmation...");
    const now = getCurrentTimestampInSeconds();
    await actor.confirmTradingComplete(now, now, mockSignature, mockSignature);
    status = await actor.getTransactionStatus();
    console.log("Status after trading completion:", status);

    // 4. Test settlement completion confirmation
    console.log("\n4. Testing settlement completion confirmation...");
    // ParticipantA settlement
    await actor.confirmSettlingComplete(
      config.stakeVault.solanaAddress,
      config.participantA.solanaAddress,
      getCurrentTimestampInSeconds(),
      mockSignature
    );
    status = await actor.getTransactionStatus();
    console.log("Status after ParticipantA settlement:", status);

    // ParticipantB settlement
    await actor.confirmSettlingComplete(
      config.stakeVault.solanaAddress,
      config.participantB.solanaAddress,
      getCurrentTimestampInSeconds(),
      mockSignature
    );
    status = await actor.getTransactionStatus();
    console.log("Status after ParticipantB settlement:", status);

    console.log("\nOptimistic test completed!");
  } catch (error) {
    console.error("Error during test:", error);
  }
}

// Run tests
runTests();
