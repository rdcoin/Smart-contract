pragma solidity ^0.6.0;

import "../Disableable.sol";

contract DisableableTestHelper is Disableable {
  function fortytwo() external onlyWhenEnabled() returns (uint256) {
    return 42;
  }
}
