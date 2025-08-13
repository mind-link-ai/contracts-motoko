# TradeOS Decentralized Policy Engine

## Overview

![Policy Engine Architecture](https://cdn.tradeos.xyz/frontend/policy-engine-arch.png)

At the heart of TradeOS is a collection of smart contracts designed to be 
modular and configurable, allowing different trading scenarios and 
requirements to plug in without rewriting the entire system. By
leveraging a fully decentralized architecture, no single entity can
unilaterally control or censor trades. The engine coordinates with
multichain vaults to escrow assets securely and accepts multiple trust
mechanisms -- such as zkTLS or TEE‑TLS -- to verify delivery proofs or 
dispute evidence. A domain‑specific language, **TPL (TradeOS Policy Language)**,
allows traders to script custom policies while still benefiting from
community‑maintained templates for common P2P flows. By unifying multiple
blockchains and user bases, TradeOS aims to share liquidity globally and
enable cross‑chain commerce at scale.

## Escrow Payment Canister & APIs

This repository contains an Express server (`server.ts`) that interfaces
with the escrow payment canister. The server exposes a REST API for managing
escrow transactions and related actions:

- `POST /initialize` – start an escrow transaction
- `POST /confirmStaking` – record staking completion for each participant
- `POST /confirmTrading` – confirm delivery of trade goods or services
- `POST /confirmSettling` – finalize payouts once conditions are met
- `POST /initiateDispute` – begin a dispute with cryptographic evidence
- `POST /resolveDispute` – resolve a dispute and specify custom
  settlements
- `POST /signWithSchnorr` – obtain a Schnorr signature for settlement
- `GET /schnorrPublicKey` – fetch the signing public key
- `GET /signWithSchnorrContent/:id` – view the payload used for signing
- `GET /transaction/:id` – inspect transaction details
- `GET /proof/:id` – retrieve any attached proof for a transaction
- `GET /canisterPrincipal` – return the canister principal text

The accompanying test suite (`tests/guarantee.test.ts`) demonstrates
basic trade lifecycles, signature verification, dispute handling, and
utility helpers for querying transaction history.

## Setup

Follow these steps to run the project locally:

1. `sh -ci "$(curl -fsSL https://internetcomputer.org/install.sh)"` to install command-line execution environment
2. `npm i -g pnpm ic-mops` to install package manager for the Motoko programming language
3. `pnpm i` to install Node dependencies
4. `mops i` to install Motoko dependencies
5. `modify file dfx.json - canisters.guarantee.controllers` to setup custom controller (if any)
6. `dfx start --background` to setup local instance
7. `pnpm deploy:local` to deploy canister onto local instance
8. `pnpm test:guarantee` to run tests
9. `cp .env.example .env` # then edit env values
10. `pnpm start` to start backend APIs server
11. Use the `/setGlobalConfig` endpoint to set `proofUrl`, `proofCycles`,
    `schnorrKeyID`, and `schnorrCycles` after deploying to mainnet.

