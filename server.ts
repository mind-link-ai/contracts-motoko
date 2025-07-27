import fs from 'fs';
import express, { Request, Response } from 'express';
import { Actor, HttpAgent } from '@dfinity/agent';
import { Ed25519KeyIdentity } from '@dfinity/identity';
import { idlFactory } from './.dfx/local/canisters/guarantee/service.did.js';
import dotenv from 'dotenv';

dotenv.config();

const CANISTER_ID = process.env.CANISTER_ID_GUARANTEE as string;
const ICP_HOST = process.env.ICP_HOST || 'http://127.0.0.1:4943';
const IDENTITY_JSON_PATH = process.env.IDENTITY_JSON_PATH;

if (!CANISTER_ID) {
  throw new Error('CANISTER_ID_GUARANTEE env variable missing');
}
if (!IDENTITY_JSON_PATH) {
  throw new Error('IDENTITY_JSON_PATH env variable missing');
}

function createActor() {
  const json = fs.readFileSync(IDENTITY_JSON_PATH!, 'utf8');
  const identity = Ed25519KeyIdentity.fromParsedJson(JSON.parse(json));
  const agent = new HttpAgent({ host: ICP_HOST, identity, verifyQuerySignatures: false });
  return Actor.createActor(idlFactory, { agent, canisterId: CANISTER_ID });
}


const app = express();
app.use(express.json());

app.post('/initialize', async (req: Request, res: Response) => {
  try {
    const actor = createActor();
    const mode = req.body.escrowMode === 'Mutual' ? { Mutual: null } : { Settlement: null };
    const txId = await actor.initialize(
      mode,
      req.body.comments,
      req.body.participantASolanaAddress,
      req.body.participantBSolanaAddress,
      BigInt(req.body.participantAShouldStakeUSDCAmount),
      BigInt(req.body.participantBShouldStakeUSDCAmount),
      req.body.verifierSolanaAddress,
      req.body.arbitratorSolanaAddress,
      BigInt(req.body.stakeDuration),
      BigInt(req.body.tradeDuration)
    );
    res.json({ txId });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: String(err) });
  }
});

app.post('/confirmStaking', async (req: Request, res: Response) => {
  try {
    const actor = createActor();
    await actor.confirmStakingComplete(
      req.body.transactionId,
      req.body.stakeVaultSolanaAddress,
      req.body.participantSolanaAddress,
      BigInt(req.body.participantStakeTimestamp),
      req.body.verifierSignature
    );
    res.json({ success: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: String(err) });
  }
});

app.post('/confirmTrading', async (req: Request, res: Response) => {
  try {
    const actor = createActor();
    await actor.confirmTradingComplete(
      req.body.transactionId,
      req.body.participantASignature ? [req.body.participantASignature] : [],
      req.body.participantBSignature ? [req.body.participantBSignature] : [],
      req.body.verifierSignature ? [req.body.verifierSignature] : []
    );
    res.json({ success: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: String(err) });
  }
});

app.post('/confirmSettling', async (req: Request, res: Response) => {
  try {
    const actor = createActor();
    await actor.confirmSettlingComplete(
      req.body.transactionId,
      req.body.stakeVaultSolanaAddress,
      req.body.participantSolanaAddress,
      BigInt(req.body.participantSettleTimestamp),
      req.body.verifierSignature
    );
    res.json({ success: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: String(err) });
  }
});

app.post('/initiateDispute', async (req: Request, res: Response) => {
  try {
    const actor = createActor();
    await actor.initiateDispute(
      req.body.transactionId,
      req.body.participantSolanaAddress,
      BigInt(req.body.participantDisputeTimestamp),
      req.body.participantSignature ? [req.body.participantSignature] : [],
      req.body.verifierSignature ? [req.body.verifierSignature] : []
    );
    res.json({ success: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: String(err) });
  }
});

app.post('/resolveDispute', async (req: Request, res: Response) => {
  try {
    const actor = createActor();
    await actor.resolveDispute(
      req.body.transactionId,
      req.body.comments,
      BigInt(req.body.participantAWithdrawableUSDCAmount),
      BigInt(req.body.participantBWithdrawableUSDCAmount),
      BigInt(req.body.arbitratorResolveTimestamp),
      req.body.arbitratorSignature
    );
    res.json({ success: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: String(err) });
  }
});

app.post('/signWithSchnorr', async (req: Request, res: Response) => {
  try {
    const actor = createActor();
    const signature = await actor.signWithSchnorr(req.body.transactionId);
    res.json({ signature });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: String(err) });
  }
});

app.post('/setGlobalConfig', async (req: Request, res: Response) => {
  try {
    const actor = createActor();
    await actor.setGlobalConfig(
      req.body.newProofUrl,
      BigInt(req.body.newProofCycles),
      req.body.newSchnorrKeyID,
      BigInt(req.body.newSchnorrCycles)
    );
    res.json({ success: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: String(err) });
  }
});

app.get('/schnorrPublicKey', async (_req: Request, res: Response) => {
  try {
    const actor = createActor();
    const key = await actor.getSchnorrPublicKey();
    res.json({ key });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: String(err) });
  }
});

app.get('/signWithSchnorrContent/:id', async (req: Request, res: Response) => {
  try {
    const actor = createActor();
    const content = await actor.getSignWithSchnorrContent(req.params.id);
    res.json({ content });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: String(err) });
  }
});

app.get('/canisterPrincipal', async (_req: Request, res: Response) => {
  try {
    const actor = createActor();
    const principal = await actor.getThisCanisterPrincipalText();
    res.json({ principal });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: String(err) });
  }
});

app.get('/transaction/:id', async (req: Request, res: Response) => {
  try {
    const actor = createActor();
    const details = await actor.getTransactionDetails(req.params.id);
    res.json({ details });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: String(err) });
  }
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
});
