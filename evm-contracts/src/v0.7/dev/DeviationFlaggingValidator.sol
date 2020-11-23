pragma solidity 0.7.0;

import "./Owned.sol";
import "./CheckedMath.sol";
import "../interfaces/AggregatorValidatorInterface.sol";
import "../interfaces/FlagsInterface.sol";

/**
 * @title The Deviation Flagging Validator contract
 * @notice Checks the current value against the previous value, and makes sure
 * that it does not deviate outside of some relative range. If the deviation
 * threshold is passed then the validator raises a flag on the designated
 * flag contract.
 */
contract DeviationFlaggingValidator is Owned, AggregatorValidatorInterface {
  using CheckedMath for int256;

  uint32 constant public THRESHOLD_MULTIPLIER = 100000;

  uint32 public s_flaggingThreshold;
  FlagsInterface public s_flags;

  event FlaggingThresholdUpdated(
    uint24 indexed previous,
    uint24 indexed current
  );
  event FlagsAddressUpdated(
    address indexed previous,
    address indexed current
  );

  int256 constant private INT256_MIN = -2**255;

  /**
   * @notice sets up the validator with its threshold and flag address.
   * @param flagsAddress sets the address of the flags contract
   * @param threshold sets the threshold that will trigger a flag to be
   * raised. Setting the value of 100,000 is equivalent to tolerating a 100%
   * change compared to the previous price.
   */
  constructor(
    address flagsAddress,
    uint24 threshold
  )
    public
    Owned(msg.sender)
  {
    setFlagsAddress(flagsAddress);
    setFlaggingThreshold(threshold);
  }

  /**
   * @notice checks whether the parameters count as valid by comparing the
   * difference change to the flagging threshold.
   * @param previousRoundId is ignored.
   * @param previousAnswer is used as the median of the difference with the
   * current answer to determine if the deviation threshold has been exceeded.
   * @param roundId is ignored.
   * @param answer is the latest answer which is compared for a ratio of change
   * to make sure it has not execeeded the flagging threshold.
   */
  function validate(
    uint256 previousRoundId,
    int256 previousAnswer,
    uint256 roundId,
    int256 answer
  )
    external
    override
    returns (bool)
  {
    if (!isValid(previousRoundId, previousAnswer, roundId, answer)) {
      s_flags.raiseFlag(msg.sender);
      return false;
    }

    return true;
  }

  /**
   * @notice checks whether the parameters count as valid by comparing the
   * difference change to the flagging threshold and raises a flag on the
   * flagging contract if so.
   * @param previousAnswer is used as the median of the difference with the
   * current answer to determine if the deviation threshold has been exceeded.
   * @param answer is the current answer which is compared for a ratio of
   * change * to make sure it has not execeeded the flagging threshold.
   */
  function isValid(
    uint256 ,
    int256 previousAnswer,
    uint256 ,
    int256 answer
  )
    public
    view
    returns (bool)
  {
    if (previousAnswer == 0) return true;

    (int256 change, bool changeOk) = previousAnswer.sub(answer);
    (int256 ratioNumerator, bool numOk) = change.mul(THRESHOLD_MULTIPLIER);
    (int256 ratio, bool ratioOk) = ratioNumerator.div(previousAnswer);
    (uint256 absRatio, bool absOk) = abs(ratio);

    return changeOk && numOk && ratioOk && absOk && absRatio <= s_flaggingThreshold;
  }

  /**
   * @notice updates the flagging threshold
   * @param newThreshold sets the threshold that will trigger a flag to be
   * raised. Setting the value of 100,000 is equivalent to tolerating a 100%
   * change compared to the previous price.
   */
  function setFlaggingThreshold(uint24 newThreshold)
    public
    onlyOwner()
  {
    uint24 previousFT = uint24(s_flaggingThreshold);

    if (previousFT != newThreshold) {
      s_flaggingThreshold = newThreshold;

      emit FlaggingThresholdUpdated(previousFT, newThreshold);
    }
  }

  /**
   * @notice updates the flagging contract address for raising flags
   * @param flagsAddress sets the address of the flags contract
   */
  function setFlagsAddress(address flagsAddress)
    public
    onlyOwner()
  {
    address previous = address(s_flags);

    if (previous != flagsAddress) {
      s_flags = FlagsInterface(flagsAddress);

      emit FlagsAddressUpdated(previous, flagsAddress);
    }
  }


  // PRIVATE

  function abs(
    int256 value
  )
    private
    pure
    returns (uint256, bool)
  {
    if (value >= 0) return (uint256(value), true);
    if (value == CheckedMath.INT256_MIN) return (0, false);
    return (uint256(value * -1), true);
  }

}
