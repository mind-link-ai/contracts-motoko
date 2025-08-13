import * as fs from "fs";
import * as express from "express";
import bs58 from "bs58";
import { Response, Request, NextFunction } from "express";
import { Actor, HttpAgent } from "@dfinity/agent";
import { Ed25519KeyIdentity } from "@dfinity/identity";
import { idlFactory } from "./.dfx/local/canisters/guarantee/service.did.js";
import * as dotenv from "dotenv";
import * as nacl from "tweetnacl";

dotenv.config();

const CANISTER_ID = process.env.CANISTER_ID_GUARANTEE as string;
const ICP_HOST = process.env.ICP_HOST || "http://127.0.0.1:4943";

const VAULT_ADDRESS = process.env.VAULT_ADDRESS;
const VERIFIER_KEYPAIR_PATH = process.env.VERIFIER_KEYPAIR_PATH;
const ARBITRATOR_KEYPAIR_PATH = process.env.ARBITRATOR_KEYPAIR_PATH;

if (!CANISTER_ID) {
  throw new Error("CANISTER_ID_GUARANTEE env variable missing");
}

if (!VAULT_ADDRESS) {
  throw new Error("VAULT_ADDRESS env var missing");
}

if (!VERIFIER_KEYPAIR_PATH) {
  throw new Error("VERIFIER_KEYPAIR_PATH env var missing");
}

if (!ARBITRATOR_KEYPAIR_PATH) {
  throw new Error("ARBITRATOR_KEYPAIR_PATH env var missing");
}

interface KeyPair {
  publicKey: string;
  secretKey: Uint8Array;
}

function generateKeyPair(): KeyPair {
  const keyPair = nacl.sign.keyPair();
  return {
    publicKey: bs58.encode(keyPair.publicKey),
    secretKey: keyPair.secretKey,
  };
}

function createOrGetKeyPair(path: string): KeyPair {
  let identity: KeyPair;
  if (fs.existsSync(path!)) {
    const json = fs.readFileSync(path!, "utf8");
    const raw = JSON.parse(json);
    identity = {
      publicKey: raw.publicKey,
      secretKey: bs58.decode(raw.secretKey)
    }
  } else {
    identity = generateKeyPair();
    const json = JSON.stringify({
      publicKey: identity.publicKey,
      secretKey: bs58.encode(identity.secretKey)
    });
    fs.writeFileSync(path, json);
  }
  return identity;
}

function signMessage(message: string, keypair: KeyPair): string {
  const messageBytes = new TextEncoder().encode(message);
  const signature = nacl.sign.detached(messageBytes, keypair.secretKey);
  return bs58.encode(signature);
}

async function createActor() {
  const identity = Ed25519KeyIdentity.generate();
  const agent = HttpAgent.createSync({
    host: ICP_HOST,
    identity,
    verifyQuerySignatures: false,
  });
  // for local testing
  if (ICP_HOST.includes("127.0.0.1")) {
    await agent.fetchRootKey();
  }
  return Actor.createActor(idlFactory, { agent, canisterId: CANISTER_ID });
}

const now = () =>
  BigInt(Math.floor(Date.now() / 1000));

const AGENT = createActor();
const VERIFIER = createOrGetKeyPair(VERIFIER_KEYPAIR_PATH);
const ARBITRATOR = createOrGetKeyPair(ARBITRATOR_KEYPAIR_PATH);

function requireBearer(expectedToken: string) {
  return (req: Request, res: Response, next: NextFunction) => {
    const auth = req.headers.authorization || '';
    const isBearer = auth.toLowerCase().startsWith('bearer ');
    const token = isBearer ? auth.slice(7).trim() : null;

    if (!token || token !== expectedToken) {
      return res.status(401).json({ error: 'Unauthorized' });
    }
    next();
  };
}

const app = express();
app.use(express.json());
if (process.env.AUTH_ENABLED) {
  const authToken = process.env.AUTH_TOKEN;
  if (!authToken) {
    throw new Error("AUTH_TOKEN env var missing");
  }
  app.use(requireBearer(authToken));
}

////////////////////////////////////////// API begins ///////////////////////////////////////////////

