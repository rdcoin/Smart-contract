pragma solidity ^0.6.0;

import "./AccessControllerInterface.sol";

interface AccessControllerPaymentInterface is AccessControllerInterface {
  function getMaxPayment(address reader, address feed) external view returns (uint256);
  function getPaymentAmount(address feed, uint256 unit) external view returns (uint256);
}
