import bs58 from "bs58";
import * as dotenv from "dotenv";
import * as nacl from "tweetnacl";
import * as ed25519 from "@noble/ed25519";
import * as sha512 from "@noble/hashes/sha512";

import { Actor, HttpAgent } from "@dfinity/agent";
import { Ed25519KeyIdentity } from "@dfinity/identity";
import { Principal } from "@dfinity/principal";

import { idlFactory } from "../.dfx/local/canisters/guarantee/service.did.js";

dotenv.config();

function generateKeyPair() {
  const keyPair = nacl.sign.keyPair();
  return {
    publicKey: bs58.encode(keyPair.publicKey),
    secretKey: keyPair.secretKey,
  };
}

function signMessage(message: string, secretKey: Uint8Array): string {
  const messageBytes = new TextEncoder().encode(message);
  const signature = nacl.sign.detached(messageBytes, secretKey);
  return bs58.encode(signature);
}

function hexToBytes(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < hex.length; i += 2) {
    bytes[i / 2] = parseInt(hex.substr(i, 2), 16);
  }
  return bytes;
}

const participantA = generateKeyPair();
const participantB = generateKeyPair();
const verifier = generateKeyPair();
const arbitrator = generateKeyPair();
const stakeVault = generateKeyPair();

const config = {
  stakeDuration: BigInt(60 * 60 * 24),
  tradeDuration: BigInt(60 * 60 * 24 * 7),
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

async function setupActor() {
  const canisterId = process.env.CANISTER_ID_GUARANTEE;
  if (!canisterId) throw new Error("Canister ID not found");

  const customIdentity = Ed25519KeyIdentity.generate();
  const agent = new HttpAgent({
    host: "http://127.0.0.1:4943",
    identity: customIdentity,
    verifyQuerySignatures: false,
  });
  await agent.fetchRootKey();

  const actor = Actor.createActor(idlFactory, { agent, canisterId });
  const principal = await actor.getThisCanisterPrincipalText();
  return { actor, principal: principal as string };
}

async function completeStaking(actor: any, principal: string, txId: string) {
  const participantAStakeTimestamp = getCurrentTimestampInSeconds();
  const stakeMessageA = `${principal}-${txId}-Staking-${config.stakeVault.solanaAddress}-${config.participantA.solanaAddress}-${participantAStakeTimestamp}`;
  const stakeSignatureA = signMessage(stakeMessageA, config.verifier.secretKey);

  await actor.confirmStakingComplete(
    txId,
    config.stakeVault.solanaAddress,
    config.participantA.solanaAddress,
    participantAStakeTimestamp,
    stakeSignatureA
  );

  const participantBStakeTimestamp = getCurrentTimestampInSeconds();
  const stakeMessageB = `${principal}-${txId}-Staking-${config.stakeVault.solanaAddress}-${config.participantB.solanaAddress}-${participantBStakeTimestamp}`;
  const stakeSignatureB = signMessage(stakeMessageB, config.verifier.secretKey);

  await actor.confirmStakingComplete(
    txId,
    config.stakeVault.solanaAddress,
    config.participantB.solanaAddress,
    participantBStakeTimestamp,
    stakeSignatureB
  );
}

async function completeTrading(
  actor: any,
  principal: string,
  txId: string,
  withVerifier = false
) {
  const tradeMessageA = `${principal}-${txId}-Trading`;
  const tradeMessageB = `${principal}-${txId}-Trading`;
  const tradeSignatureA = signMessage(
    tradeMessageA,
    config.participantA.secretKey
  );
  const tradeSignatureB = signMessage(
    tradeMessageB,
    config.participantB.secretKey
  );

  if (withVerifier) {
    const verifierTradeMessage = `${principal}-${txId}-Trading`;
    const verifierTradeSignature = signMessage(
      verifierTradeMessage,
      config.verifier.secretKey
    );
    await actor.confirmTradingComplete(txId, [], [], [verifierTradeSignature]);
  } else {
    await actor.confirmTradingComplete(
      txId,
      [tradeSignatureA],
      [tradeSignatureB],
      []
    );
  }
}

async function completeSettling(actor: any, principal: string, txId: string) {
  const participantASettleTimestamp = getCurrentTimestampInSeconds();
  const settleMessageA = `${principal}-${txId}-Settling-${config.stakeVault.solanaAddress}-${config.participantA.solanaAddress}-${participantASettleTimestamp}`;
  const settleSignatureA = signMessage(
    settleMessageA,
    config.verifier.secretKey
  );

  await actor.confirmSettlingComplete(
    txId,
    config.stakeVault.solanaAddress,
    config.participantA.solanaAddress,
    participantASettleTimestamp,
    settleSignatureA
  );

  const participantBSettleTimestamp = getCurrentTimestampInSeconds();
  const settleMessageB = `${principal}-${txId}-Settling-${config.stakeVault.solanaAddress}-${config.participantB.solanaAddress}-${participantBSettleTimestamp}`;
  const settleSignatureB = signMessage(
    settleMessageB,
    config.verifier.secretKey
  );

  await actor.confirmSettlingComplete(
    txId,
    config.stakeVault.solanaAddress,
    config.participantB.solanaAddress,
    participantBSettleTimestamp,
    settleSignatureB
  );
}

async function testBasicFunctionality(actor: any, principal: string) {
  console.log("=== Basic Functionality Tests ===");

  console.log("\n--- Settlement Escrow Mode ---");
  const settlementTxId = await actor.initialize(
    { Settlement: null },
    "Settlement escrow test",
    config.participantA.solanaAddress,
    config.participantB.solanaAddress,
    config.participantA.shouldStakeAmount,
    config.participantB.shouldStakeAmount,
    config.verifier.solanaAddress,
    config.arbitrator.solanaAddress,
    config.stakeDuration,
    config.tradeDuration
  );

  await completeStaking(actor, principal, settlementTxId);
  await completeTrading(actor, principal, settlementTxId);
  await completeSettling(actor, principal, settlementTxId);

  let status = await actor.getTransactionStatusText(settlementTxId);
  console.log("Settlement final status:", status);

  console.log("\n--- Mutual Escrow Mode ---");
  const mutualTxId = await actor.initialize(
    { Mutual: null },
    "Mutual escrow test",
    config.participantA.solanaAddress,
    config.participantB.solanaAddress,
    config.participantA.shouldStakeAmount,
    config.participantB.shouldStakeAmount,
    config.verifier.solanaAddress,
    config.arbitrator.solanaAddress,
    config.stakeDuration,
    config.tradeDuration
  );

  await completeStaking(actor, principal, mutualTxId);
  await completeTrading(actor, principal, mutualTxId);
  await completeSettling(actor, principal, mutualTxId);

  status = await actor.getTransactionStatusText(mutualTxId);
  console.log("Mutual final status:", status);

  let details = await actor.getTransactionDetails(mutualTxId);
}

async function testSignatureFunctionality(actor: any, principal: string) {
  console.log("\n=== Signature Functionality Tests ===");

  console.log("\n--- Verifier Signature Test ---");
  const verifierTxId = await actor.initialize(
    { Settlement: null },
    "Verifier signature test",
    config.participantA.solanaAddress,
    config.participantB.solanaAddress,
    config.participantA.shouldStakeAmount,
    config.participantB.shouldStakeAmount,
    config.verifier.solanaAddress,
    config.arbitrator.solanaAddress,
    config.stakeDuration,
    config.tradeDuration
  );

  await completeStaking(actor, principal, verifierTxId);
  await completeTrading(actor, principal, verifierTxId, true);

  let status = await actor.getTransactionStatusText(verifierTxId);
  console.log("Verifier signature status:", status);

  console.log("\n--- Schnorr Signature Test ---");
  const schnorrTxId = await actor.initialize(
    { Settlement: null },
    "Schnorr signature test",
    config.participantA.solanaAddress,
    config.participantB.solanaAddress,
    config.participantA.shouldStakeAmount,
    config.participantB.shouldStakeAmount,
    config.verifier.solanaAddress,
    config.arbitrator.solanaAddress,
    config.stakeDuration,
    config.tradeDuration
  );

  await completeStaking(actor, principal, schnorrTxId);
  await completeTrading(actor, principal, schnorrTxId);

  try {
    const schnorrPublicKey = await actor.getSchnorrPublicKey();
    console.log("Schnorr public key:", schnorrPublicKey);

    const signWithSchnorrContent =
      await actor.getSignWithSchnorrContent(schnorrTxId);
    console.log("signWithSchnorrContent:", signWithSchnorrContent);

    const schnorrSignature = await actor.signWithSchnorr(schnorrTxId);
    console.log("Schnorr signature:", schnorrSignature);

    const details = await actor.getTransactionDetails(schnorrTxId);
    const expectedMessage = `${principal}-${schnorrTxId}-Traded-Settlement-${details[0].participantA.participantSolanaAddress}-${details[0].participantA.withdrawableUSDCAmount}-${details[0].participantB.participantSolanaAddress}-${details[0].participantB.withdrawableUSDCAmount}-CanSettle`;
    console.log("Expected signature message:", expectedMessage);
    console.log("message equal:", expectedMessage == signWithSchnorrContent);

    try {
      ed25519.etc.sha512Sync = (...m) =>
        sha512.sha512(ed25519.etc.concatBytes(...m));

      const messageBytes = Uint8Array.from(
        Buffer.from(expectedMessage, "utf8")
      );

      const isValidSignature = await ed25519.verify(
        schnorrSignature,
        messageBytes,
        schnorrPublicKey
      );

      console.log("Signature verification result:", isValidSignature);

      if (isValidSignature) {
        console.log(
          "Signature verified successfully, proceeding with settling..."
        );
        await completeSettling(actor, principal, schnorrTxId);
        const finalStatus = await actor.getTransactionStatusText(schnorrTxId);
        console.log("Schnorr transaction final status:", finalStatus);
      } else {
        throw Error("Schnorr signature verification failed");
      }
    } catch (verifyError) {
      console.log("Signature verification error:", verifyError);
    }
  } catch (error) {
    console.log("Schnorr signature error (expected in some states):", error);
  }
}

async function testExceptionScenarios(actor: any, principal: string) {
  console.log("\n=== Exception Scenario Tests ===");

  console.log("\n--- Timeout Scenarios ---");
  const timeoutTxId = await actor.initialize(
    { Settlement: null },
    "Timeout test",
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

  try {
    await completeStaking(actor, principal, timeoutTxId);
    let status = await actor.getTransactionStatusText(timeoutTxId);
    console.log("Timeout test status:", status);
  } catch (error) {
    console.log("Timeout handled correctly:", error);
  }

  console.log("\n--- Dispute Scenario ---");
  const disputeTxId = await actor.initialize(
    { Settlement: null },
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

  await completeStaking(actor, principal, disputeTxId);

  const disputeTimestamp = getCurrentTimestampInSeconds();
  const disputeMessage = `${principal}-${disputeTxId}-Disputing-${config.participantA.solanaAddress}-${disputeTimestamp}`;
  const disputeSignature = signMessage(
    disputeMessage,
    config.participantA.secretKey
  );

  await actor.initiateDispute(
    disputeTxId,
    config.participantA.solanaAddress,
    disputeTimestamp,
    [disputeSignature],
    []
  );

  const customAmountA = BigInt(600 * 1_000_000);
  const customAmountB = BigInt(400 * 1_000_000);
  const resolveTimestamp = getCurrentTimestampInSeconds();
  const resolveMessage = `${principal}-${disputeTxId}-Resolving-${customAmountA}-${customAmountB}-${resolveTimestamp}`;
  const resolveSignature = signMessage(
    resolveMessage,
    config.arbitrator.secretKey
  );

  await actor.resolveDispute(
    disputeTxId,
    "Dispute resolved",
    customAmountA,
    customAmountB,
    resolveTimestamp,
    resolveSignature
  );

  await completeSettling(actor, principal, disputeTxId);

  let status = await actor.getTransactionStatusText(disputeTxId);
  console.log("Dispute resolution status:", status);

  try {
    const fetchedProof = await actor.fetchProof(disputeTxId);
    const proofDetails = await actor.getProofDetails(disputeTxId);
    console.log("Proof details:", proofDetails);
  } catch (proofError) {
    console.log("Proof fetch error:", proofError);
  }
}

async function testUtilityFunctions(actor: any, principal: string) {
  console.log("\n=== Utility Function Tests ===");

  console.log("\n--- Recent Transaction IDs ---");
  const recentTxs = await actor.getRecentTransactionIds(5);
  console.log("Recent 5 transactions:", recentTxs);

  console.log("\n--- All Transaction IDs ---");
  const allTxs = await actor.getAllTransactionIds();
  console.log("Total transactions count:", allTxs.length);
  console.log("All transaction IDs:", allTxs);

  console.log("\n--- Transaction Details Test ---");
  const latestTxId = recentTxs[0];
  console.log("Latest transaction ID:", latestTxId);

  const txDetails = await actor.getTransactionDetails(latestTxId);
  console.log("Transaction details:", txDetails);
}

async function runTests() {
  try {
    console.log("Starting Guarantee Contract Tests...");
    console.log("Participant A:", config.participantA.solanaAddress);
    console.log("Participant B:", config.participantB.solanaAddress);
    console.log("Verifier:", config.verifier.solanaAddress);
    console.log("Arbitrator:", config.arbitrator.solanaAddress);
    console.log("Stake Vault:", config.stakeVault.solanaAddress);

    const { actor, principal } = await setupActor();
    console.log("Contract Principal:", principal);

    await testBasicFunctionality(actor, principal);
    await testSignatureFunctionality(actor, principal);
    await testExceptionScenarios(actor, principal);
    await testUtilityFunctions(actor, principal);

    console.log("\n=== All Tests Completed Successfully ===");
  } catch (error) {
    console.error("Test execution error:", error);
  }
}

runTests();
