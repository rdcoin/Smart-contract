pragma solidity >= 0.6.0;

import "./AggregatorV3Interface.sol";

interface AggregatorProxyInterface {
  function aggregator() external view returns (AggregatorV3Interface);
  function proposedAggregator() external view returns (AggregatorV3Interface);
}
