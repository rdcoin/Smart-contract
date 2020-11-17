pragma solidity 0.7.0;

import "./Median.sol";
import "./Owned.sol";
import "./SafeMath128.sol";
import "./SafeMath32.sol";
import "./SafeMath64.sol";
import "../interfaces/AggregatorV2V3Interface.sol";
import "../interfaces/AggregatorValidatorInterface.sol";
import "../interfaces/LinkTokenInterface.sol";
import "../vendor/SafeMathChainlink.sol";

/**
 * @title The Prepaid Aggregator contract
 * @notice Handles aggregating data pushed in from off-chain, and unlocks
 * payment for oracles as they report. Oracles' submissions are gathered in
 * rounds, with each round aggregating the submissions for each oracle into a
 * single answer. The latest aggregated answer is exposed as well as historical
 * answers and their updated at timestamp.
 */
contract FluxAggregator is AggregatorV2V3Interface, Owned {
  using SafeMathChainlink for uint256;
  using SafeMath128 for uint128;
  using SafeMath64 for uint64;
  using SafeMath32 for uint32;

  struct Round {
    int256 answer;
    uint64 startedAt;
    uint64 updatedAt;
    uint32 answeredInRound;
  }

  struct RoundDetails {
    int256[] submissions;
    uint32 maxSubmissions;
    uint32 minSubmissions;
    uint32 timeout;
    uint128 paymentAmount;
  }

  struct OracleStatus {
    uint128 withdrawable;
    uint32 startingRound;
    uint32 endingRound;
    uint32 lastReportedRound;
    uint32 lastStartedRound;
    int256 latestSubmission;
    uint16 index;
    address admin;
    address pendingAdmin;
  }

  struct Requester {
    bool authorized;
    uint32 delay;
    uint32 lastStartedRound;
  }

  struct Funds {
    uint128 available;
    uint128 allocated;
  }

  LinkTokenInterface public linkToken;
  AggregatorValidatorInterface public validator;

  // Round related params
  uint128 public paymentAmount;
  uint32 public maxSubmissionCount;
  uint32 public minSubmissionCount;
  uint32 public restartDelay;
  uint32 public timeout;
  uint8 public override decimals;
  string public override description;

  int256 immutable public minSubmissionValue;
  int256 immutable public maxSubmissionValue;

  uint256 constant public override version = 3;


  // To ensure owner isn't withdrawing required funds as oracles are
  // submitting updates, we enforce that the contract maintains a minimum
  // reserve of RESERVE_ROUNDS * oracleCount() LINK earmarked for payment to
  // oracles. (Of course, this doesn't prevent the contract from running out of
  // funds without the owner's intervention.)
  uint256 constant private RESERVE_ROUNDS = 2;
  uint256 constant private MAX_ORACLE_COUNT = 77;
  uint32 constant private ROUND_MAX = 2**32-1;
  uint256 private constant VALIDATOR_GAS_LIMIT = 100000;
  // An error specific to the Aggregator V3 Interface, to prevent possible
  // confusion around accidentally reading unset values as reported values.
  string constant private V3_NO_DATA_ERROR = "No data present";

  uint32 private reportingRoundId;
  uint32 internal latestRoundId;
  mapping(address => OracleStatus) private oracles;
  mapping(uint32 => Round) internal rounds;
  mapping(uint32 => RoundDetails) internal details;
  mapping(address => Requester) internal requesters;
  address[] private oracleAddresses;
  Funds private recordedFunds;

  event AvailableFundsUpdated(
    uint256 indexed amount
  );
  event RoundDetailsUpdated(
    uint128 indexed paymentAmount,
    uint32 indexed minSubmissionCount,
    uint32 indexed maxSubmissionCount,
    uint32 restartDelay,
    uint32 timeout // measured in seconds
  );
  event OraclePermissionsUpdated(
    address indexed oracle,
    bool indexed whitelisted
  );
  event OracleAdminUpdated(
    address indexed oracle,
    address indexed newAdmin
  );
  event OracleAdminUpdateRequested(
    address indexed oracle,
    address admin,
    address newAdmin
  );
  event SubmissionReceived(
    int256 indexed submission,
    uint32 indexed round,
    address indexed oracle
  );
  event RequesterPermissionsSet(
    address indexed requester,
    bool authorized,
    uint32 delay
  );
  event ValidatorUpdated(
    address indexed previous,
    address indexed current
  );

  /**
   * @notice set up the aggregator with initial configuration
   * @param linkAddress The address of the LINK token
   * @param linkPaymentAmount The amount paid of LINK paid to each oracle per submission, in wei (units of 10⁻¹⁸ LINK)
   * @param timoutSeconds is the number of seconds after the previous round that are
   * allowed to lapse before allowing an oracle to skip an unfinished round
   * @param validatorAddress is an optional contract address for validating
   * external validation of answers
   * @param minimumSubmissionValue is an immutable check for a lower bound of what
   * submission values are accepted from an oracle
   * @param maximumSubmissionValue is an immutable check for an upper bound of what
   * submission values are accepted from an oracle
   * @param decimalPlaces represents the number of decimals to offset the answer by
   * @param feedDescription a short description of what is being reported
   */
  constructor(
    address linkAddress,
    uint128 linkPaymentAmount,
    uint32 timoutSeconds,
    address validatorAddress,
    int256 minimumSubmissionValue,
    int256 maximumSubmissionValue,
    uint8 decimalPlaces,
    string memory feedDescription
  ) public {
    linkToken = LinkTokenInterface(linkAddress);
    updateFutureRounds(linkPaymentAmount, 0, 0, 0, timoutSeconds);
    setValidator(validatorAddress);
    minSubmissionValue = minimumSubmissionValue;
    maxSubmissionValue = maximumSubmissionValue;
    decimals = decimalPlaces;
    description = feedDescription;
    rounds[0].updatedAt = uint64(block.timestamp.sub(uint256(timoutSeconds)));
  }

  /**
   * @notice called by oracles when they have witnessed a need to update
   * @param roundId is the ID of the round this submission pertains to
   * @param submission is the updated data that the oracle is submitting
   */
  function submit(uint256 roundId, int256 submission)
    external
  {
    bytes memory error = validateOracleRound(msg.sender, uint32(roundId));
    require(submission >= minSubmissionValue, "value below minSubmissionValue");
    require(submission <= maxSubmissionValue, "value above maxSubmissionValue");
    require(error.length == 0, string(error));

    oracleInitializeNewRound(uint32(roundId));
    recordSubmission(submission, uint32(roundId));
    (bool updated, int256 newAnswer) = updateRoundAnswer(uint32(roundId));
    payOracle(uint32(roundId));
    deleteRoundDetails(uint32(roundId));
    if (updated) {
      validateAnswer(uint32(roundId), newAnswer);
    }
  }

  /**
   * @notice called by the owner to remove and add new oracles as well as
   * update the round related parameters that pertain to total oracle count
   * @param removed is the list of addresses for the new Oracles being removed
   * @param added is the list of addresses for the new Oracles being added
   * @param addedAdmins is the admin addresses for the new respective added
   * list. Only this address is allowed to access the respective oracle's funds
   * @param minimumSubmissions is the new minimum submission count for each round
   * @param maximumSubmissions is the new maximum submission count for each round
   * @param restartDelayRounds is the number of rounds an Oracle has to wait before
   * they can initiate a round
   */
  function changeOracles(
    address[] calldata removed,
    address[] calldata added,
    address[] calldata addedAdmins,
    uint32 minimumSubmissions,
    uint32 maximumSubmissions,
    uint32 restartDelayRounds
  )
    external
    onlyOwner()
  {
    for (uint256 i = 0; i < removed.length; i++) {
      removeOracle(removed[i]);
    }

    require(added.length == addedAdmins.length, "need same oracle and admin count");
    require(uint256(oracleCount()).add(added.length) <= MAX_ORACLE_COUNT, "max oracles allowed");

    for (uint256 i = 0; i < added.length; i++) {
      addOracle(added[i], addedAdmins[i]);
    }

    updateFutureRounds(paymentAmount, minimumSubmissions, maximumSubmissions, restartDelayRounds, timeout);
  }

  /**
   * @notice update the round and payment related parameters for subsequent
   * rounds
   * @param linkPaymentAmount is the payment amount for subsequent rounds
   * @param minimumSubmissions is the new minimum submission count for each round
   * @param maximumSubmissions is the new maximum submission count for each round
   * @param restartDelayRounds is the number of rounds an Oracle has to wait before
   * they can initiate a round
   * @param timeoutSeconds is the number of seconds after the previous round that are
   * allowed to lapse before allowing an oracle to skip an unfinished round
   */
  function updateFutureRounds(
    uint128 linkPaymentAmount,
    uint32 minimumSubmissions,
    uint32 maximumSubmissions,
    uint32 restartDelayRounds,
    uint32 timeoutSeconds
  )
    public
    onlyOwner()
  {
    uint32 oracleNum = oracleCount(); // Save on storage reads
    require(maximumSubmissions >= minimumSubmissions, "max must equal/exceed min");
    require(oracleNum >= maximumSubmissions, "max cannot exceed total");
    require(oracleNum == 0 || oracleNum > restartDelayRounds, "delay cannot exceed total");
    require(recordedFunds.available >= requiredReserve(linkPaymentAmount), "insufficient funds for payment");
    if (oracleCount() > 0) {
      require(minimumSubmissions > 0, "min must be greater than 0");
    }

    paymentAmount = linkPaymentAmount;
    minSubmissionCount = minimumSubmissions;
    maxSubmissionCount = maximumSubmissions;
    restartDelay = restartDelayRounds;
    timeout = timeoutSeconds;

    emit RoundDetailsUpdated(
      paymentAmount,
      minimumSubmissions,
      maximumSubmissions,
      restartDelayRounds,
      timeoutSeconds
    );
  }

  /**
   * @notice the amount of payment yet to be withdrawn by oracles
   */
  function allocatedFunds()
    external
    view
    returns (uint128)
  {
    return recordedFunds.allocated;
  }

  /**
   * @notice the amount of future funding available to oracles
   */
  function availableFunds()
    external
    view
    returns (uint128)
  {
    return recordedFunds.available;
  }

  /**
   * @notice recalculate the amount of LINK available for payouts
   */
  function updateAvailableFunds()
    public
  {
    Funds memory funds = recordedFunds;

    uint256 nowAvailable = linkToken.balanceOf(address(this)).sub(funds.allocated);

    if (funds.available != nowAvailable) {
      recordedFunds.available = uint128(nowAvailable);
      emit AvailableFundsUpdated(nowAvailable);
    }
  }

  /**
   * @notice returns the number of oracles
   */
  function oracleCount() public view returns (uint8) {
    return uint8(oracleAddresses.length);
  }

  /**
   * @notice returns an array of addresses containing the oracles on contract
   */
  function getOracles() external view returns (address[] memory) {
    return oracleAddresses;
  }

  /**
   * @notice get the most recently reported answer
   *
   * @dev #[deprecated] Use latestRoundData instead. This does not error if no
   * answer has been reached, it will simply return 0. Either wait to point to
   * an already answered Aggregator or use the recommended latestRoundData
   * instead which includes better verification information.
   */
  function latestAnswer()
    public
    view
    virtual
    override
    returns (int256)
  {
    return rounds[latestRoundId].answer;
  }

  /**
   * @notice get the most recent updated at timestamp
   *
   * @dev #[deprecated] Use latestRoundData instead. This does not error if no
   * answer has been reached, it will simply return 0. Either wait to point to
   * an already answered Aggregator or use the recommended latestRoundData
   * instead which includes better verification information.
   */
  function latestTimestamp()
    public
    view
    virtual
    override
    returns (uint256)
  {
    return rounds[latestRoundId].updatedAt;
  }

  /**
   * @notice get the ID of the last updated round
   *
   * @dev #[deprecated] Use latestRoundData instead. This does not error if no
   * answer has been reached, it will simply return 0. Either wait to point to
   * an already answered Aggregator or use the recommended latestRoundData
   * instead which includes better verification information.
   */
  function latestRound()
    public
    view
    virtual
    override
    returns (uint256)
  {
    return latestRoundId;
  }

  /**
   * @notice get past rounds answers
   * @param roundId the round number to retrieve the answer for
   *
   * @dev #[deprecated] Use getRoundData instead. This does not error if no
   * answer has been reached, it will simply return 0. Either wait to point to
   * an already answered Aggregator or use the recommended getRoundData
   * instead which includes better verification information.
   */
  function getAnswer(uint256 roundId)
    public
    view
    virtual
    override
    returns (int256)
  {
    if (validRoundId(roundId)) {
      return rounds[uint32(roundId)].answer;
    }
    return 0;
  }

  /**
   * @notice get timestamp when an answer was last updated
   * @param roundId the round number to retrieve the updated timestamp for
   *
   * @dev #[deprecated] Use getRoundData instead. This does not error if no
   * answer has been reached, it will simply return 0. Either wait to point to
   * an already answered Aggregator or use the recommended getRoundData
   * instead which includes better verification information.
   */
  function getTimestamp(uint256 roundId)
    public
    view
    virtual
    override
    returns (uint256)
  {
    if (validRoundId(roundId)) {
      return rounds[uint32(roundId)].updatedAt;
    }
    return 0;
  }

  /**
   * @notice get data about a round. Consumers are encouraged to check
   * that they're receiving fresh data by inspecting the updatedAt and
   * answeredInRound return values.
   * @param roundId the round ID to retrieve the round data for
   * @return id is the round ID for which data was retrieved
   * @return answer is the answer for the given round
   * @return startedAt is the timestamp when the round was started. This is 0
   * if the round hasn't been started yet.
   * @return updatedAt is the timestamp when the round last was updated (i.e.
   * answer was last computed)
   * @return answeredInRound is the round ID of the round in which the answer
   * was computed. answeredInRound may be smaller than roundId when the round
   * timed out. answeredInRound is equal to roundId when the round didn't time out
   * and was completed regularly.
   * @dev Note that for in-progress rounds (i.e. rounds that haven't yet received
   * maxSubmissions) answer and updatedAt may change between queries.
   */
  function getRoundData(uint80 roundId)
    public
    view
    virtual
    override
    returns (
      uint80 id,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    )
  {
    Round memory r = rounds[uint32(roundId)];

    require(r.answeredInRound > 0 && validRoundId(roundId), V3_NO_DATA_ERROR);

    return (
      roundId,
      r.answer,
      r.startedAt,
      r.updatedAt,
      r.answeredInRound
    );
  }

  /**
   * @notice get data about the latest round. Consumers are encouraged to check
   * that they're receiving fresh data by inspecting the updatedAt and
   * answeredInRound return values. Consumers are encouraged to
   * use this more fully featured method over the "legacy" latestRound/
   * latestAnswer/latestTimestamp functions. Consumers are encouraged to check
   * that they're receiving fresh data by inspecting the updatedAt and
   * answeredInRound return values.
   * @return id is the round ID for which data was retrieved
   * @return answer is the answer for the given round
   * @return startedAt is the timestamp when the round was started. This is 0
   * if the round hasn't been started yet.
   * @return updatedAt is the timestamp when the round last was updated (i.e.
   * answer was last computed)
   * @return answeredInRound is the round ID of the round in which the answer
   * was computed. answeredInRound may be smaller than roundId when the round
   * timed out. answeredInRound is equal to roundId when the round didn't time
   * out and was completed regularly.
   * @dev Note that for in-progress rounds (i.e. rounds that haven't yet
   * received maxSubmissions) answer and updatedAt may change between queries.
   */
   function latestRoundData()
    public
    view
    virtual
    override
    returns (
      uint80 id,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    )
  {
    return getRoundData(latestRoundId);
  }


  /**
   * @notice query the available amount of LINK for an oracle to withdraw
   */
  function withdrawablePayment(address oracleAddress)
    external
    view
    returns (uint256)
  {
    return oracles[oracleAddress].withdrawable;
  }

  /**
   * @notice transfers the oracle's LINK to another address. Can only be called
   * by the oracle's admin.
   * @param oracleAddress is the oracle whose LINK is transferred
   * @param recipientAddress is the address to send the LINK to
   * @param linkAmount is the amount of LINK to send
   */
  function withdrawPayment(address oracleAddress, address recipientAddress, uint256 linkAmount)
    external
  {
    require(oracles[oracleAddress].admin == msg.sender, "only callable by admin");

    // Safe to downcast linkAmount because the total amount of LINK is less than 2^128.
    uint128 amount = uint128(linkAmount);
    uint128 available = oracles[oracleAddress].withdrawable;
    require(available >= amount, "insufficient withdrawable funds");

    oracles[oracleAddress].withdrawable = available.sub(amount);
    recordedFunds.allocated = recordedFunds.allocated.sub(amount);

    assert(linkToken.transfer(recipientAddress, uint256(amount)));
  }

  /**
   * @notice transfers the owner's LINK to another address
   * @param recipientAddress is the address to send the LINK to
   * @param linkAmount is the amount of LINK to send
   */
  function withdrawFunds(address recipientAddress, uint256 linkAmount)
    external
    onlyOwner()
  {
    uint256 available = uint256(recordedFunds.available);
    require(available.sub(requiredReserve(paymentAmount)) >= linkAmount, "insufficient reserve funds");
    require(linkToken.transfer(recipientAddress, linkAmount), "token transfer failed");
    updateAvailableFunds();
  }

  /**
   * @notice get the admin address of an oracle
   * @param oracleAddress is the address of the oracle whose admin is being queried
   */
  function getAdmin(address oracleAddress)
    external
    view
    returns (address)
  {
    return oracles[oracleAddress].admin;
  }

  /**
   * @notice transfer the admin address for an oracle
   * @param oracleAddress is the address of the oracle whose admin is being transferred
   * @param newAdminAddress is the new admin address
   */
  function transferAdmin(address oracleAddress, address newAdminAddress)
    external
  {
    require(oracles[oracleAddress].admin == msg.sender, "only callable by admin");
    oracles[oracleAddress].pendingAdmin = newAdminAddress;

    emit OracleAdminUpdateRequested(oracleAddress, msg.sender, newAdminAddress);
  }

  /**
   * @notice accept the admin address transfer for an oracle
   * @param oracleAddress is the address of the oracle whose admin is being transferred
   */
  function acceptAdmin(address oracleAddress)
    external
  {
    require(oracles[oracleAddress].pendingAdmin == msg.sender, "only callable by pending admin");
    oracles[oracleAddress].pendingAdmin = address(0);
    oracles[oracleAddress].admin = msg.sender;

    emit OracleAdminUpdated(oracleAddress, msg.sender);
  }

  /**
   * @notice allows non-oracles to request a new round
   */
  function requestNewRound()
    external
    returns (uint80)
  {
    require(requesters[msg.sender].authorized, "not authorized requester");

    uint32 current = reportingRoundId;
    require(rounds[current].updatedAt > 0 || timedOut(current), "prev round must be supersedable");

    uint32 newRoundId = current.add(1);
    requesterInitializeNewRound(newRoundId);
    return newRoundId;
  }

  /**
   * @notice allows the owner to specify new non-oracles to start new rounds
   * @param requesterAddress is the address to set permissions for
   * @param isAuthorized is a boolean specifying whether they can start new rounds or not
   * @param delaySeconds is the number of rounds the requester must wait before starting another round
   */
  function setRequesterPermissions(address requesterAddress, bool isAuthorized, uint32 delaySeconds)
    external
    onlyOwner()
  {
    if (requesters[requesterAddress].authorized == isAuthorized) return;

    if (isAuthorized) {
      requesters[requesterAddress].authorized = isAuthorized;
      requesters[requesterAddress].delay = delaySeconds;
    } else {
      delete requesters[requesterAddress];
    }

    emit RequesterPermissionsSet(requesterAddress, isAuthorized, delaySeconds);
  }

  /**
   * @notice called through LINK's transferAndCall to update available funds
   * in the same transaction as the funds were transferred to the aggregator
   * @param data is mostly ignored. It is checked for length, to be sure
   * nothing strange is passed in.
   */
  function onTokenTransfer(address, uint256, bytes calldata data)
    external
  {
    require(data.length == 0, "transfer doesn't accept calldata");
    updateAvailableFunds();
  }

  /**
   * @notice a method to provide all current info oracles need. Intended only
   * only to be callable by oracles. Not for use by contracts to read state.
   * @param oracleAddress the address to look up information for.
   * @param queriedRoundId the round to query
   */
  function oracleRoundState(address oracleAddress, uint32 queriedRoundId)
    external
    view
    returns (
      bool eligibleToSubmit,
      uint32 roundId,
      int256 latestSubmission,
      uint64 startedAt,
      uint64 timeoutSeconds,
      uint128 availableFunds,
      uint8 numberOfOracles,
      uint128 linkPaymentAmount
    )
  {
    require(msg.sender == tx.origin, "off-chain reading only");

    if (queriedRoundId > 0) {
      Round storage round = rounds[queriedRoundId];
      RoundDetails storage details = details[queriedRoundId];
      return (
        eligibleForSpecificRound(oracleAddress, queriedRoundId),
        queriedRoundId,
        oracles[oracleAddress].latestSubmission,
        round.startedAt,
        details.timeout,
        recordedFunds.available,
        oracleCount(),
        (round.startedAt > 0 ? details.paymentAmount : paymentAmount)
      );
    } else {
      return oracleRoundStateSuggestRound(oracleAddress);
    }
  }

  /**
   * @notice method to update the address which does external data validation.
   * @param newValidatorAddress designates the address of the new validation contract.
   */
  function setValidator(address newValidatorAddress)
    public
    onlyOwner()
  {
    address previous = address(validator);

    if (previous != newValidatorAddress) {
      validator = AggregatorValidatorInterface(newValidatorAddress);

      emit ValidatorUpdated(previous, newValidatorAddress);
    }
  }


  /**
   * Private
   */

  function initializeNewRound(uint32 roundId)
    private
  {
    updateTimedOutRoundInfo(roundId.sub(1));

    reportingRoundId = roundId;
    RoundDetails memory nextDetails = RoundDetails(
      new int256[](0),
      maxSubmissionCount,
      minSubmissionCount,
      timeout,
      paymentAmount
    );
    details[roundId] = nextDetails;
    rounds[roundId].startedAt = uint64(block.timestamp);

    emit NewRound(roundId, msg.sender, rounds[roundId].startedAt);
  }

  function oracleInitializeNewRound(uint32 roundId)
    private
  {
    if (!newRound(roundId)) return;
    uint256 lastStarted = oracles[msg.sender].lastStartedRound; // cache storage reads
    if (roundId <= lastStarted + restartDelay && lastStarted != 0) return;

    initializeNewRound(roundId);

    oracles[msg.sender].lastStartedRound = roundId;
  }

  function requesterInitializeNewRound(uint32 roundId)
    private
  {
    if (!newRound(roundId)) return;
    uint256 lastStarted = requesters[msg.sender].lastStartedRound; // cache storage reads
    require(roundId > lastStarted + requesters[msg.sender].delay || lastStarted == 0, "must delay requests");

    initializeNewRound(roundId);

    requesters[msg.sender].lastStartedRound = roundId;
  }

  function updateTimedOutRoundInfo(uint32 roundId)
    private
  {
    if (!timedOut(roundId)) return;

    uint32 prevId = roundId.sub(1);
    rounds[roundId].answer = rounds[prevId].answer;
    rounds[roundId].answeredInRound = rounds[prevId].answeredInRound;
    rounds[roundId].updatedAt = uint64(block.timestamp);

    delete details[roundId];
  }

  function eligibleForSpecificRound(address oracleAddress, uint32 queriedRoundId)
    private
    view
    returns (bool eligible)
  {
    if (rounds[queriedRoundId].startedAt > 0) {
      return acceptingSubmissions(queriedRoundId) && validateOracleRound(oracleAddress, queriedRoundId).length == 0;
    } else {
      return delayed(oracleAddress, queriedRoundId) && validateOracleRound(oracleAddress, queriedRoundId).length == 0;
    }
  }

  function oracleRoundStateSuggestRound(address oracleAddress)
    private
    view
    returns (
      bool eligibleToSubmit,
      uint32 roundId,
      int256 latestSubmission,
      uint64 startedAt,
      uint64 timeoutSeconds,
      uint128 availableFunds,
      uint8 numberOfOracles,
      uint128 linkPaymentAmount
    )
  {
    Round storage round = rounds[0];
    OracleStatus storage oracle = oracles[oracleAddress];

    bool shouldSupersede = oracle.lastReportedRound == reportingRoundId || !acceptingSubmissions(reportingRoundId);
    // Instead of nudging oracles to submit to the next round, the inclusion of
    // the shouldSupersede bool in the if condition pushes them towards
    // submitting in a currently open round.
    if (supersedable(reportingRoundId) && shouldSupersede) {
      roundId = reportingRoundId.add(1);
      round = rounds[roundId];

      linkPaymentAmount = paymentAmount;
      eligibleToSubmit = delayed(oracleAddress, roundId);
    } else {
      roundId = reportingRoundId;
      round = rounds[roundId];

      linkPaymentAmount = details[roundId].paymentAmount;
      eligibleToSubmit = acceptingSubmissions(roundId);
    }

    if (validateOracleRound(oracleAddress, roundId).length != 0) {
      eligibleToSubmit = false;
    }

    return (
      eligibleToSubmit,
      roundId,
      oracle.latestSubmission,
      round.startedAt,
      details[roundId].timeout,
      recordedFunds.available,
      oracleCount(),
      linkPaymentAmount
    );
  }

  function updateRoundAnswer(uint32 roundId)
    internal
    returns (bool, int256)
  {
    if (details[roundId].submissions.length < details[roundId].minSubmissions) {
      return (false, 0);
    }

    int256 newAnswer = Median.calculateInplace(details[roundId].submissions);
    rounds[roundId].answer = newAnswer;
    rounds[roundId].updatedAt = uint64(block.timestamp);
    rounds[roundId].answeredInRound = roundId;
    latestRoundId = roundId;

    emit AnswerUpdated(newAnswer, roundId, block.timestamp);

    return (true, newAnswer);
  }

  function validateAnswer(
    uint32 roundId,
    int256 newAnswer
  )
    private
  {
    AggregatorValidatorInterface av = validator; // cache storage reads
    if (address(av) == address(0)) return;

    uint32 prevRound = roundId.sub(1);
    uint32 prevAnswerRoundId = rounds[prevRound].answeredInRound;
    int256 prevRoundAnswer = rounds[prevRound].answer;
    // We do not want the validator to ever prevent reporting, so we limit its
    // gas usage and catch any errors that may arise.
    try av.validate{gas: VALIDATOR_GAS_LIMIT}(
      prevAnswerRoundId,
      prevRoundAnswer,
      roundId,
      newAnswer
    ) {} catch {}
  }

  function payOracle(uint32 roundId)
    private
  {
    uint128 payment = details[roundId].paymentAmount;
    Funds memory funds = recordedFunds;
    funds.available = funds.available.sub(payment);
    funds.allocated = funds.allocated.add(payment);
    recordedFunds = funds;
    oracles[msg.sender].withdrawable = oracles[msg.sender].withdrawable.add(payment);

    emit AvailableFundsUpdated(funds.available);
  }

  function recordSubmission(int256 submission, uint32 roundId)
    private
  {
    require(acceptingSubmissions(roundId), "round not accepting submissions");

    details[roundId].submissions.push(submission);
    oracles[msg.sender].lastReportedRound = roundId;
    oracles[msg.sender].latestSubmission = submission;

    emit SubmissionReceived(submission, roundId, msg.sender);
  }

  function deleteRoundDetails(uint32 roundId)
    private
  {
    if (details[roundId].submissions.length < details[roundId].maxSubmissions) return;

    delete details[roundId];
  }

  function timedOut(uint32 roundId)
    private
    view
    returns (bool)
  {
    uint64 startedAt = rounds[roundId].startedAt;
    uint32 roundTimeout = details[roundId].timeout;
    return startedAt > 0 && roundTimeout > 0 && startedAt.add(roundTimeout) < block.timestamp;
  }

  function getStartingRound(address oracleAddress)
    private
    view
    returns (uint32)
  {
    uint32 currentRound = reportingRoundId;
    if (currentRound != 0 && currentRound == oracles[oracleAddress].endingRound) {
      return currentRound;
    }
    return currentRound.add(1);
  }

  function previousAndCurrentUnanswered(uint32 roundId, uint32 rrId)
    private
    view
    returns (bool)
  {
    return roundId.add(1) == rrId && rounds[rrId].updatedAt == 0;
  }

  function requiredReserve(uint256 payment)
    private
    view
    returns (uint256)
  {
    return payment.mul(oracleCount()).mul(RESERVE_ROUNDS);
  }

  function addOracle(
    address oracleAddress,
    address adminAddress
  )
    private
  {
    require(!oracleEnabled(oracleAddress), "oracle already enabled");

    require(adminAddress != address(0), "cannot set admin to 0");
    require(oracles[oracleAddress].admin == address(0) || oracles[oracleAddress].admin == adminAddress, "owner cannot overwrite admin");

    oracles[oracleAddress].startingRound = getStartingRound(oracleAddress);
    oracles[oracleAddress].endingRound = ROUND_MAX;
    oracles[oracleAddress].index = uint16(oracleAddresses.length);
    oracleAddresses.push(oracleAddress);
    oracles[oracleAddress].admin = adminAddress;

    emit OraclePermissionsUpdated(oracleAddress, true);
    emit OracleAdminUpdated(oracleAddress, adminAddress);
  }

  function removeOracle(
    address oracleAddress
  )
    private
  {
    require(oracleEnabled(oracleAddress), "oracle not enabled");

    oracles[oracleAddress].endingRound = reportingRoundId.add(1);
    address tail = oracleAddresses[uint256(oracleCount()).sub(1)];
    uint16 index = oracles[oracleAddress].index;
    oracles[tail].index = index;
    delete oracles[oracleAddress].index;
    oracleAddresses[index] = tail;
    oracleAddresses.pop();

    emit OraclePermissionsUpdated(oracleAddress, false);
  }

  function validateOracleRound(address oracleAddress, uint32 roundId)
    private
    view
    returns (bytes memory)
  {
    // cache storage reads
    uint32 startingRound = oracles[oracleAddress].startingRound;
    uint32 rrId = reportingRoundId;

    if (startingRound == 0) return "not enabled oracle";
    if (startingRound > roundId) return "not yet enabled oracle";
    if (oracles[oracleAddress].endingRound < roundId) return "no longer allowed oracle";
    if (oracles[oracleAddress].lastReportedRound >= roundId) return "cannot report on previous rounds";
    if (roundId != rrId && roundId != rrId.add(1) && !previousAndCurrentUnanswered(roundId, rrId)) return "invalid round to report";
    if (roundId != 1 && !supersedable(roundId.sub(1))) return "previous round not supersedable";
  }

  function supersedable(uint32 roundId)
    private
    view
    returns (bool)
  {
    return rounds[roundId].updatedAt > 0 || timedOut(roundId);
  }

  function oracleEnabled(address oracleAddress)
    private
    view
    returns (bool)
  {
    return oracles[oracleAddress].endingRound == ROUND_MAX;
  }

  function acceptingSubmissions(uint32 roundId)
    private
    view
    returns (bool)
  {
    return details[roundId].maxSubmissions != 0;
  }

  function delayed(address oracleAddress, uint32 roundId)
    private
    view
    returns (bool)
  {
    uint256 lastStarted = oracles[oracleAddress].lastStartedRound;
    return roundId > lastStarted + restartDelay || lastStarted == 0;
  }

  function newRound(uint32 roundId)
    private
    view
    returns (bool)
  {
    return roundId == reportingRoundId.add(1);
  }

  function validRoundId(uint256 roundId)
    private
    view
    returns (bool)
  {
    return roundId <= ROUND_MAX;
  }

}
