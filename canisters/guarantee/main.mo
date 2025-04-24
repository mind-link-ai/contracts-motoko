import Error "mo:base/Error";
import Int "mo:base/Int";
import Nat "mo:base/Nat";
import Principal "mo:base/Principal";
import Text "mo:base/Text";
import Time "mo:base/Time";

actor Guarantee {
  type Status = {
    #New;
    #Staking;
    #Staked;
    #Completed;
    #Timeout;
    #Disputed;
    #Resolved;
  };

  type ParticipantInfo = {
    participantSolanaAddress : Text;
    shouldStakeUSDCAmount : Nat;
    stakeVaultSolanaAddress : ?Text;
    stakeTimestamp : ?Nat;
    disputeTimestamp : ?Nat;
    withdrawablePercentage : ?Nat;
  };

  type TransactionInfo = {
    status : Status;
    creationTimestamp : Nat;
    stakingPhaseDuration : Nat;
    tradingPhaseDuration : Nat;
    participantA : ParticipantInfo;
    participantB : ParticipantInfo;
    verifierSolanaAddress : Text;
    arbitratorSolanaAddress : Text;
    comments : Text;
    stakingPhaseCompletedTimestamp : ?Nat;
    tradingPhaseCompletedTimestamp : ?Nat;
    timeoutTimestamp : ?Nat;
    resolvedTimestamp : ?Nat;
  };

  stable var transaction : ?TransactionInfo = null;

  public shared func initialize(
    stakingPhaseDuration : Nat,
    tradingPhaseDuration : Nat,
    participantASolanaAddress : Text,
    participantBSolanaAddress : Text,
    participantAShouldStakeUSDCAmount : Nat,
    participantBShouldStakeUSDCAmount : Nat,
    verifierSolanaAddress : Text,
    arbitratorSolanaAddress : Text,
    comments : Text,
  ) : async () {
    switch (transaction) {
      case (null) {
        let participantA : ParticipantInfo = {
          participantSolanaAddress = participantASolanaAddress;
          shouldStakeUSDCAmount = participantAShouldStakeUSDCAmount;
          stakeVaultSolanaAddress = null;
          stakeTimestamp = null;
          disputeTimestamp = null;
          withdrawablePercentage = ?0;
        };

        let participantB : ParticipantInfo = {
          participantSolanaAddress = participantBSolanaAddress;
          shouldStakeUSDCAmount = participantBShouldStakeUSDCAmount;
          stakeVaultSolanaAddress = null;
          stakeTimestamp = null;
          disputeTimestamp = null;
          withdrawablePercentage = ?0;
        };

        transaction := ?{
          status = #New;
          creationTimestamp = Int.abs(Time.now()) / 1_000_000_000;
          stakingPhaseDuration = stakingPhaseDuration;
          tradingPhaseDuration = tradingPhaseDuration;
          participantA = participantA;
          participantB = participantB;
          verifierSolanaAddress = verifierSolanaAddress;
          arbitratorSolanaAddress = arbitratorSolanaAddress;
          comments = comments;
          stakingPhaseCompletedTimestamp = null;
          tradingPhaseCompletedTimestamp = null;
          timeoutTimestamp = null;
          resolvedTimestamp = null;
        };
      };
      case (_) {
        throw Error.reject("Already initialized");
      };
    };
  };

  public shared func confirmStakingComplete(
    participantSolanaAddress : Text,
    stakeVaultSolanaAddress : Text,
    stakeTimestamp : Nat,
    verifierSignature : Text,
  ) : async () {
    switch (transaction) {
      case (null) {
        throw Error.reject("Should initialize first");
      };
      case (?txInfo) {
        let now : Nat = (Int.abs(Time.now()) / 1_000_000_000);
        if (now > txInfo.creationTimestamp + txInfo.stakingPhaseDuration) {
          transaction := ?{
            txInfo with
            status = #Timeout;
            timeoutTimestamp = ?now;
          };
          return;
        };

        if (not isValidStatusForStaking(txInfo.status)) {
          throw Error.reject("Invalid status for staking");
        };

        if (not verifyStakeSignature(participantSolanaAddress, stakeVaultSolanaAddress, stakeTimestamp, verifierSignature)) {
          throw Error.reject("Invalid signature");
        };

        var updatedTxInfo = txInfo;

        if (Text.equal(participantSolanaAddress, txInfo.participantA.participantSolanaAddress)) {
          updatedTxInfo := {
            txInfo with
            participantA = {
              txInfo.participantA with
              stakeVaultSolanaAddress = ?stakeVaultSolanaAddress;
              stakeTimestamp = ?stakeTimestamp;
              withdrawablePercentage = ?100;
            }
          };
        } else if (Text.equal(participantSolanaAddress, txInfo.participantB.participantSolanaAddress)) {
          updatedTxInfo := {
            txInfo with
            participantB = {
              txInfo.participantB with
              stakeVaultSolanaAddress = ?stakeVaultSolanaAddress;
              stakeTimestamp = ?stakeTimestamp;
              withdrawablePercentage = ?100;
            }
          };
        } else {
          throw Error.reject("Invalid participant address");
        };

        let isAStaked = switch (updatedTxInfo.participantA.stakeTimestamp) {
          case (null) { false };
          case (_) { true };
        };

        let isBStaked = switch (updatedTxInfo.participantB.stakeTimestamp) {
          case (null) { false };
          case (_) { true };
        };

        let newStatus = if (isAStaked and isBStaked) {
          #Staked;
        } else if (isAStaked or isBStaked) {
          #Staking;
        } else {
          throw Error.reject("Invalid value");
        };

        let newStakingPhaseCompletedTimestamp = if (isAStaked and isBStaked) {
          ?now;
        } else {
          null;
        };

        transaction := ?{
          updatedTxInfo with
          status = newStatus;
          stakingPhaseCompletedTimestamp = newStakingPhaseCompletedTimestamp;
        };
      };
    };
  };

  public shared func confirmTradingComplete(
    participantATimestamp : Nat,
    participantBTimestamp : Nat,
    participantASignature : Text,
    participantBSignature : Text,
  ) : async () {
    switch (transaction) {
      case (null) {
        throw Error.reject("Should initialize first");
      };
      case (?txInfo) {
        if (txInfo.status != #Staked) {
          throw Error.reject("Transaction is not in Staked status");
        };

        let now : Nat = (Int.abs(Time.now()) / 1_000_000_000);
        switch (txInfo.stakingPhaseCompletedTimestamp) {
          case (null) {
            throw Error.reject("Invalid value");
          };
          case (?stakingPhaseCompletedTimestamp) {

            if (now > stakingPhaseCompletedTimestamp + txInfo.tradingPhaseDuration) {
              transaction := ?{
                txInfo with
                status = #Timeout;
                timeoutTimestamp = ?now;
              };
              return;
            };

            if (
              not verifyTradeSignature(
                participantATimestamp,
                participantBTimestamp,
                participantASignature,
                participantBSignature,
              )
            ) {
              throw Error.reject("Invalid signature");
            };

            transaction := ?{
              txInfo with
              status = #Completed;
              tradingPhaseCompletedTimestamp = ?now;
            };
          };
        };
      };
    };
  };

  public shared func initiateDispute(
    participantTimestamp : Nat,
    participantSignature : Text,
  ) : async () {
    switch (transaction) {
      case (null) {
        throw Error.reject("Should initialize first");
      };
      case (?txInfo) {
        if (txInfo.status != #Staked) {
          throw Error.reject("Transaction is not in Staked status");
        };

        if (not verifyDisputeSignature(participantTimestamp, participantSignature)) {
          throw Error.reject("Invalid signature");
        };

        let now = Int.abs(Time.now()) / 1_000_000_000;
        switch (txInfo.stakingPhaseCompletedTimestamp) {
          case (null) {
            throw Error.reject("Invalid value");
          };
          case (?stakingPhaseCompletedTimestamp) {
            if (now > stakingPhaseCompletedTimestamp + txInfo.tradingPhaseDuration) {
              transaction := ?{
                txInfo with
                status = #Timeout;
                timeoutTimestamp = ?now;
              };
            } else {
              transaction := ?{
                txInfo with
                status = #Disputed;
              };
            };
          };
        };
      };
    };
  };

  public shared func resolveDispute(
    arbitrateTimestamp : Nat,
    comments : Text,
    participantAPercentage : Nat,
    participantBPercentage : Nat,
    arbitratorSignature : Text,
  ) : async () {
    switch (transaction) {
      case (null) {
        throw Error.reject("Should initialize first");
      };
      case (?txInfo) {
        if (txInfo.status != #Disputed) {
          throw Error.reject("Transaction is not in Disputed status");
        };

        if (not verifyResolveSignature(arbitrateTimestamp, comments, participantAPercentage, participantBPercentage, arbitratorSignature)) {
          throw Error.reject("Invalid signature");
        };

        let now = Int.abs(Time.now()) / 1_000_000_000;
        transaction := ?{
          txInfo with
          status = #Resolved;
          participantA = {
            txInfo.participantA with
            withdrawablePercentage = ?participantAPercentage;
          };
          participantB = {
            txInfo.participantB with
            withdrawablePercentage = ?participantBPercentage;
          };
          resolvedTimestamp = ?now;
          comments = comments;
        };
      };
    };
  };

  private func isValidStatusForStaking(status : Status) : Bool {
    switch (status) {
      case (#New) { return true };
      case (#Staking) { return true };
      case (_) { return false };
    };
  };

  private func verifyStakeSignature(
    participantSolanaAddress : Text,
    stakeVaultSolanaAddress : Text,
    stakeTimestamp : Nat,
    verifierSignature : Text,
  ) : Bool {
    // TODO: verify signature
    return true;
  };

  private func verifyTradeSignature(
    participantATimestamp : Nat,
    participantBTimestamp : Nat,
    participantASignature : Text,
    participantBSignature : Text,
  ) : Bool {
    // TODO: verify signature
    return true;
  };

  private func verifyDisputeSignature(
    participantTimestamp : Nat,
    participantSignature : Text,
  ) : Bool {
    // TODO: verify signature
    return true;
  };

  private func verifyResolveSignature(
    arbitrateTimestamp : Nat,
    comments : Text,
    participantAPercentage : Nat,
    participantBPercentage : Nat,
    arbitratorSignature : Text,
  ) : Bool {
    // TODO: verify signature
    return true;
  };

  public query func getThisCanisterPrincipal() : async Principal {
    Principal.fromActor(Guarantee);
  };

  public query func getTransactionStatus() : async ?Text {
    switch (transaction) {
      case (null) { null };
      case (?txInfo) {
        switch (txInfo.status) {
          case (#New) { ?"New" };
          case (#Staking) { ?"Staking" };
          case (#Staked) { ?"Staked" };
          case (#Completed) { ?"Completed" };
          case (#Timeout) { ?"Timeout" };
          case (#Disputed) { ?"Disputed" };
          case (#Resolved) { ?"Resolved" };
        };
      };
    };
  };

  public query func getTransactionDetails() : async ?{
    participantASolanaAddress : Text;
    participantBSolanaAddress : Text;
    participantAShouldStakeUSDCAmount : Nat;
    participantBShouldStakeUSDCAmount : Nat;
    stakingPhaseDuration : Nat;
    tradingPhaseDuration : Nat;
    verifierSolanaAddress : Text;
    arbitratorSolanaAddress : Text;
    creationTimestamp : Nat;
    status : Text;
    comments : ?Text;
  } {
    switch (transaction) {
      case (null) { null };
      case (?txInfo) {
        ?{
          participantASolanaAddress = txInfo.participantA.participantSolanaAddress;
          participantBSolanaAddress = txInfo.participantB.participantSolanaAddress;
          participantAShouldStakeUSDCAmount = txInfo.participantA.shouldStakeUSDCAmount;
          participantBShouldStakeUSDCAmount = txInfo.participantB.shouldStakeUSDCAmount;
          stakingPhaseDuration = txInfo.stakingPhaseDuration;
          tradingPhaseDuration = txInfo.tradingPhaseDuration;
          verifierSolanaAddress = txInfo.verifierSolanaAddress;
          arbitratorSolanaAddress = txInfo.arbitratorSolanaAddress;
          creationTimestamp = txInfo.creationTimestamp;
          status = switch (txInfo.status) {
            case (#New) { "New" };
            case (#Staking) { "Staking" };
            case (#Staked) { "Staked" };
            case (#Completed) { "Completed" };
            case (#Disputed) { "Disputed" };
            case (#Resolved) { "Resolved" };
            case (#Timeout) { "Timeout" };
          };
          comments = ?txInfo.comments;
        };
      };
    };
  };
};
