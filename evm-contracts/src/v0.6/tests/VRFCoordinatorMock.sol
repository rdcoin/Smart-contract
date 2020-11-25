pragma solidity 0.6.6;

import "../interfaces/LinkTokenInterface.sol";
import "../VRFConsumerBase.sol";

contract VRFCoordinatorMock {

	LinkTokenInterface public LINK;

	event RandomnessRequest(bytes32 keyHash, uint256 seed, uint256 fee, address sender);

	constructor(address linkAddress) public {
		LINK = LinkTokenInterface(linkAddress);
	}

	function onTokenTransfer(address sender, uint256 fee, bytes memory _data)
		public
		onlyLINK
	{
		(bytes32 keyHash, uint256 seed) = abi.decode(_data, (bytes32, uint256));
		emit RandomnessRequest(keyHash, seed, fee, sender);
	}

	function callBackWithRandomness(
		bytes32 requestId,
		uint256 randomness,
		address consumerContract
	) public {
		VRFConsumerBase v;
		bytes memory resp = abi.encodeWithSelector(
		v.rawFulfillRandomness.selector, requestId, randomness);
		uint256 b = 206000;
		require(gasleft() >= b, "not enough gas for consumer");
		(bool success,) = consumerContract.call(resp);
	}

	modifier onlyLINK() {
		require(msg.sender == address(LINK), "Must use LINK token");
		_;
	}
}