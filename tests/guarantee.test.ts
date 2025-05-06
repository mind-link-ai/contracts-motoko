import bs58 from "bs58";
import * as dotenv from "dotenv";
import * as nacl from "tweetnacl";
import { Actor, HttpAgent } from "@dfinity/agent";
import { Principal } from "@dfinity/principal";
import { idlFactory } from "../.dfx/playground/canisters/guarantee/service.did.js";

dotenv.config();

// Generate Solana key pair
function generateKeyPair() {
  const keyPair = nacl.sign.keyPair();
  return {
    publicKey: bs58.encode(keyPair.publicKey),
    secretKey: keyPair.secretKey,
  };
}

// Signing function
function signMessage(message: string, secretKey: Uint8Array): string {
  const messageBytes = new TextEncoder().encode(message);
  const signature = nacl.sign.detached(messageBytes, secretKey);
  return bs58.encode(signature);
}

// Generate test key pairs
const participantA = generateKeyPair();
const participantB = generateKeyPair();
const verifier = generateKeyPair();
const arbitrator = generateKeyPair();
const stakeVault = generateKeyPair();

const config = {
  stakeDuration: BigInt(60 * 60 * 24), // 1 day
  tradeDuration: BigInt(60 * 60 * 24 * 7), // 7 days
  participantA: {
    solanaAddress: participantA.publicKey,
    shouldStakeAmount: BigInt(1000 * 1_000_000),
    secretKey: participantA.secretKey,
  },
  participantB: {
    solanaAddress: participantB.publicKey,
    shouldStakeAmount: BigInt(1000 * 1_000_000),
    secretKey: participantB.secretKey,
  },
  verifier: {
    solanaAddress: verifier.publicKey,
    secretKey: verifier.secretKey,
  },
  arbitrator: {
    solanaAddress: arbitrator.publicKey,
    secretKey: arbitrator.secretKey,
  },
  stakeVault: {
    solanaAddress: stakeVault.publicKey,
  },
};

const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const getCurrentTimestampInSeconds = () =>
  BigInt(Math.floor(Date.now() / 1000));

async function runTests() {
  try {
    console.log("Starting guarantee contract tests...");
    console.log("Participant A address:", config.participantA.solanaAddress);
    console.log("Participant B address:", config.participantB.solanaAddress);
    console.log("Verifier address:", config.verifier.solanaAddress);
    console.log("Arbitrator address:", config.arbitrator.solanaAddress);
    console.log("Stake vault address:", config.stakeVault.solanaAddress);

    const canisterId = process.env.CANISTER_ID_GUARANTEE;
    if (!canisterId) throw new Error("Canister ID not found");

    const agent = new HttpAgent({ host: "https://icp0.io" });
    const actor = Actor.createActor(idlFactory, { agent, canisterId });
    const principal = await actor.getThisCanisterPrincipalText();
    console.log("Contract Principal:", principal);

    console.log("\n1. Testing happy path");
    await testHappyPath(actor, principal as string);

    console.log("\n2. Testing timeout scenario");
    await testTimeoutScenario(actor, principal as string);

    console.log("\n3. Testing dispute scenario");
    await testDisputeScenario(actor, principal as string);

    console.log("\nAll tests completed!");
  } catch (error) {
    console.error("Test error:", error);
  }
}

