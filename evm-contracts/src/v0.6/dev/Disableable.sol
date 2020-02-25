pragma solidity ^0.6.0;

import "../Owned.sol";

/**
 * @title Disableable
 * @notice Allows the owner to disable/enable the contract.
 * The contract is enabled by default.
 */
contract Disableable is Owned {

  bool public disabled;

  event Disabled();
  event Enabled();

  /**
   * @notice Disables the contract. This function is idempotent.
   * @dev Only emits an event if the disabled/enabled state was changed.
   */
  function disable()
    external
    onlyOwner()
  {
    if (!disabled) {
      disabled = true;
      emit Disabled();
    }
  }

  /**
   * @notice Enables the contract. This function is idempotent.
   * @dev Only emits an event if the disabled/enabled state was changed
   */
  function enable()
    external
    onlyOwner()
  {
    if (disabled) {
      disabled = false;
      emit Enabled();
    }
  }

  /**
   * @dev reverts when the contract is disabled
   */
  modifier onlyWhenEnabled() {
    require(!disabled, "Contract is disabled");
    _;
  }
}