/**
 * initialize an escrow transaction:
 * - field escrowMode (optional),
 * -   default to Settlement mode, where party A's stake amount will be transferred to B after settle
 * -   if you choose Mutual mode, each party's stake amount will go back to its original owner
 * - field comments (optional), any description or external ID for this transaction
 * - field participantASolanaAddress, party A's address
 * - field participantBSolanaAddress, party B's address
 * - field participantAShouldStakeUSDCAmount, party A's stake amount
 * - field participantBShouldStakeUSDCAmount, party B's stake amount
 * - field stakeDuration (optional), duration in seconds before stake timeout, default to 1 day
 * - field tradeDuration (optional), duration in seconds before trade timeout, default to 1 week
 */
app.post("/initialize", async (req: Request, res: Response) => {
  try {
    const actor = await AGENT;
    const mode =
      req.body.escrowMode === "Mutual"
        ? { Mutual: null }
        : { Settlement: null };
    const txId = await actor.initialize(
      mode,
      req.body.comments ?? "normal transaction",
      req.body.participantASolanaAddress,
      req.body.participantBSolanaAddress,
      BigInt(req.body.participantAShouldStakeUSDCAmount),
      BigInt(req.body.participantBShouldStakeUSDCAmount),
      VERIFIER.publicKey,
      ARBITRATOR.publicKey,
      BigInt(req.body.stakeDuration ?? 60 * 60 * 24),
      BigInt(req.body.tradeDuration ?? 60 * 60 * 24 * 7),
    );
    res.json({ txId });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: String(err) });
  }
});

/**
 * confirm party's staking
 * - field transactionId, the escrow transaction ID
 * - field participantSolanaAddress, party's address
 */
app.post("/confirmStaking", async (req: Request, res: Response) => {
  try {
    const actor = await AGENT;

    const principal = await actor.getThisCanisterPrincipalText() as string;
    const txId = req.body.transactionId;
    const party = req.body.participantSolanaAddress;
    const ts = now();
    const stakeMessage = `${principal}-${txId}-Staking-${VAULT_ADDRESS}-${party}-${ts}`;
    const stakeSignature = signMessage(stakeMessage, VERIFIER);

    await actor.confirmStakingComplete(
      txId,
      VAULT_ADDRESS,
      party,
      ts,
      stakeSignature,
    );
    res.json({ success: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: String(err) });
  }
});

/**
 * confirm trading result
 * - field transactionId, the escrow transaction ID
 * - field participantASignature (optional if verifier-driven)
 * - field participantBSignature (optional if verifier-driven)
 */
app.post("/confirmTrading", async (req: Request, res: Response) => {
  try {
    const actor = await AGENT;

    const partyASignature = req.body.participantASignature;
    const partyBSignature = req.body.participantBSignature;

    const principal = await actor.getThisCanisterPrincipalText() as string;
    const txId = req.body.transactionId;
    if (partyASignature && partyBSignature) {
      await actor.confirmTradingComplete(
        txId,
        [partyASignature],
        [partyBSignature],
        [],
      );
    } else {
      const tradeMessage = `${principal}-${txId}-Trading`;
      const tradeSignature = signMessage(
        tradeMessage,
        VERIFIER
      );
      await actor.confirmTradingComplete(
        txId,
        [],
        [],
        [tradeSignature],
      );
    }
    res.json({ success: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: String(err) });
  }
});

/**
 * confirm settlement
 * - field transactionId, the escrow transaction ID
 * - field participantSolanaAddress, party's address
 */
app.post("/confirmSettling", async (req: Request, res: Response) => {
  try {
    const actor = await AGENT;

    const principal = await actor.getThisCanisterPrincipalText() as string;
    const txId = req.body.transactionId;
    const ts = now();
    const party = req.body.participantSolanaAddress;

    const settleMessage = `${principal}-${txId}-Settling-${VAULT_ADDRESS}-${party}-${ts}`;
    const settleSignature = signMessage(
      settleMessage,
      VERIFIER
    );
    await actor.confirmSettlingComplete(
      txId,
      VAULT_ADDRESS,
      party,
      ts,
      settleSignature,
    );
    res.json({ success: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: String(err) });
  }
});