async function testHappyPath(actor: any, principal: string) {
  console.log("=== happy path begins ===");
  console.log("=== step: init ===");
  console.log("party A address: " + config.participantA.solanaAddress);
  console.log("party B address: " + config.participantB.solanaAddress);
  console.log("party A stake amount: " + config.participantA.shouldStakeAmount);
  console.log("party B stake amount: " + config.participantB.shouldStakeAmount);
  console.log("verifier address: " + config.verifier.solanaAddress);
  console.log("arbitrator address: " + config.arbitrator.solanaAddress);
  console.log("stake duration: " + config.stakeDuration);
  console.log("trade duration: " + config.tradeDuration);
  console.log("");
  await actor.initialize(
    "Normal transaction test",
    config.participantA.solanaAddress,
    config.participantB.solanaAddress,
    config.participantA.shouldStakeAmount,
    config.participantB.shouldStakeAmount,
    config.verifier.solanaAddress,
    config.arbitrator.solanaAddress,
    config.stakeDuration,
    config.tradeDuration
  );
  let status = await actor.getTransactionStatusText();
  console.log("Initial status:", status);
  let details = await actor.getTransactionDetails();
  console.log("Initial details:", details);

  // Participant A staking complete
  const participantAStakeTimestamp = getCurrentTimestampInSeconds();
  const stakeMessageA = `${principal}-Staking-${config.stakeVault.solanaAddress}-${config.participantA.solanaAddress}-${participantAStakeTimestamp}`;
  const stakeSignatureA = signMessage(stakeMessageA, config.verifier.secretKey);

  console.log("=== step: stake by party A ===");
  console.log("vault address: " + config.stakeVault.solanaAddress);
  console.log("party A address: " + config.participantA.solanaAddress);
  console.log("party A stake ts: " + participantAStakeTimestamp);
  console.log("party A sig: " + stakeSignatureA);
  console.log("");
  await actor.confirmStakingComplete(
    config.stakeVault.solanaAddress,
    config.participantA.solanaAddress,
    participantAStakeTimestamp,
    stakeSignatureA
  );
  status = await actor.getTransactionStatusText();
  console.log("Participant A staking status:", status);

  // Participant B staking complete
  const participantBStakeTimestamp = getCurrentTimestampInSeconds();
  const stakeMessageB = `${principal}-Staking-${config.stakeVault.solanaAddress}-${config.participantB.solanaAddress}-${participantBStakeTimestamp}`;
  const stakeSignatureB = signMessage(stakeMessageB, config.verifier.secretKey);

  console.log("=== step: stake by party B ===");
  console.log("vault address: " + config.stakeVault.solanaAddress);
  console.log("party B address: " + config.participantB.solanaAddress);
  console.log("party B stake ts: " + participantBStakeTimestamp);
  console.log("party B sig: " + stakeSignatureB);
  console.log("");
  await actor.confirmStakingComplete(
    config.stakeVault.solanaAddress,
    config.participantB.solanaAddress,
    participantBStakeTimestamp,
    stakeSignatureB
  );
  status = await actor.getTransactionStatusText();
  console.log("Participant B staking status:", status);

  // Trading complete
  const participantATradeTimestamp = getCurrentTimestampInSeconds();
  const participantBTradeTimestamp = getCurrentTimestampInSeconds();

  const tradeMessageA = `${principal}-Trading-${participantATradeTimestamp}`;
  const tradeMessageB = `${principal}-Trading-${participantBTradeTimestamp}`;

  const tradeSignatureA = signMessage(
    tradeMessageA,
    config.participantA.secretKey
  );
  const tradeSignatureB = signMessage(
    tradeMessageB,
    config.participantB.secretKey
  );

  console.log("=== step: confirm trade ===");
  console.log("party A trade ts: " + participantATradeTimestamp);
  console.log("party B trade ts: " + participantBTradeTimestamp);
  console.log("party A sig: " + tradeSignatureA);
  console.log("party B sig: " + tradeSignatureB);
  console.log("");
  await actor.confirmTradingComplete(
    participantATradeTimestamp,
    participantBTradeTimestamp,
    tradeSignatureA,
    tradeSignatureB
  );
  status = await actor.getTransactionStatusText();
  console.log("Trading complete status:", status);

  // Participant A settling complete
  const participantASettleTimestamp = getCurrentTimestampInSeconds();
  const settleMessageA = `${principal}-Settling-${config.stakeVault.solanaAddress}-${config.participantA.solanaAddress}-${participantASettleTimestamp}`;
  const settleSignatureA = signMessage(
    settleMessageA,
    config.verifier.secretKey
  );

  console.log("=== step: settle A ===");
  console.log("vault address: " + config.stakeVault.solanaAddress);
  console.log("party A address: " + config.participantA.solanaAddress);
  console.log("party A settle ts: " + participantASettleTimestamp);
  console.log("party A sig: " + settleSignatureA);
  console.log("");
  await actor.confirmSettlingComplete(
    config.stakeVault.solanaAddress,
    config.participantA.solanaAddress,
    participantASettleTimestamp,
    settleSignatureA
  );
  status = await actor.getTransactionStatusText();
  console.log("Participant A settling status:", status);

  // Participant B settling complete
  const participantBSettleTimestamp = getCurrentTimestampInSeconds();
  const settleMessageB = `${principal}-Settling-${config.stakeVault.solanaAddress}-${config.participantB.solanaAddress}-${participantBSettleTimestamp}`;
  const settleSignatureB = signMessage(
    settleMessageB,
    config.verifier.secretKey
  );

  console.log("=== step: settle B ===");
  console.log("vault address: " + config.stakeVault.solanaAddress);
  console.log("party B address: " + config.participantB.solanaAddress);
  console.log("party B settle ts: " + participantBSettleTimestamp);
  console.log("party B sig: " + settleSignatureB);
  console.log("");
  await actor.confirmSettlingComplete(
    config.stakeVault.solanaAddress,
    config.participantB.solanaAddress,
    participantBSettleTimestamp,
    settleSignatureB
  );
  status = await actor.getTransactionStatusText();
  console.log("Participant B settling status:", status);

  details = await actor.getTransactionDetails();
  console.log("Final details:", details);
  console.log("=== happy path ended ===");
}

