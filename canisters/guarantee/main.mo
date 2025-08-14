import IC "ic:aaaaa-aa";

import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Error "mo:base/Error";
import HashMap "mo:base/HashMap";
import Int "mo:base/Int";
import Iter "mo:base/Iter";
import Nat "mo:base/Nat";
import Principal "mo:base/Principal";
import Text "mo:base/Text";
import Time "mo:base/Time";

import Sha256 "mo:sha2/Sha256";
import NACL "mo:tweetnacl";

import Base58 "../lib/Base58";
import Hex "../lib/Hex";

actor Guarantee {
  type Status = {
    #New;
    #Staking;
    #Staked;
    #Traded;
    #Timeout;
    #Disputing;
    #Resolved;
    #Settling;
    #Settled;
  };

  type EscrowMode = {
    #Mutual;
    #Settlement;
  };

  type ParticipantInfo = {
    participantSolanaAddress : Text;
    shouldStakeUSDCAmount : Nat;
    withdrawableUSDCAmount : Nat;
    stakeVaultSolanaAddress : ?Text;
    stakeTimestamp : ?Nat;
    disputeTimestamp : ?Nat;
    settleTimestamp : ?Nat;
  };

  type TransactionInfo = {
    id : Text;
    status : Status;
    escrowMode : EscrowMode;
    comments : Text;
    participantA : ParticipantInfo;
    participantB : ParticipantInfo;
    verifierSolanaAddress : Text;
    arbitratorSolanaAddress : Text;
    stakeDuration : Nat;
    tradeDuration : Nat;
    newTimestamp : Nat;
    stakedTimestamp : ?Nat;
    tradedTimestamp : ?Nat;
    timeoutTimestamp : ?Nat;
    resolvedTimestamp : ?Nat;
    settledTimestamp : ?Nat;
  };

  private stable var transactionsEntries : [(Text, TransactionInfo)] = [];
  private var transactions = HashMap.HashMap<Text, TransactionInfo>(0, Text.equal, Text.hash);

  private stable var proofEntries : [(Text, Text)] = [];
  private var proofs = HashMap.HashMap<Text, Text>(0, Text.equal, Text.hash);

  private stable var proofUrl : Text = "https://p2p.tradeos.xyz/api/proof";
  private stable var proofCycles : Nat = 30_000_000_000;

  private stable var schnorrKeyID : Text = "key_1";
  private stable var schnorrCycles : Nat = 30_000_000_000;

  system func preupgrade() {
    transactionsEntries := Iter.toArray(transactions.entries());
    proofEntries := Iter.toArray(proofs.entries());
  };

  system func postupgrade() {
    transactions := HashMap.fromIter<Text, TransactionInfo>(transactionsEntries.vals(), transactionsEntries.size(), Text.equal, Text.hash);
    proofs := HashMap.fromIter<Text, Text>(proofEntries.vals(), proofEntries.size(), Text.equal, Text.hash);

    transactionsEntries := [];
    proofEntries := [];
  };

  public shared ({ caller }) func setGlobalConfig(newProofUrl : Text, newProofCycles : Nat, newSchnorrKeyID : Text, newSchnorrCycles : Nat) : async () {
    assert Principal.isController(caller);

    proofUrl := newProofUrl;
    proofCycles := newProofCycles;

    schnorrKeyID := newSchnorrKeyID;
    schnorrCycles := newSchnorrCycles;
  };

  public shared func initialize(
    escrowMode : EscrowMode,
    comments : Text,
    participantASolanaAddress : Text,
    participantBSolanaAddress : Text,
    participantAShouldStakeUSDCAmount : Nat,
    participantBShouldStakeUSDCAmount : Nat,
    verifierSolanaAddress : Text,
    arbitratorSolanaAddress : Text,
    stakeDuration : Nat,
    tradeDuration : Nat,
  ) : async Text {
    if (participantAShouldStakeUSDCAmount == 0 and participantBShouldStakeUSDCAmount == 0) {
      throw Error.reject("At least one participant should stake amount greater than 0");
    };

    let participantA : ParticipantInfo = {
      participantSolanaAddress = participantASolanaAddress;
      shouldStakeUSDCAmount = participantAShouldStakeUSDCAmount;
      withdrawableUSDCAmount = 0;
      stakeVaultSolanaAddress = null;
      stakeTimestamp = null;
      disputeTimestamp = null;
      settleTimestamp = null;
    };

    let participantB : ParticipantInfo = {
      participantSolanaAddress = participantBSolanaAddress;
      shouldStakeUSDCAmount = participantBShouldStakeUSDCAmount;
      withdrawableUSDCAmount = 0;
      stakeVaultSolanaAddress = null;
      stakeTimestamp = null;
      settleTimestamp = null;
      disputeTimestamp = null;
    };

    let now = (Int.abs(Time.now()) / 1_000_000_000);
    let transactionId = generateTransactionId(participantASolanaAddress, participantBSolanaAddress, now);

    let transaction : TransactionInfo = {
      id = transactionId;
      status = #New;
      escrowMode = escrowMode;
      comments = comments;
      participantA = participantA;
      participantB = participantB;
      verifierSolanaAddress = verifierSolanaAddress;
      arbitratorSolanaAddress = arbitratorSolanaAddress;
      stakeDuration = stakeDuration;
      tradeDuration = tradeDuration;
      newTimestamp = now;
      stakedTimestamp = null;
      tradedTimestamp = null;
      timeoutTimestamp = null;
      resolvedTimestamp = null;
      settledTimestamp = null;
    };

    transactions.put(transactionId, transaction);
    return transactionId;
  };

  public shared func confirmStakingComplete(
    transactionId : Text,
    stakeVaultSolanaAddress : Text,
    participantSolanaAddress : Text,
    participantStakeTimestamp : Nat,
    verifierSignature : Text,
  ) : async () {
    switch (transactions.get(transactionId)) {
      case (null) {
        throw Error.reject("Transaction not found");
      };
      case (?txInfo) {
        let now : Nat = (Int.abs(Time.now()) / 1_000_000_000);
        if (now > (txInfo.newTimestamp + txInfo.stakeDuration)) {
          let updatedTxInfo = {
            txInfo with
            status = #Timeout;
            timeoutTimestamp = ?now;
          };
          transactions.put(transactionId, updatedTxInfo);
          return;
        };

        if (not (txInfo.status == #New or txInfo.status == #Staking)) {
          throw Error.reject("Transaction is not in New/Staking status");
        };

        if (not verifyStakeSignature(transactionId, stakeVaultSolanaAddress, participantSolanaAddress, participantStakeTimestamp, verifierSignature)) {
          throw Error.reject("Invalid signature");
        };

        var updatedTxInfo = txInfo;
        if (Text.equal(participantSolanaAddress, txInfo.participantA.participantSolanaAddress)) {
          updatedTxInfo := {
            txInfo with
            participantA = {
              txInfo.participantA with
              withdrawableUSDCAmount = txInfo.participantA.shouldStakeUSDCAmount;
              stakeVaultSolanaAddress = ?stakeVaultSolanaAddress;
              stakeTimestamp = ?participantStakeTimestamp;
            }
          };
        } else if (Text.equal(participantSolanaAddress, txInfo.participantB.participantSolanaAddress)) {
          updatedTxInfo := {
            txInfo with
            participantB = {
              txInfo.participantB with
              withdrawableUSDCAmount = txInfo.participantB.shouldStakeUSDCAmount;
              stakeVaultSolanaAddress = ?stakeVaultSolanaAddress;
              stakeTimestamp = ?participantStakeTimestamp;
            }
          };
        } else {
          throw Error.reject("Invalid participant address");
        };

        let isParticipantAZeroStake = txInfo.participantA.shouldStakeUSDCAmount == 0;
        let isParticipantBZeroStake = txInfo.participantB.shouldStakeUSDCAmount == 0;
        let isAStaked = switch (updatedTxInfo.participantA.stakeTimestamp) {
          case (null) { isParticipantAZeroStake };
          case (_) { true };
        };
        let isBStaked = switch (updatedTxInfo.participantB.stakeTimestamp) {
          case (null) { isParticipantBZeroStake };
          case (_) { true };
        };

        let newStatus = if (isAStaked and isBStaked) {
          #Staked;
        } else if (isAStaked or isBStaked) {
          #Staking;
        } else {
          throw Error.reject("Invalid value");
        };

        let newStakedTimestamp = if (newStatus == #Staked) {
          ?now;
        } else {
          null;
        };

        let finalTxInfo = {
          updatedTxInfo with
          status = newStatus;
          stakedTimestamp = newStakedTimestamp;
        };
        transactions.put(transactionId, finalTxInfo);
      };
    };
  };

  public shared func confirmTradingComplete(
    transactionId : Text,
    participantASignature : ?Text,
    participantBSignature : ?Text,
    verifierSignature : ?Text,
  ) : async () {
    switch (transactions.get(transactionId)) {
      case (null) {
        throw Error.reject("Transaction not found");
      };
      case (?txInfo) {
        switch (txInfo.stakedTimestamp) {
          case (null) {
            throw Error.reject("Invalid value");
          };
          case (?stakedTimestamp) {
            let now : Nat = (Int.abs(Time.now()) / 1_000_000_000);
            if (now > (stakedTimestamp + txInfo.tradeDuration)) {
              let updatedTxInfo = {
                txInfo with
                status = #Timeout;
                tradedTimestamp = ?now;
                timeoutTimestamp = ?now;
              };
              transactions.put(transactionId, updatedTxInfo);
              return;
            };

            if (not (txInfo.status == #Staked)) {
              throw Error.reject("Transaction is not in Staked status");
            };

            switch (verifierSignature) {
              case (?signature) {
                if (not verifyTradeVerifierSignature(transactionId, signature)) {
                  throw Error.reject("Invalid verifier signature");
                };
              };
              case (null) {
                switch (participantASignature, participantBSignature) {
                  case (?signatureA, ?signatureB) {
                    if (
                      not verifyTradeParticipantSignature(
                        transactionId,
                        signatureA,
                        signatureB,
                      )
                    ) {
                      throw Error.reject("Invalid participant signatures");
                    };
                  };
                  case (_) {
                    throw Error.reject("Missing required signatures");
                  };
                };
              };
            };

            let updatedTxInfo = switch (txInfo.escrowMode) {
              case (#Mutual) {
                {
                  txInfo with
                  status = #Traded;
                  tradedTimestamp = ?now;
                };
              };
              case (#Settlement) {
                {
                  txInfo with
                  status = #Traded;
                  tradedTimestamp = ?now;
                  participantA = {
                    txInfo.participantA with
                    withdrawableUSDCAmount = 0;
                  };
                  participantB = {
                    txInfo.participantB with
                    withdrawableUSDCAmount = txInfo.participantB.withdrawableUSDCAmount + txInfo.participantA.withdrawableUSDCAmount;
                  };
                };
              };
            };
            transactions.put(transactionId, updatedTxInfo);
          };
        };
      };
    };
  };

  public shared func confirmSettlingComplete(
    transactionId : Text,
    stakeVaultSolanaAddress : Text,
    participantSolanaAddress : Text,
    participantSettleTimestamp : Nat,
    verifierSignature : Text,
  ) : async () {
    switch (transactions.get(transactionId)) {
      case (null) {
        throw Error.reject("Transaction not found");
      };
      case (?txInfo) {
        if (not (txInfo.status == #Traded or txInfo.status == #Timeout or txInfo.status == #Resolved or txInfo.status == #Settling)) {
          throw Error.reject("Transaction is not in Traded/Timeout/Resolved/Settling status");
        };

        if (not verifySettleSignature(transactionId, stakeVaultSolanaAddress, participantSolanaAddress, participantSettleTimestamp, verifierSignature)) {
          throw Error.reject("Invalid signature");
        };

        let now : Nat = (Int.abs(Time.now()) / 1_000_000_000);
        var updatedTxInfo = txInfo;
        if (Text.equal(participantSolanaAddress, txInfo.participantA.participantSolanaAddress)) {
          updatedTxInfo := {
            txInfo with
            participantA = {
              txInfo.participantA with
              settleTimestamp = ?participantSettleTimestamp;
            };
          };
        } else if (Text.equal(participantSolanaAddress, txInfo.participantB.participantSolanaAddress)) {
          updatedTxInfo := {
            txInfo with
            participantB = {
              txInfo.participantB with
              settleTimestamp = ?participantSettleTimestamp;
            };
          };
        } else {
          throw Error.reject("Invalid participant address");
        };

        let isParticipantAZeroStake = txInfo.participantA.shouldStakeUSDCAmount == 0;
        let isParticipantBZeroStake = txInfo.participantB.shouldStakeUSDCAmount == 0;
        let isParticipantAZeroWithdrawable = txInfo.participantA.withdrawableUSDCAmount == 0;
        let isParticipantBZeroWithdrawable = txInfo.participantB.withdrawableUSDCAmount == 0;
        let isASettled = switch (updatedTxInfo.participantA.settleTimestamp) {
          case (null) {
            isParticipantAZeroStake or isParticipantAZeroWithdrawable;
          };
          case (_) { true };
        };
        let isBSettled = switch (updatedTxInfo.participantB.settleTimestamp) {
          case (null) {
            isParticipantBZeroStake or isParticipantBZeroWithdrawable;
          };
          case (_) { true };
        };

        let newStatus = if (isASettled and isBSettled) {
          #Settled;
        } else if (isASettled or isBSettled) {
          #Settling;
        } else {
          throw Error.reject("Invalid value");
        };

        let newSettledTimestamp = if (newStatus == #Settled) {
          ?now;
        } else {
          null;
        };

        let finalTxInfo = {
          updatedTxInfo with
          status = newStatus;
          settledTimestamp = newSettledTimestamp;
        };
        transactions.put(transactionId, finalTxInfo);
      };
    };
  };

  public shared func initiateDispute(
    transactionId : Text,
    participantSolanaAddress : Text,
    participantDisputeTimestamp : Nat,
    participantSignature : ?Text,
    verifierSignature : ?Text,
  ) : async () {
    switch (transactions.get(transactionId)) {
      case (null) {
        throw Error.reject("Transaction not found");
      };
      case (?txInfo) {
        switch (txInfo.stakedTimestamp) {
          case (null) {
            throw Error.reject("Invalid value");
          };
          case (?stakedTimestamp) {
            let now : Nat = (Int.abs(Time.now()) / 1_000_000_000);
            if (now > (stakedTimestamp + txInfo.tradeDuration)) {
              let updatedTxInfo = {
                txInfo with
                status = #Timeout;
                tradedTimestamp = ?now;
                timeoutTimestamp = ?now;
              };
              transactions.put(transactionId, updatedTxInfo);
              return;
            };

            if (not (txInfo.status == #Staked)) {
              throw Error.reject("Transaction is not in Staked status");
            };

            switch (verifierSignature) {
              case (?signature) {
                if (not verifyDisputeVerifierSignature(transactionId, participantSolanaAddress, participantDisputeTimestamp, signature)) {
                  throw Error.reject("Invalid verifier signature");
                };
              };
              case (null) {
                switch (participantSignature) {
                  case (?signature) {
                    if (not verifyDisputeParticipantSignature(transactionId, participantSolanaAddress, participantDisputeTimestamp, signature)) {
                      throw Error.reject("Invalid participant signature");
                    };
                  };
                  case (_) {
                    throw Error.reject("Missing required signature");
                  };
                };
              };
            };

            var updatedTxInfo = txInfo;
            if (Text.equal(participantSolanaAddress, txInfo.participantA.participantSolanaAddress)) {
              updatedTxInfo := {
                txInfo with
                participantA = {
                  txInfo.participantA with
                  disputeTimestamp = ?participantDisputeTimestamp;
                };
              };
            } else if (Text.equal(participantSolanaAddress, txInfo.participantB.participantSolanaAddress)) {
              updatedTxInfo := {
                txInfo with
                participantB = {
                  txInfo.participantB with
                  disputeTimestamp = ?participantDisputeTimestamp;
                };
              };
            } else {
              throw Error.reject("Invalid participant address");
            };

            let finalTxInfo = {
              updatedTxInfo with
              status = #Disputing;
            };
            transactions.put(transactionId, finalTxInfo);
          };
        };
      };
    };
  };

  public shared func resolveDispute(
    transactionId : Text,
    comments : Text,
    participantAWithdrawableUSDCAmount : Nat,
    participantBWithdrawableUSDCAmount : Nat,
    arbitratorResolveTimestamp : Nat,
    arbitratorSignature : Text,
  ) : async () {
    switch (transactions.get(transactionId)) {
      case (null) {
        throw Error.reject("Transaction not found");
      };
      case (?txInfo) {
        if (not (txInfo.status == #Disputing or txInfo.status == #Resolved)) {
          throw Error.reject("Transaction is not in Disputing status");
        };

        if (
          (participantAWithdrawableUSDCAmount + participantBWithdrawableUSDCAmount) > (txInfo.participantA.shouldStakeUSDCAmount + txInfo.participantB.shouldStakeUSDCAmount)
        ) {
          throw Error.reject("Total withdrawable amount exceeds total staked amount");
        };

        if (not verifyResolveSignature(transactionId, participantAWithdrawableUSDCAmount, participantBWithdrawableUSDCAmount, arbitratorResolveTimestamp, arbitratorSignature)) {
          throw Error.reject("Invalid signature");
        };

        let url = proofUrl # "/" # transactionId;
        // let url = proofUrl # "/" # "mock-proof-data.json";
        let request_headers = [
          { name = "User-Agent"; value = "ICP-Canister-Guarantee" },
        ];

        let http_request : IC.http_request_args = {
          url = url;
          max_response_bytes = null;
          headers = request_headers;
          body = null;
          method = #get;
          transform = ?{
            function = transform;
            context = Blob.fromArray([]);
          };
        };

        let http_response : IC.http_request_result = await (with cycles = proofCycles) IC.http_request(http_request);

        if (http_response.status != 200) {
          throw Error.reject("HTTP request failed with status: " # Nat.toText(http_response.status));
        };

        let proof : Text = switch (Text.decodeUtf8(http_response.body)) {
          case (null) { throw Error.reject("No proof data returned") };
          case (?data) {
            data;
          };
        };
        proofs.put(transactionId, proof);

        let now : Nat = (Int.abs(Time.now()) / 1_000_000_000);
        let updatedTxInfo = {
          txInfo with
          status = #Resolved;
          comments = comments;
          participantA = {
            txInfo.participantA with
            withdrawableUSDCAmount = participantAWithdrawableUSDCAmount;
          };
          participantB = {
            txInfo.participantB with
            withdrawableUSDCAmount = participantBWithdrawableUSDCAmount;
          };
          resolvedTimestamp = ?now;
        };
        transactions.put(transactionId, updatedTxInfo);
      };
    };
  };

  private func verifyStakeSignature(
    transactionId : Text,
    stakeVaultSolanaAddress : Text,
    participantSolanaAddress : Text,
    participantStakeTimestamp : Nat,
    verifierSignature : Text,
  ) : Bool {
    switch (transactions.get(transactionId)) {
      case (null) { return false };
      case (?txInfo) {
        let thisCanisterPrincipalText = privateGetThisCanisterPrincipalText();
        let message = thisCanisterPrincipalText # "-" # transactionId # "-" # "Staking" # "-" # stakeVaultSolanaAddress # "-" # participantSolanaAddress # "-" # Nat.toText(participantStakeTimestamp);
        let messageBytes = Blob.toArray(Text.encodeUtf8(message));
        let signatureBytes = Base58.decode(verifierSignature);
        let publicKeyBytes = Base58.decode(txInfo.verifierSolanaAddress);
        return NACL.SIGN.DETACHED.verify(messageBytes, signatureBytes, publicKeyBytes);
      };
    };
  };

  private func verifyTradeVerifierSignature(
    transactionId : Text,
    verifierSignature : Text,
  ) : Bool {
    switch (transactions.get(transactionId)) {
      case (null) { return false };
      case (?txInfo) {
        let thisCanisterPrincipalText = privateGetThisCanisterPrincipalText();
        let message = thisCanisterPrincipalText # "-" # transactionId # "-" # "Trading";
        let messageBytes = Blob.toArray(Text.encodeUtf8(message));
        let signatureBytes = Base58.decode(verifierSignature);
        let publicKeyBytes = Base58.decode(txInfo.verifierSolanaAddress);
        return NACL.SIGN.DETACHED.verify(messageBytes, signatureBytes, publicKeyBytes);
      };
    };
  };

  private func verifyTradeParticipantSignature(
    transactionId : Text,
    participantASignature : Text,
    participantBSignature : Text,
  ) : Bool {
    switch (transactions.get(transactionId)) {
      case (null) { return false };
      case (?txInfo) {
        let thisCanisterPrincipalText = privateGetThisCanisterPrincipalText();
        let messageA = thisCanisterPrincipalText # "-" # transactionId # "-" # "Trading";
        let messageB = thisCanisterPrincipalText # "-" # transactionId # "-" # "Trading";
        let messageABytes = Blob.toArray(Text.encodeUtf8(messageA));
        let messageBBytes = Blob.toArray(Text.encodeUtf8(messageB));
        let signatureABytes = Base58.decode(participantASignature);
        let signatureBBytes = Base58.decode(participantBSignature);
        let publicKeyABytes = Base58.decode(txInfo.participantA.participantSolanaAddress);
        let publicKeyBBytes = Base58.decode(txInfo.participantB.participantSolanaAddress);
        let isAValid = NACL.SIGN.DETACHED.verify(messageABytes, signatureABytes, publicKeyABytes);
        let isBValid = NACL.SIGN.DETACHED.verify(messageBBytes, signatureBBytes, publicKeyBBytes);
        return isAValid and isBValid;
      };
    };
  };

  private func verifySettleSignature(
    transactionId : Text,
    stakeVaultSolanaAddress : Text,
    participantSolanaAddress : Text,
    participantSettleTimestamp : Nat,
    verifierSignature : Text,
  ) : Bool {
    switch (transactions.get(transactionId)) {
      case (null) { return false };
      case (?txInfo) {
        let thisCanisterPrincipalText = privateGetThisCanisterPrincipalText();
        let message = thisCanisterPrincipalText # "-" # transactionId # "-" # "Settling" # "-" # stakeVaultSolanaAddress # "-" # participantSolanaAddress # "-" # Nat.toText(participantSettleTimestamp);
        let messageBytes = Blob.toArray(Text.encodeUtf8(message));
        let signatureBytes = Base58.decode(verifierSignature);
        let publicKeyBytes = Base58.decode(txInfo.verifierSolanaAddress);
        return NACL.SIGN.DETACHED.verify(messageBytes, signatureBytes, publicKeyBytes);
      };
    };
  };

  private func verifyDisputeVerifierSignature(
    transactionId : Text,
    participantSolanaAddress : Text,
    participantDisputeTimestamp : Nat,
    verifierSignature : Text,
  ) : Bool {
    switch (transactions.get(transactionId)) {
      case (null) { return false };
      case (?txInfo) {
        let thisCanisterPrincipalText = privateGetThisCanisterPrincipalText();
        let message = thisCanisterPrincipalText # "-" # transactionId # "-" # "Disputing" # "-" # participantSolanaAddress # "-" # Nat.toText(participantDisputeTimestamp);
        let messageBytes = Blob.toArray(Text.encodeUtf8(message));
        let signatureBytes = Base58.decode(verifierSignature);
        let publicKeyBytes = Base58.decode(txInfo.verifierSolanaAddress);
        return NACL.SIGN.DETACHED.verify(messageBytes, signatureBytes, publicKeyBytes);
      };
    };
  };

  private func verifyDisputeParticipantSignature(
    transactionId : Text,
    participantSolanaAddress : Text,
    participantTimestamp : Nat,
    participantSignature : Text,
  ) : Bool {
    switch (transactions.get(transactionId)) {
      case (null) { return false };
      case (?txInfo) {
        let thisCanisterPrincipalText = privateGetThisCanisterPrincipalText();
        let message = thisCanisterPrincipalText # "-" # transactionId # "-" # "Disputing" # "-" # participantSolanaAddress # "-" # Nat.toText(participantTimestamp);
        let messageBytes = Blob.toArray(Text.encodeUtf8(message));
        let signatureBytes = Base58.decode(participantSignature);
        if (Text.equal(participantSolanaAddress, txInfo.participantA.participantSolanaAddress)) {
          let publicKeyBytes = Base58.decode(txInfo.participantA.participantSolanaAddress);
          return NACL.SIGN.DETACHED.verify(messageBytes, signatureBytes, publicKeyBytes);
        } else if (Text.equal(participantSolanaAddress, txInfo.participantB.participantSolanaAddress)) {
          let publicKeyBytes = Base58.decode(txInfo.participantB.participantSolanaAddress);
          return NACL.SIGN.DETACHED.verify(messageBytes, signatureBytes, publicKeyBytes);
        } else {
          return false;
        };
      };
    };
  };

  private func verifyResolveSignature(
    transactionId : Text,
    participantAWithdrawableUSDCAmount : Nat,
    participantBWithdrawableUSDCAmount : Nat,
    arbitratorResolveTimestamp : Nat,
    arbitratorSignature : Text,
  ) : Bool {
    switch (transactions.get(transactionId)) {
      case (null) { return false };
      case (?txInfo) {
        let thisCanisterPrincipalText = privateGetThisCanisterPrincipalText();
        let message = thisCanisterPrincipalText # "-" # transactionId # "-" # "Resolving" # "-" # Nat.toText(participantAWithdrawableUSDCAmount) # "-" # Nat.toText(participantBWithdrawableUSDCAmount) # "-" # Nat.toText(arbitratorResolveTimestamp);
        let messageBytes = Blob.toArray(Text.encodeUtf8(message));
        let signatureBytes = Base58.decode(arbitratorSignature);
        let publicKeyBytes = Base58.decode(txInfo.arbitratorSolanaAddress);
        return NACL.SIGN.DETACHED.verify(messageBytes, signatureBytes, publicKeyBytes);
      };
    };
  };

  public query func transform({
    context : Blob;
    response : IC.http_request_result;
  }) : async IC.http_request_result {
    {
      response with headers = [];
    };
  };

  public shared func fetchProof(transactionId : Text) : async Text {
    switch (transactions.get(transactionId)) {
      case (null) {
        throw Error.reject("Transaction not found");
      };
      case (?txInfo) {
        let url = proofUrl # "/" # transactionId;
        // let url = proofUrl # "/" # "mock-proof-data.json";
        let request_headers = [
          { name = "User-Agent"; value = "ICP-Canister-Guarantee" },
        ];

        let http_request : IC.http_request_args = {
          url = url;
          max_response_bytes = null;
          headers = request_headers;
          body = null;
          method = #get;
          transform = ?{
            function = transform;
            context = Blob.fromArray([]);
          };
        };

        let http_response : IC.http_request_result = await (with cycles = proofCycles) IC.http_request(http_request);

        if (http_response.status != 200) {
          throw Error.reject("HTTP request failed with status: " # Nat.toText(http_response.status));
        };

        let proof : Text = switch (Text.decodeUtf8(http_response.body)) {
          case (null) { throw Error.reject("No proof data returned") };
          case (?data) {
            data;
          };
        };
        proofs.put(transactionId, proof);
        return proof;
      };
    };
  };

  public query func getProofDetails(transactionId : Text) : async ?Text {
    proofs.get(transactionId);
  };

  public shared func getSchnorrPublicKey() : async Text {
    let publicKeyArgs = {
      derivation_path = [Principal.toBlob(Principal.fromActor(Guarantee))];
      key_id = { algorithm = #ed25519; name = schnorrKeyID };
      canister_id = null;
    };

    let { public_key } = await (with cycles = schnorrCycles) IC.schnorr_public_key(publicKeyArgs);
    return Hex.encode(Blob.toArray(public_key));
  };

  public query func getSignWithSchnorrContent(transactionId : Text) : async Text {
    switch (transactions.get(transactionId)) {
      case (null) {
        throw Error.reject("Transaction not found");
      };
      case (?txInfo) {
        if (not (txInfo.status == #Traded or txInfo.status == #Timeout or txInfo.status == #Resolved or txInfo.status == #Settling)) {
          throw Error.reject("Transaction is not in Traded/Timeout/Resolved/Settling status");
        };

        let thisCanisterPrincipalText = privateGetThisCanisterPrincipalText();

        let statusText = switch (txInfo.status) {
          case (#Traded) "Traded";
          case (#Timeout) "Timeout";
          case (#Resolved) "Resolved";
          case (#Settling) "Settling";
          case (_) throw Error.reject("Transaction is not in Traded/Timeout/Resolved/Settling status");
        };

        let escrowModeText = switch (txInfo.escrowMode) {
          case (#Mutual) "Mutual";
          case (#Settlement) "Settlement";
        };

        let message = thisCanisterPrincipalText # "-" #
        transactionId # "-" #
        statusText # "-" #
        escrowModeText # "-" #
        txInfo.participantA.participantSolanaAddress # "-" #
        Nat.toText(txInfo.participantA.withdrawableUSDCAmount) # "-" #
        txInfo.participantB.participantSolanaAddress # "-" #
        Nat.toText(txInfo.participantB.withdrawableUSDCAmount) # "-" #
        "CanSettle";

        return message;
      };
    };
  };

  public shared func signWithSchnorr(transactionId : Text) : async Text {
    switch (transactions.get(transactionId)) {
      case (null) {
        throw Error.reject("Transaction not found");
      };
      case (?txInfo) {
        if (not (txInfo.status == #Traded or txInfo.status == #Timeout or txInfo.status == #Resolved or txInfo.status == #Settling)) {
          throw Error.reject("Transaction is not in Traded/Timeout/Resolved/Settling status");
        };

        let thisCanisterPrincipalText = privateGetThisCanisterPrincipalText();

        let statusText = switch (txInfo.status) {
          case (#Traded) "Traded";
          case (#Timeout) "Timeout";
          case (#Resolved) "Resolved";
          case (#Settling) "Settling";
          case (_) throw Error.reject("Transaction is not in Traded/Timeout/Resolved/Settling status");
        };

        let escrowModeText = switch (txInfo.escrowMode) {
          case (#Mutual) "Mutual";
          case (#Settlement) "Settlement";
        };

        let message = thisCanisterPrincipalText # "-" #
        transactionId # "-" #
        statusText # "-" #
        escrowModeText # "-" #
        txInfo.participantA.participantSolanaAddress # "-" #
        Nat.toText(txInfo.participantA.withdrawableUSDCAmount) # "-" #
        txInfo.participantB.participantSolanaAddress # "-" #
        Nat.toText(txInfo.participantB.withdrawableUSDCAmount) # "-" #
        "CanSettle";

        let signArgs = {
          message = Text.encodeUtf8(message);
          derivation_path = [Principal.toBlob(Principal.fromActor(Guarantee))];
          key_id = { algorithm = #ed25519; name = schnorrKeyID };
          aux = null;
        };

        let { signature } = await (with cycles = schnorrCycles) IC.sign_with_schnorr(signArgs);
        return Hex.encode(Blob.toArray(signature));
      };
    };
  };

  private func generateTransactionId(participantASolanaAddress : Text, participantBSolanaAddress : Text, now : Nat) : Text {
    let canisterId = privateGetThisCanisterPrincipalText();
    let combinedInput = canisterId # "-" # participantASolanaAddress # "-" # participantBSolanaAddress # "-" # Nat.toText(now);
    let digest = Sha256.fromBlob(#sha256, Text.encodeUtf8(combinedInput));
    let transactionId = Base58.encode(Blob.toArray(digest));
    return transactionId;
  };

  private func privateGetThisCanisterPrincipalText() : Text {
    Principal.toText(Principal.fromActor(Guarantee));
  };

  public query func getThisCanisterPrincipalText() : async Text {
    privateGetThisCanisterPrincipalText();
  };

  public query func getTransactionStatusText(transactionId : Text) : async ?Text {
    switch (transactions.get(transactionId)) {
      case (null) { null };
      case (?txInfo) {
        switch (txInfo.status) {
          case (#New) { ?"New" };
          case (#Staking) { ?"Staking" };
          case (#Staked) { ?"Staked" };
          case (#Traded) { ?"Traded" };
          case (#Timeout) { ?"Timeout" };
          case (#Disputing) { ?"Disputing" };
          case (#Resolved) { ?"Resolved" };
          case (#Settling) { ?"Settling" };
          case (#Settled) { ?"Settled" };
        };
      };
    };
  };

  public query func getTransactionDetails(transactionId : Text) : async ?TransactionInfo {
    transactions.get(transactionId);
  };

  public query func getRecentTransactionIds(limit : Nat) : async [Text] {
    let allIds = Iter.toArray(transactions.keys());
    let size = allIds.size();

    if (size <= limit) {
      return allIds;
    };

    let startIndex = size - limit;
    Array.tabulate<Text>(limit, func(i) { allIds[startIndex + i] });
  };

  public query func getAllTransactionIds() : async [Text] {
    Iter.toArray(transactions.keys());
  };
};
