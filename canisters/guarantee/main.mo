import Error "mo:base/Error";
import Int "mo:base/Int";
import Principal "mo:base/Principal";
import Text "mo:base/Text";
import Time "mo:base/Time";

import Base58 "../lib/base58";
import Blob "mo:base/Blob";
import NACL "mo:tweetnacl";
import Nat "mo:base/Nat";

import HashMap "mo:base/HashMap";
import IC "ic:aaaaa-aa";
import Iter "mo:base/Iter";
import Nat32 "mo:base/Nat32";

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

  public shared func initialize(
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
    participantATimestamp : Nat,
    participantBTimestamp : Nat,
    participantASignature : Text,
    participantBSignature : Text,
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

            if (
              not verifyTradeSignature(
                transactionId,
                participantATimestamp,
                participantBTimestamp,
                participantASignature,
                participantBSignature,
              )
            ) {
              throw Error.reject("Invalid signature");
            };

            let updatedTxInfo = {
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
    participantSignature : Text,
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

            if (not verifyDisputeSignature(transactionId, participantSolanaAddress, participantDisputeTimestamp, participantSignature)) {
              throw Error.reject("Invalid signature");
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
        if (not (txInfo.status == #Disputing)) {
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

        let host : Text = "api.example.com";
        let url = "https://" # host # "/proof/" # transactionId;
        let request_headers = [
          { name = "User-Agent"; value = "guarantee-canister" },
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

        let http_response : IC.http_request_result = await (with cycles = 234_000_000_000) IC.http_request(http_request);
        let proof : Text = switch (Text.decodeUtf8(http_response.body)) {
          case (null) { throw Error.reject("No proof data returned") };
          case (?data) { data };
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

  private func verifyTradeSignature(
    transactionId : Text,
    participantATimestamp : Nat,
    participantBTimestamp : Nat,
    participantASignature : Text,
    participantBSignature : Text,
  ) : Bool {
    switch (transactions.get(transactionId)) {
      case (null) { return false };
      case (?txInfo) {
        let thisCanisterPrincipalText = privateGetThisCanisterPrincipalText();
        let messageA = thisCanisterPrincipalText # "-" # transactionId # "-" # "Trading" # "-" # Nat.toText(participantATimestamp);
        let messageB = thisCanisterPrincipalText # "-" # transactionId # "-" # "Trading" # "-" # Nat.toText(participantBTimestamp);
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

  private func verifyDisputeSignature(
    transactionId : Text,
    participantSolanaAddress : Text,
    participantTimestamp : Nat,
    participantSignature : Text,
  ) : Bool {
    switch (transactions.get(transactionId)) {
      case (null) { return false };
      case (?txInfo) {
        let thisCanisterPrincipalText = privateGetThisCanisterPrincipalText();
        let message = thisCanisterPrincipalText # "-" # transactionId # "-" # "Disputing" # "-" # Nat.toText(participantTimestamp);
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

  public shared func fetchProof(transactionId : Text) : async Text {
    switch (transactions.get(transactionId)) {
      case (null) {
        throw Error.reject("Transaction not found");
      };
      case (?txInfo) {
        let host : Text = "api.example.com";
        let url = "https://" # host # "/proof/" # transactionId;
        let request_headers = [
          { name = "User-Agent"; value = "guarantee-canister" },
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

        let http_response : IC.http_request_result = await (with cycles = 234_000_000_000) IC.http_request(http_request);
        let proof : Text = switch (Text.decodeUtf8(http_response.body)) {
          case (null) { throw Error.reject("No proof data returned") };
          case (?data) { data };
        };
        proofs.put(transactionId, proof);
        return proof;
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

  private func generateTransactionId(participantASolanaAddress : Text, participantBSolanaAddress : Text, now : Nat) : Text {
    let canisterId = privateGetThisCanisterPrincipalText();
    let combinedInput = canisterId # "-" # participantASolanaAddress # "-" # participantBSolanaAddress # "-" # Nat.toText(now);
    let transactionId = Nat32.toText(Text.hash(combinedInput));
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

  public query func getProofDetails(transactionId : Text) : async ?Text {
    proofs.get(transactionId);
  };

  public query func getAllTransactionIds() : async [Text] {
    Iter.toArray(transactions.keys());
  };
};