async function testTimeoutScenario(actor: any, principal: string) {
  await actor.initialize(
    "Staking timeout test",
    config.participantA.solanaAddress,
    config.participantB.solanaAddress,
    config.participantA.shouldStakeAmount,
    config.participantB.shouldStakeAmount,
    config.verifier.solanaAddress,
    config.arbitrator.solanaAddress,
    BigInt(1), // Timeout after 1 second
    config.tradeDuration
  );
  await delay(2000); // Wait 2 seconds to ensure timeout

  const participantAStakeTimestamp = getCurrentTimestampInSeconds();
  const stakeMessageA = `${principal}-Staking-${config.stakeVault.solanaAddress}-${config.participantA.solanaAddress}-${participantAStakeTimestamp}`;
  const stakeSignatureA = signMessage(stakeMessageA, config.verifier.secretKey);

  await actor.confirmStakingComplete(
    config.stakeVault.solanaAddress,
    config.participantA.solanaAddress,
    participantAStakeTimestamp,
    stakeSignatureA
  );
  let status = await actor.getTransactionStatusText();
  console.log("Staking timeout status:", status);
  let details = await actor.getTransactionDetails();
  console.log("Staking timeout details:", details);

  // Trading timeout test
  await actor.initialize(
    "Trading timeout test",
    config.participantA.solanaAddress,
    config.participantB.solanaAddress,
    config.participantA.shouldStakeAmount,
    config.participantB.shouldStakeAmount,
    config.verifier.solanaAddress,
    config.arbitrator.solanaAddress,
    config.stakeDuration,
    BigInt(1) // Timeout after 1 second
  );

  // Participant A staking
  const participantAStakeTimestamp2 = getCurrentTimestampInSeconds();
  const stakeMessageA2 = `${principal}-Staking-${config.stakeVault.solanaAddress}-${config.participantA.solanaAddress}-${participantAStakeTimestamp2}`;
  const stakeSignatureA2 = signMessage(
    stakeMessageA2,
    config.verifier.secretKey
  );

  await actor.confirmStakingComplete(
    config.stakeVault.solanaAddress,
    config.participantA.solanaAddress,
    participantAStakeTimestamp2,
    stakeSignatureA2
  );

  // Participant B staking
  const participantBStakeTimestamp2 = getCurrentTimestampInSeconds();
  const stakeMessageB2 = `${principal}-Staking-${config.stakeVault.solanaAddress}-${config.participantB.solanaAddress}-${participantBStakeTimestamp2}`;
  const stakeSignatureB2 = signMessage(
    stakeMessageB2,
    config.verifier.secretKey
  );

  await actor.confirmStakingComplete(
    config.stakeVault.solanaAddress,
    config.participantB.solanaAddress,
    participantBStakeTimestamp2,
    stakeSignatureB2
  );

  await delay(2000); // Wait 2 seconds to ensure timeout

  // Try to confirm trading complete
  const participantATradeTimestamp = getCurrentTimestampInSeconds();
  const participantBTradeTimestamp = getCurrentTimestampInSeconds();

  const tradeMessageA = `${principal}-Trading-${participantATradeTimestamp}`;
  const tradeMessageB = `${principal}-Trading-${participantBTradeTimestamp}`;

  const tradeSignatureA = signMessage(
    tradeMessageA,
    config.participantA.secretKey
  );
  const tradeSignatureB = signMessage(
    tradeMessageB,
    config.participantB.secretKey
  );

  await actor.confirmTradingComplete(
    participantATradeTimestamp,
    participantBTradeTimestamp,
    tradeSignatureA,
    tradeSignatureB
  );

  status = await actor.getTransactionStatusText();
  console.log("Trading timeout status:", status);
  details = await actor.getTransactionDetails();
  console.log("Trading timeout details:", details);
}

