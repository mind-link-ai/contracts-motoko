import Time "mo:base/Time";
import Principal "mo:base/Principal";
import Text "mo:base/Text";
import Nat "mo:base/Nat";
import Debug "mo:base/Debug";

actor GuaranteeContract {
  type TransactionStatus = {
    #New;
    #Staking;
    #Staked;
    #Completed;
    #Disputed;
    #Resolved;
    #Failed;
    #Ended;
  };

  type ParticipantInfo = {
    solanaAddress : Text;
    requiredAmount : Nat;
    vaultAddress : ?Text;
    stakeTimestamp : ?Int;
    stakeSignature : ?Text;
    withdrawablePercentage : Nat;
  };

  type TransactionInfo = {
    participantA : ParticipantInfo;
    participantB : ParticipantInfo;
    stakingWindowDuration : Int;
    tradingWindowDuration : Int;
    verifierAddress : Text;
    arbitratorAddress : Text;
    creationTimestamp : Int;
    stakingCompletedTimestamp : ?Int;
    status : TransactionStatus;
    comments : Text;
  };

  stable var transaction : ?TransactionInfo = null;

  public shared func initialize(
    participantASolanaAddress : Text,
    participantBSolanaAddress : Text,
    participantARequiredAmount : Nat,
    participantBRequiredAmount : Nat,
    stakingWindowDuration : Int,
    tradingWindowDuration : Int,
    verifierAddress : Text,
    arbitratorAddress : Text,
    comments : Text,
  ) : async () {
    switch (transaction) {
      case (null) {
        let participantA : ParticipantInfo = {
          solanaAddress = participantASolanaAddress;
          requiredAmount = participantARequiredAmount;
          vaultAddress = null;
          stakeTimestamp = null;
          stakeSignature = null;
          withdrawablePercentage = 0;
        };

        let participantB : ParticipantInfo = {
          solanaAddress = participantBSolanaAddress;
          requiredAmount = participantBRequiredAmount;
          vaultAddress = null;
          stakeTimestamp = null;
          stakeSignature = null;
          withdrawablePercentage = 0;
        };

        transaction := ?{
          participantA = participantA;
          participantB = participantB;
          stakingWindowDuration = stakingWindowDuration;
          tradingWindowDuration = tradingWindowDuration;
          verifierAddress = verifierAddress;
          arbitratorAddress = arbitratorAddress;
          creationTimestamp = Time.now();
          stakingCompletedTimestamp = null;
          status = #New;
          comments = comments;
        };
      };
      case (_) {
        Debug.print("Contract already initialized");
      };
    };
  };

  public shared func stake(
    participantSolanaAddress : Text,
    vaultAddress : Text,
    stakeTimestamp : Int,
    stakeSignature : Text,
  ) : async () {
    switch (transaction) {
      case (null) {
        Debug.print("Transaction not initialized");
        return;
      };
      case (?txInfo) {
        if (not isValidStateForStaking(txInfo.status)) {
          Debug.print("Invalid state for staking");
          return;
        };

        if (Time.now() > txInfo.creationTimestamp + txInfo.stakingWindowDuration) {
          transaction := ?{
            participantA = txInfo.participantA;
            participantB = txInfo.participantB;
            stakingWindowDuration = txInfo.stakingWindowDuration;
            tradingWindowDuration = txInfo.tradingWindowDuration;
            verifierAddress = txInfo.verifierAddress;
            arbitratorAddress = txInfo.arbitratorAddress;
            creationTimestamp = txInfo.creationTimestamp;
            stakingCompletedTimestamp = txInfo.stakingCompletedTimestamp;
            status = #Failed;
            comments = txInfo.comments;
          };
          return;
        };

        var updatedTxInfo = txInfo;
        var isParticipantA = false;
        var isParticipantB = false;

        if (Text.equal(participantSolanaAddress, txInfo.participantA.solanaAddress)) {
          let updatedParticipantA : ParticipantInfo = {
            solanaAddress = txInfo.participantA.solanaAddress;
            requiredAmount = txInfo.participantA.requiredAmount;
            vaultAddress = ?vaultAddress;
            stakeTimestamp = ?stakeTimestamp;
            stakeSignature = ?stakeSignature;
            withdrawablePercentage = 100;
          };
          updatedTxInfo := {
            participantA = updatedParticipantA;
            participantB = txInfo.participantB;
            stakingWindowDuration = txInfo.stakingWindowDuration;
            tradingWindowDuration = txInfo.tradingWindowDuration;
            verifierAddress = txInfo.verifierAddress;
            arbitratorAddress = txInfo.arbitratorAddress;
            creationTimestamp = txInfo.creationTimestamp;
            stakingCompletedTimestamp = txInfo.stakingCompletedTimestamp;
            status = txInfo.status;
            comments = txInfo.comments;
          };
          isParticipantA := true;
        } else if (Text.equal(participantSolanaAddress, txInfo.participantB.solanaAddress)) {
          let updatedParticipantB : ParticipantInfo = {
            solanaAddress = txInfo.participantB.solanaAddress;
            requiredAmount = txInfo.participantB.requiredAmount;
            vaultAddress = ?vaultAddress;
            stakeTimestamp = ?stakeTimestamp;
            stakeSignature = ?stakeSignature;
            withdrawablePercentage = 100;
          };
          updatedTxInfo := {
            participantA = txInfo.participantA;
            participantB = updatedParticipantB;
            stakingWindowDuration = txInfo.stakingWindowDuration;
            tradingWindowDuration = txInfo.tradingWindowDuration;
            verifierAddress = txInfo.verifierAddress;
            arbitratorAddress = txInfo.arbitratorAddress;
            creationTimestamp = txInfo.creationTimestamp;
            stakingCompletedTimestamp = txInfo.stakingCompletedTimestamp;
            status = txInfo.status;
            comments = txInfo.comments;
          };
          isParticipantB := true;
        } else {
          Debug.print("Invalid participant address");
          return;
        };

        var newStatus = updatedTxInfo.status;
        var newStakingCompletedTimestamp = updatedTxInfo.stakingCompletedTimestamp;

        let isAStaked = switch (updatedTxInfo.participantA.stakeTimestamp) {
          case (null) { false };
          case (_) { true };
        };

        let isBStaked = switch (updatedTxInfo.participantB.stakeTimestamp) {
          case (null) { false };
          case (_) { true };
        };

        if (isAStaked and isBStaked) {
          newStatus := #Staked;
          newStakingCompletedTimestamp := ?Time.now();
        } else if (isAStaked or isBStaked) {
          newStatus := #Staking;
        };

        transaction := ?{
          participantA = updatedTxInfo.participantA;
          participantB = updatedTxInfo.participantB;
          stakingWindowDuration = updatedTxInfo.stakingWindowDuration;
          tradingWindowDuration = updatedTxInfo.tradingWindowDuration;
          verifierAddress = updatedTxInfo.verifierAddress;
          arbitratorAddress = updatedTxInfo.arbitratorAddress;
          creationTimestamp = updatedTxInfo.creationTimestamp;
          stakingCompletedTimestamp = newStakingCompletedTimestamp;
          status = newStatus;
          comments = updatedTxInfo.comments;
        };
      };
    };
  };

  public shared func confirmTransactionComplete(
    contractAddress : Principal,
    participantATimestamp : Int,
    participantBTimestamp : Int,
    participantASignature : Text,
    participantBSignature : Text,
  ) : async () {
    switch (transaction) {
      case (null) {
        Debug.print("Transaction not initialized");
        return;
      };
      case (?txInfo) {
        if (txInfo.status != #Staked) {
          Debug.print("Transaction not in Staked state");
          return;
        };

        switch (txInfo.stakingCompletedTimestamp) {
          case (null) {
            Debug.print("Staking not completed yet");
            return;
          };
          case (?stakingCompletedTime) {
            if (Time.now() > stakingCompletedTime + txInfo.tradingWindowDuration) {
              transaction := ?{
                participantA = txInfo.participantA;
                participantB = txInfo.participantB;
                stakingWindowDuration = txInfo.stakingWindowDuration;
                tradingWindowDuration = txInfo.tradingWindowDuration;
                verifierAddress = txInfo.verifierAddress;
                arbitratorAddress = txInfo.arbitratorAddress;
                creationTimestamp = txInfo.creationTimestamp;
                stakingCompletedTimestamp = txInfo.stakingCompletedTimestamp;
                status = #Failed;
                comments = txInfo.comments;
              };
              return;
            };
          };
        };

        transaction := ?{
          participantA = txInfo.participantA;
          participantB = txInfo.participantB;
          stakingWindowDuration = txInfo.stakingWindowDuration;
          tradingWindowDuration = txInfo.tradingWindowDuration;
          verifierAddress = txInfo.verifierAddress;
          arbitratorAddress = txInfo.arbitratorAddress;
          creationTimestamp = txInfo.creationTimestamp;
          stakingCompletedTimestamp = txInfo.stakingCompletedTimestamp;
          status = #Completed;
          comments = txInfo.comments;
        };
      };
    };
  };

  public shared func initiateDispute(
    contractAddress : Principal,
    participantTimestamp : Int,
    participantSignature : Text,
  ) : async () {
    switch (transaction) {
      case (null) {
        Debug.print("Transaction not initialized");
        return;
      };
      case (?txInfo) {
        if (txInfo.status != #Staked) {
          Debug.print("Transaction not in Staked state");
          return;
        };

        switch (txInfo.stakingCompletedTimestamp) {
          case (null) {
            Debug.print("Staking not completed yet");
            return;
          };
          case (?stakingCompletedTime) {
            if (Time.now() > stakingCompletedTime + txInfo.tradingWindowDuration) {
              transaction := ?{
                participantA = txInfo.participantA;
                participantB = txInfo.participantB;
                stakingWindowDuration = txInfo.stakingWindowDuration;
                tradingWindowDuration = txInfo.tradingWindowDuration;
                verifierAddress = txInfo.verifierAddress;
                arbitratorAddress = txInfo.arbitratorAddress;
                creationTimestamp = txInfo.creationTimestamp;
                stakingCompletedTimestamp = txInfo.stakingCompletedTimestamp;
                status = #Failed;
                comments = txInfo.comments;
              };
              return;
            };
          };
        };

        transaction := ?{
          participantA = txInfo.participantA;
          participantB = txInfo.participantB;
          stakingWindowDuration = txInfo.stakingWindowDuration;
          tradingWindowDuration = txInfo.tradingWindowDuration;
          verifierAddress = txInfo.verifierAddress;
          arbitratorAddress = txInfo.arbitratorAddress;
          creationTimestamp = txInfo.creationTimestamp;
          stakingCompletedTimestamp = txInfo.stakingCompletedTimestamp;
          status = #Disputed;
          comments = txInfo.comments;
        };
      };
    };
  };

  public shared func resolveDispute(
    contractAddress : Principal,
    participantAPercentage : Nat,
    participantBPercentage : Nat,
    comments : Text,
    arbitratorTimestamp : Int,
    arbitratorSignature : Text,
  ) : async () {
    switch (transaction) {
      case (null) {
        Debug.print("Transaction not initialized");
        return;
      };
      case (?txInfo) {
        if (txInfo.status != #Disputed) {
          Debug.print("Transaction not in Disputed state");
          return;
        };

        let updatedParticipantA : ParticipantInfo = {
          solanaAddress = txInfo.participantA.solanaAddress;
          requiredAmount = txInfo.participantA.requiredAmount;
          vaultAddress = txInfo.participantA.vaultAddress;
          stakeTimestamp = txInfo.participantA.stakeTimestamp;
          stakeSignature = txInfo.participantA.stakeSignature;
          withdrawablePercentage = participantAPercentage;
        };

        let updatedParticipantB : ParticipantInfo = {
          solanaAddress = txInfo.participantB.solanaAddress;
          requiredAmount = txInfo.participantB.requiredAmount;
          vaultAddress = txInfo.participantB.vaultAddress;
          stakeTimestamp = txInfo.participantB.stakeTimestamp;
          stakeSignature = txInfo.participantB.stakeSignature;
          withdrawablePercentage = participantBPercentage;
        };

        transaction := ?{
          participantA = updatedParticipantA;
          participantB = updatedParticipantB;
          stakingWindowDuration = txInfo.stakingWindowDuration;
          tradingWindowDuration = txInfo.tradingWindowDuration;
          verifierAddress = txInfo.verifierAddress;
          arbitratorAddress = txInfo.arbitratorAddress;
          creationTimestamp = txInfo.creationTimestamp;
          stakingCompletedTimestamp = txInfo.stakingCompletedTimestamp;
          status = #Resolved;
          comments = comments;
        };
      };
    };
  };

  public shared func forceEnd(
    contractAddress : Principal,
    participantAPercentage : Nat,
    participantBPercentage : Nat,
    comments : Text,
    arbitratorTimestamp : Int,
    arbitratorSignature : Text,
  ) : async () {
    switch (transaction) {
      case (null) {
        Debug.print("Transaction not initialized");
        return;
      };
      case (?txInfo) {
        let updatedParticipantA : ParticipantInfo = {
          solanaAddress = txInfo.participantA.solanaAddress;
          requiredAmount = txInfo.participantA.requiredAmount;
          vaultAddress = txInfo.participantA.vaultAddress;
          stakeTimestamp = txInfo.participantA.stakeTimestamp;
          stakeSignature = txInfo.participantA.stakeSignature;
          withdrawablePercentage = participantAPercentage;
        };

        let updatedParticipantB : ParticipantInfo = {
          solanaAddress = txInfo.participantB.solanaAddress;
          requiredAmount = txInfo.participantB.requiredAmount;
          vaultAddress = txInfo.participantB.vaultAddress;
          stakeTimestamp = txInfo.participantB.stakeTimestamp;
          stakeSignature = txInfo.participantB.stakeSignature;
          withdrawablePercentage = participantBPercentage;
        };

        transaction := ?{
          participantA = updatedParticipantA;
          participantB = updatedParticipantB;
          stakingWindowDuration = txInfo.stakingWindowDuration;
          tradingWindowDuration = txInfo.tradingWindowDuration;
          verifierAddress = txInfo.verifierAddress;
          arbitratorAddress = txInfo.arbitratorAddress;
          creationTimestamp = txInfo.creationTimestamp;
          stakingCompletedTimestamp = txInfo.stakingCompletedTimestamp;
          status = #Ended;
          comments = comments;
        };
      };
    };
  };

  public query func getTransactionStatus() : async ?Text {
    switch (transaction) {
      case (null) { return null };
      case (?txInfo) {
        switch (txInfo.status) {
          case (#New) { return ?"New" };
          case (#Staking) { return ?"Staking" };
          case (#Staked) { return ?"Staked" };
          case (#Completed) { return ?"Completed" };
          case (#Disputed) { return ?"Disputed" };
          case (#Resolved) { return ?"Resolved" };
          case (#Failed) { return ?"Failed" };
          case (#Ended) { return ?"Ended" };
        };
      };
    };
  };

  public query func getParticipantAWithdrawablePercentage() : async ?Nat {
    switch (transaction) {
      case (null) { return null };
      case (?txInfo) { return ?txInfo.participantA.withdrawablePercentage };
    };
  };

  public query func getParticipantBWithdrawablePercentage() : async ?Nat {
    switch (transaction) {
      case (null) { return null };
      case (?txInfo) { return ?txInfo.participantB.withdrawablePercentage };
    };
  };

  public query func getTransactionDetails() : async ?{
    participantASolanaAddress : Text;
    participantBSolanaAddress : Text;
    participantARequiredAmount : Nat;
    participantBRequiredAmount : Nat;
    stakingWindowDuration : Int;
    tradingWindowDuration : Int;
    verifierAddress : Text;
    arbitratorAddress : Text;
    creationTimestamp : Int;
    status : Text;
    comments : Text;
  } {
    switch (transaction) {
      case (null) { return null };
      case (?txInfo) {
        let statusText = switch (txInfo.status) {
          case (#New) { "New" };
          case (#Staking) { "Staking" };
          case (#Staked) { "Staked" };
          case (#Completed) { "Completed" };
          case (#Disputed) { "Disputed" };
          case (#Resolved) { "Resolved" };
          case (#Failed) { "Failed" };
          case (#Ended) { "Ended" };
        };

        return ?{
          participantASolanaAddress = txInfo.participantA.solanaAddress;
          participantBSolanaAddress = txInfo.participantB.solanaAddress;
          participantARequiredAmount = txInfo.participantA.requiredAmount;
          participantBRequiredAmount = txInfo.participantB.requiredAmount;
          stakingWindowDuration = txInfo.stakingWindowDuration;
          tradingWindowDuration = txInfo.tradingWindowDuration;
          verifierAddress = txInfo.verifierAddress;
          arbitratorAddress = txInfo.arbitratorAddress;
          creationTimestamp = txInfo.creationTimestamp;
          status = statusText;
          comments = txInfo.comments;
        };
      };
    };
  };

  private func isValidStateForStaking(status : TransactionStatus) : Bool {
    switch (status) {
      case (#New) { return true };
      case (#Staking) { return true };
      case (_) { return false };
    };
  };
};
