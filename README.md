# TradeOS Decentralized Policy Engine

## Overview

![Policy Engine Architecture](https://cdn.tradeos.xyz/frontend/policy-engine-arch.png)

At the heart of TradeOS (https://www.tradeos.xyz) is a collection of smart contracts designed to be 
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

### Escrow Modes

`POST /initialize` accepts an optional `escrowMode` parameter:

- **Settlement** (default): Party A's stake amount is transferred to party B after settlement.
- **Mutual**: Each party's stake is returned to its original owner after settlement.

The accompanying test suite (`tests/guarantee.test.ts`) demonstrates
basic trade lifecycles, signature verification, dispute handling, and
utility helpers for querying transaction history.

## Proof-of-Delivery Specification

When a dispute is resolved the canister performs an HTTP GET request to
`{proofUrl}/{transactionId}`. The endpoint is expected to return a JSON
payload matching the following schema, which the canister stores as the
transaction's proof of delivery.

### Fields

| Field               | Description                                                 |
| ------------------- | ----------------------------------------------------------- |
| `version`           | Version of the proof data format                            |
| `generatedAt`       | Timestamp of when the proof data was generated (Unix epoch) |
| `transactionId`     | The ID of the current transaction                           |
| `resolutionId`      | The ID of the resolution                                    |
| `market`            | The market where the transaction took place                 |
| `buyerAddress`      | The blockchain address of the buyer                         |
| `sellerAddress`     | The blockchain address of the seller                        |
| `arbitratorAddress` | The blockchain address of the arbitrator                    |
| `assetType`         | The type of asset involved in the transaction               |
| `assetAmount`       | The amount of the asset (in smallest units)                 |
| `resolution`        | The final resolution of the dispute (`Refund buyer`, `Refund seller`, or `Refund both`) |
| `resolvedAt`        | Timestamp of when the dispute was resolved (Unix epoch)     |
| `reasonCode`        | Code indicating the reason for the resolution               |
| `proofs`            | An array of proof objects                                   |
| `payloadHash`       | Hash of the payload                                         |
| `signature`         | Digital signature of the proof data                         |
| `sigAlgo`           | Signature algorithm used                                    |

Possible `reasonCode` values include: `ITEM_NOT_RECEIVED`, `NOT_AS_DESCRIBED`,
`PARTIAL_DELIVERY`, `GOODS_DAMAGED`, `SERVICE_NOT_RENDERED`, `LATE_DELIVERY`,
`ALREADY_CANCELLED`.

### Proof Object

Each object in the `proofs` array can have the following fields:

| Field            | Description                                                              |
| ---------------- | ------------------------------------------------------------------------ |
| `type`           | Type of proof                                                            |
| `url` (optional) | URL where the proof can be accessed (e.g., for screenshots or chat logs) |
| `sha256`         | SHA256 hash of the proof content                                         |

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

