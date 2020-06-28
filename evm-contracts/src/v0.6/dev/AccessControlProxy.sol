pragma solidity 0.6.6;

import "./AccessControllerPaymentInterface.sol";
import "../interfaces/LinkTokenInterface.sol";
import "../LinkTokenReceiver.sol";
import "../Owned.sol";

/**
 * @title AccessControlProxy
 * @notice This proxy allows for the same accessController address to be set on
 * EACAggregatorProxys so that when a new access controller is created, it only
 * needs to be updated on this contract rather than on each proxy. Users of
 * reference data can pay for access at this contract's address instead of
 * having to look up the latest address of the access controller contract.
 * @dev Utilizes the propose/confirm workflow for safe updating
 */
contract AccessControlProxy is AccessControllerPaymentInterface, Owned, LinkTokenReceiver {

  LinkTokenInterface immutable public LINK;
  AccessControllerPaymentInterface public accessController;
  AccessControllerPaymentInterface public proposedAccessController;

  /**
   * @param _link The LINK token address
   * @param _accessController The address of the access controller contract
   */
  constructor(
    address _link,
    address _accessController
  )
    public
  {
    LINK = LinkTokenInterface(_link);
    setAccessController(_accessController);
  }

  /**
   * @notice Gets the Chainlink token address
   * @return address of the LINK token
   */
  function getChainlinkToken()
    public
    view
    override
    returns (address)
  {
    return address(LINK);
  }

  /**
   * @notice Returns the access of an address
   * @dev Will fill in the msg.sender for the feed address if called
   * @param _user The address to query
   * @param _data The bytes data included in the query (this is only
   */
  function hasAccess(
    address _user,
    bytes calldata _data
  )
    external
    view
    override
    returns (bool)
  {
    return hasAccessTo(msg.sender, _user, _data);
  }

  /**
   * @notice Returns the access of an address for a given feed
   * @param _feed The address of the feed which access is requested
   * @param _user The address to query
   * @param _data The bytes data included in the query (this is only
   */
  function hasAccessTo(
    address _feed,
    address _user,
    bytes memory _data
  )
    public
    view
    override
    returns (bool)
  {
    return accessController.hasAccessTo(_feed, _user, _data);
  }

  /**
   * @notice Get the maximum allowed payment for a given feed
   * by a user on the accessController contract
   * @param _reader The address to have access
   * @param _feed The address of the feed for which access is being
   * paid for
   * @return uint256 The amount of LINK to pay for the maximum
   * amount of access time
   */
  function getMaxPayment(
    address _reader,
    address _feed
  )
    external
    view
    override
    returns (uint256)
  {
    return accessController.getMaxPayment(_reader, _feed);
  }

  /**
   * @notice Get the amount of payment in LINK needed for the
   * specified feed and the number of blocks. Converts the
   * price of the feed with the current rate of LINK/USD to
   * determine the payment amount of LINK.
   * @param _feed The address of the feed for which access is being
   * paid for
   * @param _unit The number of units to calculate the payment
   * @return uint256 The amount of LINK to pay for the given feed
   * and blocks
   */
  function getPaymentAmount(
    address _feed,
    uint256 _unit
  )
    external
    view
    override
    returns (uint256)
  {
    return accessController.getPaymentAmount(_feed, _unit);
  }

  /**
   * @notice Triggered when the user pays for access with transferAndCall.
   * Calls transferAndCall on the accessController contract.
   * This will determine the current rate of LINK/USD and ensure that the
   * reader does not gain access longer than the maximum number of blocks
   * allowed. Upon payment, immediately funds the aggregator contract.
   * @dev The feed in the data payload must be that of a proxy, not the
   * implementation of the aggregator itself.
   * @param _amount The LINK payment amount
   * @param _data The data payload of the payment. Must be encoded as
   * ['address', 'address'] where the first address is the reader to gain
   * access and the second address is the feed (the proxy)
   */
  function onTokenTransfer(
    address,
    uint256 _amount,
    bytes memory _data
  )
    public
    override
    onlyLINK()
  {
    LINK.transferAndCall(address(accessController), _amount, _data);
  }

  /**
   * @notice Returns the access of an address on the proposed access controller
   * @dev Will fill in the msg.sender for the feed address if called
   * @param _user The address to query
   * @param _data The bytes data included in the query (this is only
   */
  function proposedHasAccess(
    address _user,
    bytes calldata _data
  )
    external
    view
    returns (bool)
  {
    return proposedHasAccessTo(msg.sender, _user, _data);
  }

  /**
   * @notice Returns the access of an address for a given feed on the proposed
   * access controller
   * @param _feed The address of the feed which access is requested
   * @param _user The address to query
   * @param _data The bytes data included in the query (this is only
   */
  function proposedHasAccessTo(
    address _feed,
    address _user,
    bytes memory _data
  )
    public
    view
    returns (bool)
  {
    return proposedAccessController.hasAccessTo(_feed, _user, _data);
  }


  /**
   * @notice Allows the owner to propose a new address for the access controller
   * @dev Reverts if the given address is already the access controller
   * @param _accessController The new address for the access controller contract
   */
  function proposeAccessController(
    address _accessController
  )
    external
    onlyOwner()
  {
    require(_accessController != address(accessController), "Must be different address");
    proposedAccessController = AccessControllerPaymentInterface(_accessController);
  }

  /**
   * @notice Allows the owner to confirm and change the address to the proposed
   * access controller
   * @dev Reverts if the given address does not match what was previously
   * proposed
   * @param _accessController The new address for the access controller contract
   */
  function confirmAccessController(
    address _accessController
  )
    external
    onlyOwner()
  {
    require(_accessController == address(proposedAccessController), "Invalid accessController");
    delete proposedAccessController;
    setAccessController(_accessController);
  }

  function setAccessController(
    address _accessController
  )
    internal
  {
    accessController = AccessControllerPaymentInterface(_accessController);
  }

  /**
   * @notice Called by the owner to withdraw LINK sent directly to
   * this contract without using transferAndCall.
   * @dev When the contract is used as intended, LINK shouldn't be
   * present on this contract. However, this allows user funds to
   * be recovered in case they accidentally send LINK without
   * transferAndCall.
   * @param _to The address to send the LINK to
   * @param _amount The amount to send
   */
  function withdraw(
    address _to,
    uint256 _amount
  )
    external
    onlyOwner()
  {
    require(LINK.transfer(_to, _amount), "LINK transfer failed");
  }
}
