import Blob "mo:base/Blob";
import Error "mo:base/Error";
import Int "mo:base/Int";
import NACL "mo:tweetnacl";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Principal "mo:base/Principal";
import Text "mo:base/Text";
import Time "mo:base/Time";
import Array "mo:base/Array";
import Iter "mo:base/Iter";
import Char "mo:base/Char";

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

  stable var transaction : ?TransactionInfo = null;

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
  ) : async () {
    switch (transaction) {
      case (null) {
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

        transaction := ?{
          status = #New;
          comments = comments;
          participantA = participantA;
          participantB = participantB;
          verifierSolanaAddress = verifierSolanaAddress;
          arbitratorSolanaAddress = arbitratorSolanaAddress;
          stakeDuration = stakeDuration;
          tradeDuration = tradeDuration;
          newTimestamp = (Int.abs(Time.now()) / 1_000_000_000);
          stakedTimestamp = null;
          tradedTimestamp = null;
          timeoutTimestamp = null;
          resolvedTimestamp = null;
          settledTimestamp = null;
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
        if (now > (txInfo.newTimestamp + txInfo.stakeDuration)) {
          transaction := ?{
            txInfo with
            status = #Timeout;
            timeoutTimestamp = ?now;
          };
          return;
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
        switch (txInfo.stakedTimestamp) {
          case (null) {
            throw Error.reject("Invalid value");
          };
          case (?stakedTimestamp) {
            let now : Nat = (Int.abs(Time.now()) / 1_000_000_000);
            if (now > (stakedTimestamp + txInfo.tradeDuration)) {
              transaction := ?{
                txInfo with
                status = #Timeout;
                tradedTimestamp = ?now;
                timeoutTimestamp = ?now;
              };
              return;
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
        if (not (txInfo.status == #Traded or txInfo.status == #Timeout or txInfo.status == #Resolved or txInfo.status == #Settling)) {
          throw Error.reject("Transaction is not in Traded/Timeout/Resolved/Settling status");
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
        switch (txInfo.stakedTimestamp) {
          case (null) {
            throw Error.reject("Invalid value");
          };
          case (?stakedTimestamp) {
            let now : Nat = (Int.abs(Time.now()) / 1_000_000_000);
            if (now > (stakedTimestamp + txInfo.tradeDuration)) {
              transaction := ?{
                txInfo with
                status = #Timeout;
                tradedTimestamp = ?now;
                timeoutTimestamp = ?now;
              };
              return;
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
    comments : Text,
    participantAWithdrawableUSDCAmount : Nat,
    participantBWithdrawableUSDCAmount : Nat,
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

        if (
          (participantAWithdrawableUSDCAmount + participantBWithdrawableUSDCAmount) > (txInfo.participantA.shouldStakeUSDCAmount + txInfo.participantB.shouldStakeUSDCAmount)
        ) {
          throw Error.reject("Total withdrawable amount exceeds total staked amount");
        };

        if (not verifyResolveSignature(participantAWithdrawableUSDCAmount, participantBWithdrawableUSDCAmount, arbitratorResolveTimestamp, arbitratorSignature)) {
          throw Error.reject("Invalid signature");
        };

        let now : Nat = (Int.abs(Time.now()) / 1_000_000_000);
        transaction := ?{
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
      };
    };
  };

  // Base58 character set
  private let ALPHABET : [Char] = [
    '1',
    '2',
    '3',
    '4',
    '5',
    '6',
    '7',
    '8',
    '9',
    'A',
    'B',
    'C',
    'D',
    'E',
    'F',
    'G',
    'H',
    'J',
    'K',
    'L',
    'M',
    'N',
    'P',
    'Q',
    'R',
    'S',
    'T',
    'U',
    'V',
    'W',
    'X',
    'Y',
    'Z',
    'a',
    'b',
    'c',
    'd',
    'e',
    'f',
    'g',
    'h',
    'i',
    'j',
    'k',
    'm',
    'n',
    'o',
    'p',
    'q',
    'r',
    's',
    't',
    'u',
    'v',
    'w',
    'x',
    'y',
    'z',
  ];

  // Convert character to Base58 index
  private func charToIndex(c : Char) : ?Nat {
    for (i in Iter.range(0, ALPHABET.size() - 1)) {
      if (ALPHABET[i] == c) {
        return ?i;
      };
    };
    return null;
  };

  // Base58 decoding function
  private func base58ToBytes(text : Text) : [Nat8] {
    let textChars = Text.toIter(text);
    var result : [Nat8] = [];
    var leadingOnes = 0;

    // Process leading '1's (corresponding to leading 0 bytes)
    label l for (c in textChars) {
      if (c == '1') {
        leadingOnes += 1;
      } else {
        break l;
      };
    };

    // Add leading 0 bytes
    if (leadingOnes > 0) {
      result := Array.tabulate<Nat8>(leadingOnes, func(_) = 0);
    };

    // Decode remaining characters
    let chars = Text.toArray(text);
    var acc : Nat = 0;
    var accLen = 0;

    for (i in Iter.range(leadingOnes, chars.size() - 1)) {
      let c = chars[i];
      switch (charToIndex(c)) {
        case (?idx) {
          acc := acc * 58 + idx;
          accLen += 1;

          // Extract a byte after processing several characters
          if (accLen >= 2) {
            let b = Nat8.fromNat(acc % 256);
            acc := acc / 256;
            accLen -= 1;
            result := Array.append(result, [b]);
          };
        };
        case (null) {
          // Ignore invalid characters
        };
      };
    };

    // Process remaining accumulator value
    if (accLen > 0) {
      let b = Nat8.fromNat(acc);
      result := Array.append(result, [b]);
    };

    return result;
  };

  private func verifyStakeSignature(
    stakeVaultSolanaAddress : Text,
    participantSolanaAddress : Text,
    participantStakeTimestamp : Nat,
    verifierSignature : Text,
  ) : Bool {
    switch (transaction) {
      case (null) { return false };
      case (?txInfo) {
        let thisCanisterPrincipalText = privateGetThisCanisterPrincipalText();
        let message = thisCanisterPrincipalText # "ConfirmStake" # stakeVaultSolanaAddress # participantSolanaAddress # natToText(participantStakeTimestamp);
        let messageBytes = textToBytes(message);
        let signatureBytes = base58ToBytes(verifierSignature);
        let publicKeyBytes = base58ToBytes(txInfo.verifierSolanaAddress);
        return NACL.SIGN.DETACHED.verify(messageBytes, signatureBytes, publicKeyBytes);
      };
    };
  };

  private func verifyTradeSignature(
    participantATimestamp : Nat,
    participantBTimestamp : Nat,
    participantASignature : Text,
    participantBSignature : Text,
  ) : Bool {
    switch (transaction) {
      case (null) { return false };
      case (?txInfo) {
        let thisCanisterPrincipalText = privateGetThisCanisterPrincipalText();

        let messageA = thisCanisterPrincipalText # "ConfirmTrade" # natToText(participantATimestamp);
        let messageABytes = textToBytes(messageA);
        let signatureABytes = base58ToBytes(participantASignature);
        let publicKeyABytes = base58ToBytes(txInfo.participantA.participantSolanaAddress);

        let messageB = thisCanisterPrincipalText # "ConfirmTrade" # natToText(participantBTimestamp);
        let messageBBytes = textToBytes(messageB);
        let signatureBBytes = base58ToBytes(participantBSignature);
        let publicKeyBBytes = base58ToBytes(txInfo.participantB.participantSolanaAddress);

        let isValidA = NACL.SIGN.DETACHED.verify(messageABytes, signatureABytes, publicKeyABytes);
        let isValidB = NACL.SIGN.DETACHED.verify(messageBBytes, signatureBBytes, publicKeyBBytes);
        return isValidA and isValidB;
      };
    };
  };

  private func verifySettleSignature(
    stakeVaultSolanaAddress : Text,
    participantSolanaAddress : Text,
    participantSettleTimestamp : Nat,
    verifierSignature : Text,
  ) : Bool {
    switch (transaction) {
      case (null) { return false };
      case (?txInfo) {
        let thisCanisterPrincipalText = privateGetThisCanisterPrincipalText();
        let message = thisCanisterPrincipalText # "ConfirmSettle" # stakeVaultSolanaAddress # participantSolanaAddress # natToText(participantSettleTimestamp);
        let messageBytes = textToBytes(message);
        let signatureBytes = base58ToBytes(verifierSignature);
        let publicKeyBytes = base58ToBytes(txInfo.verifierSolanaAddress);
        return NACL.SIGN.DETACHED.verify(messageBytes, signatureBytes, publicKeyBytes);
      };
    };
  };

  private func verifyDisputeSignature(
    participantSolanaAddress : Text,
    participantTimestamp : Nat,
    participantSignature : Text,
  ) : Bool {
    switch (transaction) {
      case (null) { return false };
      case (?txInfo) {
        if (not (Text.equal(participantSolanaAddress, txInfo.participantA.participantSolanaAddress) or Text.equal(participantSolanaAddress, txInfo.participantB.participantSolanaAddress))) {
          return false;
        };
        let thisCanisterPrincipalText = privateGetThisCanisterPrincipalText();
        let message = thisCanisterPrincipalText # "InitiateDispute" # natToText(participantTimestamp);
        let messageBytes = textToBytes(message);
        let signatureBytes = base58ToBytes(participantSignature);
        let publicKeyBytes = base58ToBytes(participantSolanaAddress);
        return NACL.SIGN.DETACHED.verify(messageBytes, signatureBytes, publicKeyBytes);
      };
    };
  };

  private func verifyResolveSignature(

    participantAWithdrawableUSDCAmount : Nat,
    participantBWithdrawableUSDCAmount : Nat,
    arbitratorResolveTimestamp : Nat,
    arbitratorSignature : Text,
  ) : Bool {
    switch (transaction) {
      case (null) { return false };
      case (?txInfo) {
        let thisCanisterPrincipalText = privateGetThisCanisterPrincipalText();
        let message = thisCanisterPrincipalText #
        "ResolveDispute" #
        natToText(participantAWithdrawableUSDCAmount) #
        natToText(participantBWithdrawableUSDCAmount) #
        natToText(arbitratorResolveTimestamp);
        let messageBytes = textToBytes(message);
        let signatureBytes = base58ToBytes(arbitratorSignature);
        let publicKeyBytes = base58ToBytes(txInfo.arbitratorSolanaAddress);
        return NACL.SIGN.DETACHED.verify(messageBytes, signatureBytes, publicKeyBytes);
      };
    };
  };

  private func natToText(n : Nat) : Text {
    Nat.toText(n);
  };

  private func textToBytes(x : Text) : [Nat8] {
    Blob.toArray(Text.encodeUtf8(x));
  };

  private func privateGetThisCanisterPrincipalText() : Text {
    Principal.toText(Principal.fromActor(Guarantee));
  };

  public query func getThisCanisterPrincipalText() : async Text {
    privateGetThisCanisterPrincipalText();
  };

  public query func getTransactionStatusText() : async ?Text {
    switch (transaction) {
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

  public query func getTransactionDetails() : async ?TransactionInfo {
    transaction;
  };
};
