pragma solidity 0.6.6;

import "./AccessControllerInterface.sol";
import "../Owned.sol";

/**
 * @title AccessControlProxy
 * @notice This proxy allows for the same accessController address to be set on
 * EACAggregatorProxys so that when a new access controller is created, it only
 * needs to be updated on this contract rather than on each proxy.
 * @dev Utilizes the propose/confirm workflow for safe updating
 */
contract AccessControlProxy is AccessControllerInterface, Owned {

  AccessControllerInterface public accessController;
  AccessControllerInterface public proposedAccessController;

  /**
   * @param _accessController The address of the access controller contract
   */
  constructor(address _accessController) public {
    setAccessController(_accessController);
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
    proposedAccessController = AccessControllerInterface(_accessController);
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
    accessController = AccessControllerInterface(_accessController);
  }
}
