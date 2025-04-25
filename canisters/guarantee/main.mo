import Error "mo:base/Error";
import Int "mo:base/Int";
import Principal "mo:base/Principal";
import Text "mo:base/Text";
import Time "mo:base/Time";

actor Guarantee {
  type Status = {
    #New;
    #Staking;
    #Staked;
    #Traded;
    #Settling;
    #Settled;
    #Timeout;
    #Disputing;
    #Resolved;
  };

  type ParticipantInfo = {
    participantSolanaAddress : Text;
    shouldStakeUSDCAmount : Nat;
    withdrawablePercentage : Nat;
    stakeVaultSolanaAddress : ?Text;
    stakeTimestamp : ?Nat;
    settleTimestamp : ?Nat;
    disputeTimestamp : ?Nat;
  };

  type TransactionInfo = {
    status : Status;
    creationTimestamp : Nat;
    stakeDuration : Nat;
    tradeDuration : Nat;
    participantA : ParticipantInfo;
    participantB : ParticipantInfo;
    verifierSolanaAddress : Text;
    arbitratorSolanaAddress : Text;
    comments : Text;
    stakedTimestamp : ?Nat;
    tradedTimestamp : ?Nat;
    settledTimestamp : ?Nat;
    timeoutTimestamp : ?Nat;
    resolvedTimestamp : ?Nat;
  };

  stable var transaction : ?TransactionInfo = null;

  public shared func initialize(
    stakeDuration : Nat,
    tradeDuration : Nat,
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
          withdrawablePercentage = 0;
          stakeVaultSolanaAddress = null;
          stakeTimestamp = null;
          settleTimestamp = null;
          disputeTimestamp = null;
        };

        let participantB : ParticipantInfo = {
          participantSolanaAddress = participantBSolanaAddress;
          shouldStakeUSDCAmount = participantBShouldStakeUSDCAmount;
          withdrawablePercentage = 0;
          stakeVaultSolanaAddress = null;
          stakeTimestamp = null;
          settleTimestamp = null;
          disputeTimestamp = null;
        };

        transaction := ?{
          status = #New;
          creationTimestamp = (Int.abs(Time.now()) / 1_000_000_000);
          stakeDuration = stakeDuration;
          tradeDuration = tradeDuration;
          participantA = participantA;
          participantB = participantB;
          verifierSolanaAddress = verifierSolanaAddress;
          arbitratorSolanaAddress = arbitratorSolanaAddress;
          comments = comments;
          stakedTimestamp = null;
          tradedTimestamp = null;
          settledTimestamp = null;
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
    stakeVaultSolanaAddress : Text,
    participantSolanaAddress : Text,
    participantStakeTimestamp : Nat,
    verifierSignature : Text,
  ) : async () {
    switch (transaction) {
      case (null) {
        throw Error.reject("Should initialize first");
      };
      case (?txInfo) {
        let now : Nat = (Int.abs(Time.now()) / 1_000_000_000);
        if (now > txInfo.creationTimestamp + txInfo.stakeDuration) {
          transaction := ?{
            txInfo with
            status = #Timeout;
            timeoutTimestamp = ?now;
          };
        };

        if (not (txInfo.status == #New or txInfo.status == #Staking)) {
          throw Error.reject("Transaction is not in New/Staking status");
        };

        if (not verifyStakeSignature(stakeVaultSolanaAddress, participantSolanaAddress, participantStakeTimestamp, verifierSignature)) {
          throw Error.reject("Invalid signature");
        };

        var updatedTxInfo = txInfo;
        if (Text.equal(participantSolanaAddress, txInfo.participantA.participantSolanaAddress)) {
          updatedTxInfo := {
            txInfo with
            participantA = {
              txInfo.participantA with
              withdrawablePercentage = 100;
              stakeVaultSolanaAddress = ?stakeVaultSolanaAddress;
              stakeTimestamp = ?participantStakeTimestamp;
            }
          };
        } else if (Text.equal(participantSolanaAddress, txInfo.participantB.participantSolanaAddress)) {
          updatedTxInfo := {
            txInfo with
            participantB = {
              txInfo.participantB with
              withdrawablePercentage = 100;
              stakeVaultSolanaAddress = ?stakeVaultSolanaAddress;
              stakeTimestamp = ?participantStakeTimestamp;
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
        let newStakedTimestamp = if (newStatus == #Staked) {
          ?now;
        } else {
          null;
        };
        transaction := ?{
          updatedTxInfo with
          status = newStatus;
          stakedTimestamp = newStakedTimestamp;
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
        let now : Nat = (Int.abs(Time.now()) / 1_000_000_000);
        switch (txInfo.stakedTimestamp) {
          case (null) {
            throw Error.reject("Invalid value");
          };
          case (?stakedTimestamp) {
            if (now > stakedTimestamp + txInfo.tradeDuration) {
              transaction := ?{
                txInfo with
                status = #Timeout;
                timeoutTimestamp = ?now;
              };
            };

            if (not (txInfo.status == #Staked)) {
              throw Error.reject("Transaction is not in Staked status");
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
              status = #Traded;
              tradedTimestamp = ?now;
            };
          };
        };
      };
    };
  };

  public shared func confirmSettlingComplete(
    stakeVaultSolanaAddress : Text,
    participantSolanaAddress : Text,
    participantSettleTimestamp : Nat,
    verifierSignature : Text,
  ) : async () {
    switch (transaction) {
      case (null) {
        throw Error.reject("Should initialize first");
      };
      case (?txInfo) {
        if (not (txInfo.status == #Traded or txInfo.status == #Resolved or txInfo.status == #Timeout or txInfo.status == #Settling)) {
          throw Error.reject("Transaction is not in Traded/Resolved/Timeout/Settling status");
        };

        if (not verifySettleSignature(stakeVaultSolanaAddress, participantSolanaAddress, participantSettleTimestamp, verifierSignature)) {
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

        let isASettled = switch (updatedTxInfo.participantA.settleTimestamp) {
          case (null) { false };
          case (_) { true };
        };
        let isBSettled = switch (updatedTxInfo.participantB.settleTimestamp) {
          case (null) { false };
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
        transaction := ?{
          updatedTxInfo with
          status = newStatus;
          settledTimestamp = newSettledTimestamp;
        };
      };
    };
  };

  public shared func initiateDispute(
    participantSolanaAddress : Text,
    participantDisputeTimestamp : Nat,
    participantSignature : Text,
  ) : async () {
    switch (transaction) {
      case (null) {
        throw Error.reject("Should initialize first");
      };
      case (?txInfo) {
        let now : Nat = (Int.abs(Time.now()) / 1_000_000_000);
        switch (txInfo.stakedTimestamp) {
          case (null) {
            throw Error.reject("Invalid value");
          };
          case (?stakedTimestamp) {
            if (now > stakedTimestamp + txInfo.tradeDuration) {
              transaction := ?{
                txInfo with
                status = #Timeout;
                timeoutTimestamp = ?now;
              };
            };

            if (not (txInfo.status == #Staked)) {
              throw Error.reject("Transaction is not in Staked status");
            };

            if (not verifyDisputeSignature(participantSolanaAddress, participantDisputeTimestamp, participantSignature)) {
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

            transaction := ?{
              updatedTxInfo with
              status = #Disputing;
            };
          };
        };
      };
    };
  };

  public shared func resolveDispute(
    participantAWithdrawablePercentage : Nat,
    participantBWithdrawablePercentage : Nat,
    comments : Text,
    arbitratorResolveTimestamp : Nat,
    arbitratorSignature : Text,
  ) : async () {
    switch (transaction) {
      case (null) {
        throw Error.reject("Should initialize first");
      };
      case (?txInfo) {
        if (not (txInfo.status == #Disputing)) {
          throw Error.reject("Transaction is not in Disputing status");
        };

        if (not verifyResolveSignature(participantAWithdrawablePercentage, participantBWithdrawablePercentage, comments, arbitratorResolveTimestamp, arbitratorSignature)) {
          throw Error.reject("Invalid signature");
        };

        let now : Nat = (Int.abs(Time.now()) / 1_000_000_000);
        transaction := ?{
          txInfo with
          status = #Resolved;
          participantA = {
            txInfo.participantA with
            withdrawablePercentage = participantAWithdrawablePercentage;
          };
          participantB = {
            txInfo.participantB with
            withdrawablePercentage = participantBWithdrawablePercentage;
          };
          comments = comments;
          resolvedTimestamp = ?now;
        };
      };
    };
  };

  private func verifyStakeSignature(
    stakeVaultSolanaAddress : Text,
    participantSolanaAddress : Text,
    participantStakeTimestamp : Nat,
    verifierSignature : Text,
  ) : Bool {
    // TODO: verify signature
    true;
  };

  private func verifyTradeSignature(
    participantATimestamp : Nat,
    participantBTimestamp : Nat,
    participantASignature : Text,
    participantBSignature : Text,
  ) : Bool {
    // TODO: verify signature
    true;
  };

  private func verifySettleSignature(
    stakeVaultSolanaAddress : Text,
    participantSolanaAddress : Text,
    participantSettleTimestamp : Nat,
    verifierSignature : Text,
  ) : Bool {
    // TODO: verify signature
    true;
  };

  private func verifyDisputeSignature(
    participantSolanaAddress : Text,
    participantTimestamp : Nat,
    participantSignature : Text,
  ) : Bool {
    // TODO: verify signature
    true;
  };

  private func verifyResolveSignature(
    participantAWithdrawablePercentage : Nat,
    participantBWithdrawablePercentage : Nat,
    comments : Text,
    arbitratorResolveTimestamp : Nat,
    arbitratorSignature : Text,
  ) : Bool {
    // TODO: verify signature
    true;
  };

  public query func getTransactionStatus() : async ?Text {
    switch (transaction) {
      case (null) { null };
      case (?txInfo) {
        switch (txInfo.status) {
          case (#New) { ?"New" };
          case (#Staking) { ?"Staking" };
          case (#Staked) { ?"Staked" };
          case (#Traded) { ?"Traded" };
          case (#Settling) { ?"Settling" };
          case (#Settled) { ?"Settled" };
          case (#Timeout) { ?"Timeout" };
          case (#Disputing) { ?"Disputing" };
          case (#Resolved) { ?"Resolved" };
        };
      };
    };
  };

  public query func getParticipantDetails(participantSolanaAddress : Text) : async ?ParticipantInfo {
    switch (transaction) {
      case (null) { null };
      case (?txInfo) {
        if (Text.equal(participantSolanaAddress, txInfo.participantA.participantSolanaAddress)) {
          ?txInfo.participantA;
        } else if (Text.equal(participantSolanaAddress, txInfo.participantB.participantSolanaAddress)) {
          ?txInfo.participantB;
        } else {
          null;
        };
      };
    };
  };

  public query func getTransactionDetails() : async ?TransactionInfo {
    transaction;
  };

  public query func getThisCanisterPrincipal() : async Principal {
    Principal.fromActor(Guarantee);
  };
};
