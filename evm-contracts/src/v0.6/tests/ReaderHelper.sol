pragma solidity >=0.6.0;

import "../interfaces/AggregatorInterface.sol";

contract ReaderHelper {
  function readLatestAnswer(address _feed) external view returns (int256) {
    return AggregatorInterface(_feed).latestAnswer();
  }
}
