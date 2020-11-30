pragma solidity 0.7.0;

import "./Owned.sol";
import "../interfaces/OracleInterface.sol";
import "./LinkTokenReceiver.sol";

contract OperatorProxy is Owned {

  constructor() Owned(msg.sender) {}

  function forward(address _to, bytes calldata _data) public
  {
    require(OracleInterface(owner).isAuthorizedSender(msg.sender), "Not an authorized node");
    require(_to != LinkTokenReceiver(owner).getChainlinkToken(), "Cannot send to Link token");
    (bool status,) = _to.call(_data);
    require(status, "Forwarded call failed.");
  }
}