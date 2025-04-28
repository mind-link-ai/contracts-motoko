import * as dotenv from "dotenv";
import { Actor, HttpAgent } from "@dfinity/agent";
import { Principal } from "@dfinity/principal";
import { idlFactory } from "../.dfx/playground/canisters/guarantee/service.did.js";

dotenv.config();

const config = {
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
const mockSignature = "MockSignature";

const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const getCurrentTimestampInSeconds = () =>
  BigInt(Math.floor(Date.now() / 1000));

async function runTests() {
  try {
    console.log("Starting guarantee contract tests...");

    const canisterId = process.env.CANISTER_ID_GUARANTEE;
    if (!canisterId) throw new Error("Canister ID not found");

    const agent = new HttpAgent({ host: "https://icp0.io" });
    const actor = Actor.createActor(idlFactory, { agent, canisterId });
    const principal = await actor.getThisCanisterPrincipal();
    console.log("Contract Principal:", principal);

    console.log("\n1. Testing normal flow");
    await testHappyPath(actor);

    console.log("\n2. Testing timeout scenarios");
    await testTimeoutScenario(actor);

    console.log("\n3. Testing dispute scenario");
    await testDisputeScenario(actor);

    console.log("\nAll tests completed!");
  } catch (error) {
    console.error("Test error:", error);
  }
}

async function testHappyPath(actor: any) {
  await actor.initialize(
    "Normal Transaction",
    config.participantA.solanaAddress,
    config.participantB.solanaAddress,
    config.participantA.shouldStakeAmount,
    config.participantB.shouldStakeAmount,
    config.verifier.solanaAddress,
    config.arbitrator.solanaAddress,
    config.stakeDuration,
    config.tradeDuration
  );
  let status = await actor.getTransactionStatus();
  console.log("Init status:", status);
  let details = await actor.getTransactionDetails();
  console.log("Init details:", details);

  await actor.confirmStakingComplete(
    config.stakeVault.solanaAddress,
    config.participantA.solanaAddress,
    getCurrentTimestampInSeconds(),
    mockSignature
  );
  status = await actor.getTransactionStatus();
  console.log("Participant A staking status:", status);

  await actor.confirmStakingComplete(
    config.stakeVault.solanaAddress,
    config.participantB.solanaAddress,
    getCurrentTimestampInSeconds(),
    mockSignature
  );
  status = await actor.getTransactionStatus();
  console.log("Participant B staking status:", status);

  const now = getCurrentTimestampInSeconds();
  await actor.confirmTradingComplete(now, now, mockSignature, mockSignature);
  status = await actor.getTransactionStatus();
  console.log("Trading complete status:", status);

  await actor.confirmSettlingComplete(
    config.stakeVault.solanaAddress,
    config.participantA.solanaAddress,
    getCurrentTimestampInSeconds(),
    mockSignature
  );
  status = await actor.getTransactionStatus();
  console.log("Participant A settlement status:", status);

  await actor.confirmSettlingComplete(
    config.stakeVault.solanaAddress,
    config.participantB.solanaAddress,
    getCurrentTimestampInSeconds(),
    mockSignature
  );
  status = await actor.getTransactionStatus();
  console.log("Participant B settlement status:", status);

  details = await actor.getTransactionDetails();
  console.log("Final details:", details);
}

async function testTimeoutScenario(actor: any) {
  await actor.initialize(
    "Staking Timeout Test",
    config.participantA.solanaAddress,
    config.participantB.solanaAddress,
    config.participantA.shouldStakeAmount,
    config.participantB.shouldStakeAmount,
    config.verifier.solanaAddress,
    config.arbitrator.solanaAddress,
    BigInt(1),
    config.tradeDuration
  );
  await delay(2000);
  await actor.confirmStakingComplete(
    config.stakeVault.solanaAddress,
    config.participantA.solanaAddress,
    getCurrentTimestampInSeconds(),
    mockSignature
  );
  let status = await actor.getTransactionStatus();
  console.log("Stake timeout status:", status);
  let details = await actor.getTransactionDetails();
  console.log("Stake timeout details:", details);

  await actor.initialize(
    "Trading Timeout Test",
    config.participantA.solanaAddress,
    config.participantB.solanaAddress,
    config.participantA.shouldStakeAmount,
    config.participantB.shouldStakeAmount,
    config.verifier.solanaAddress,
    config.arbitrator.solanaAddress,
    config.stakeDuration,
    BigInt(1)
  );
  await actor.confirmStakingComplete(
    config.stakeVault.solanaAddress,
    config.participantA.solanaAddress,
    getCurrentTimestampInSeconds(),
    mockSignature
  );
  await actor.confirmStakingComplete(
    config.stakeVault.solanaAddress,
    config.participantB.solanaAddress,
    getCurrentTimestampInSeconds(),
    mockSignature
  );
  await delay(2000);

  const now = getCurrentTimestampInSeconds();
  await actor.confirmTradingComplete(now, now, mockSignature, mockSignature);
  status = await actor.getTransactionStatus();
  console.log("Trade timeout status:", status);
  details = await actor.getTransactionDetails();
  console.log("Stake timeout details:", details);
}

async function testDisputeScenario(actor: any) {
  await actor.initialize(
    "Dispute Test",
    config.participantA.solanaAddress,
    config.participantB.solanaAddress,
    config.participantA.shouldStakeAmount,
    config.participantB.shouldStakeAmount,
    config.verifier.solanaAddress,
    config.arbitrator.solanaAddress,
    config.stakeDuration,
    config.tradeDuration
  );

  await actor.confirmStakingComplete(
    config.stakeVault.solanaAddress,
    config.participantA.solanaAddress,
    getCurrentTimestampInSeconds(),
    mockSignature
  );
  await actor.confirmStakingComplete(
    config.stakeVault.solanaAddress,
    config.participantB.solanaAddress,
    getCurrentTimestampInSeconds(),
    mockSignature
  );

  await actor.initiateDispute(
    config.participantA.solanaAddress,
    getCurrentTimestampInSeconds(),
    mockSignature
  );

  await actor.resolveDispute(
    "Dispute resolution details",
    60,
    40,
    getCurrentTimestampInSeconds(),
    mockSignature
  );
  let status = await actor.getTransactionStatus();
  console.log("Dispute resolved status:", status);

  await actor.confirmSettlingComplete(
    config.stakeVault.solanaAddress,
    config.participantA.solanaAddress,
    getCurrentTimestampInSeconds(),
    mockSignature
  );
  await actor.confirmSettlingComplete(
    config.stakeVault.solanaAddress,
    config.participantB.solanaAddress,
    getCurrentTimestampInSeconds(),
    mockSignature
  );
  status = await actor.getTransactionStatus();
  console.log("Dispute settlement status:", status);
}

runTests();