async function testDisputeScenario(actor: any, principal: string) {
  await actor.initialize(
    "Dispute test",
    config.participantA.solanaAddress,
    config.participantB.solanaAddress,
    config.participantA.shouldStakeAmount,
    config.participantB.shouldStakeAmount,
    config.verifier.solanaAddress,
    config.arbitrator.solanaAddress,
    config.stakeDuration,
    config.tradeDuration
  );

  // Participant A staking
  const participantAStakeTimestamp = getCurrentTimestampInSeconds();
  const stakeMessageA = `${principal}-Staking-${config.stakeVault.solanaAddress}-${config.participantA.solanaAddress}-${participantAStakeTimestamp}`;
  const stakeSignatureA = signMessage(stakeMessageA, config.verifier.secretKey);

  await actor.confirmStakingComplete(
    config.stakeVault.solanaAddress,
    config.participantA.solanaAddress,
    participantAStakeTimestamp,
    stakeSignatureA
  );

  // Participant B staking
  const participantBStakeTimestamp = getCurrentTimestampInSeconds();
  const stakeMessageB = `${principal}-Staking-${config.stakeVault.solanaAddress}-${config.participantB.solanaAddress}-${participantBStakeTimestamp}`;
  const stakeSignatureB = signMessage(stakeMessageB, config.verifier.secretKey);

  await actor.confirmStakingComplete(
    config.stakeVault.solanaAddress,
    config.participantB.solanaAddress,
    participantBStakeTimestamp,
    stakeSignatureB
  );

  // Participant A initiates dispute
  const participantADisputeTimestamp = getCurrentTimestampInSeconds();
  const disputeMessageA = `${principal}-Disputing-${participantADisputeTimestamp}`;
  const disputeSignatureA = signMessage(
    disputeMessageA,
    config.participantA.secretKey
  );

  await actor.initiateDispute(
    config.participantA.solanaAddress,
    participantADisputeTimestamp,
    disputeSignatureA
  );

  // Arbitrator resolves dispute
  const participantAWithdrawableAmount = BigInt(600 * 1_000_000);
  const participantBWithdrawableAmount = BigInt(400 * 1_000_000);
  const arbitratorResolveTimestamp = getCurrentTimestampInSeconds();

  const resolveMessage = `${principal}-Resolving-${participantAWithdrawableAmount}-${participantBWithdrawableAmount}-${arbitratorResolveTimestamp}`;
  const resolveSignature = signMessage(
    resolveMessage,
    config.arbitrator.secretKey
  );

  await actor.resolveDispute(
    "Dispute resolution details",
    participantAWithdrawableAmount,
    participantBWithdrawableAmount,
    arbitratorResolveTimestamp,
    resolveSignature
  );
  let status = await actor.getTransactionStatusText();
  console.log("Dispute resolution status:", status);

  // Participant A settling
  const participantASettleTimestamp = getCurrentTimestampInSeconds();
  const settleMessageA = `${principal}-Settling-${config.stakeVault.solanaAddress}-${config.participantA.solanaAddress}-${participantASettleTimestamp}`;
  const settleSignatureA = signMessage(
    settleMessageA,
    config.verifier.secretKey
  );

  await actor.confirmSettlingComplete(
    config.stakeVault.solanaAddress,
    config.participantA.solanaAddress,
    participantASettleTimestamp,
    settleSignatureA
  );

  // Participant B settling
  const participantBSettleTimestamp = getCurrentTimestampInSeconds();
  const settleMessageB = `${principal}-Settling-${config.stakeVault.solanaAddress}-${config.participantB.solanaAddress}-${participantBSettleTimestamp}`;
  const settleSignatureB = signMessage(
    settleMessageB,
    config.verifier.secretKey
  );

  await actor.confirmSettlingComplete(
    config.stakeVault.solanaAddress,
    config.participantB.solanaAddress,
    participantBSettleTimestamp,
    settleSignatureB
  );

  status = await actor.getTransactionStatusText();
  console.log("Dispute settlement status:", status);
}

runTests();