/**
 * raise dispute
 * - field transactionId, the escrow transaction ID
 * - field participantSolanaAddress, party's address
 * - field participantSignature (optional if verifier-driven)
 */
app.post("/initiateDispute", async (req: Request, res: Response) => {
  try {
    const actor = await AGENT;
    const principal = await actor.getThisCanisterPrincipalText() as string;
    const txId = req.body.transactionId;
    const ts = now();
    const party = req.body.participantSolanaAddress;
    const partySignature = req.body.participantSignature;

    if (partySignature) {
      await actor.initiateDispute(
        txId,
        party,
        ts,
        [partySignature],
        [],
      );
    } else {
      const disputeMessage = `${principal}-${txId}-Disputing-${party}-${ts}`;
      const disputeSignature = signMessage(
        disputeMessage,
        VERIFIER
      );
      await actor.initiateDispute(
        txId,
        party,
        ts,
        [],
        [disputeSignature],
      );
    }
    res.json({ success: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: String(err) });
  }
});

/**
 * resolve dispute
 * - field transactionId
 * - field comments
 * - field participantAWithdrawableUSDCAmount, the withdrawable amount for party A settlement
 * - field participantBWithdrawableUSDCAmount, the withdrawable amount for party B settlement
 */
app.post("/resolveDispute", async (req: Request, res: Response) => {
  try {
    const actor = await AGENT;

    const principal = await actor.getThisCanisterPrincipalText() as string;
    const txId = req.body.transactionId;
    const ts = now();

    const customAmountA = BigInt(req.body.participantAWithdrawableUSDCAmount);
    const customAmountB = BigInt(req.body.participantBWithdrawableUSDCAmount);
    const resolveMessage = `${principal}-${txId}-Resolving-${customAmountA}-${customAmountB}-${ts}`;
    const resolveSignature = signMessage(
      resolveMessage,
      ARBITRATOR
    );
    
    await actor.resolveDispute(
      txId,
      req.body.comments,
      customAmountA,
      customAmountB,
      ts,
      resolveSignature,
    );
    res.json({ success: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: String(err) });
  }
});

/**
 * sign the escrow transaction payload and produce a signature for settlement
 */
app.post("/signWithSchnorr", async (req: Request, res: Response) => {
  try {
    const actor = await AGENT;
    const signature = await actor.signWithSchnorr(req.body.transactionId);
    res.json({ signature });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: String(err) });
  }
});

/**
 * the signature's public key
 */
app.get("/schnorrPublicKey", async (_req: Request, res: Response) => {
  try {
    const actor = await AGENT;
    const key = await actor.getSchnorrPublicKey();
    res.json({ key });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: String(err) });
  }
});

/**
 * the signature's payload
 */
app.get("/signWithSchnorrContent/:id", async (req: Request, res: Response) => {
  try {
    const actor = await AGENT;
    const content = await actor.getSignWithSchnorrContent(req.params.id);
    res.json({ content });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: String(err) });
  }
});

app.get("/canisterPrincipal", async (_req: Request, res: Response) => {
  try {
    const actor = await AGENT;
    const principal = await actor.getThisCanisterPrincipalText();
    res.json({ principal });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: String(err) });
  }
});

/**
 * get escrow transaction details
 */
app.get("/transaction/:id", async (req: Request, res: Response) => {
  try {
    const actor = await AGENT;
    const details = await actor.getTransactionDetails(req.params.id);
    const resolvedDetails = JSON.parse(JSON.stringify(details, (key, value) =>
      typeof value === 'bigint' ? value.toString() : value
    ))[0];
    res.json({
      ...
      resolvedDetails,
      // fix nested enum from ICP
      status: Object.keys(resolvedDetails.status)[0],
      escrowMode: Object.keys(resolvedDetails.escrowMode)[0]
    });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: String(err) });
  }
});

/**
 * get proof (if any) from escrow transaction
 */
app.get("/proof/:id", async (req: Request, res: Response) => {
  try {
    const actor = await AGENT;
    const details = await actor.getProofDetails(req.params.id) as string;
    if (details.length > 0) {
      res.json(JSON.parse(details));
    } else {
      res.status(404).json({ error: "not found" });
    }
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: String(err) });
  }
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
});
