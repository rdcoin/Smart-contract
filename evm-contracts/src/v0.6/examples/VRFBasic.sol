pragma solidity 0.6.6;

import "../VRFConsumerBase.sol";

/**
 * @notice A basic Chainlink VRF consumer which requests randomness,
 * then emits the result in a `RandomnessGenerated` event.
 */
contract VRFBasic is VRFConsumerBase {
    
    bytes32 internal s_keyHash;
    uint256 internal s_fee;

    uint256 public s_randomResult;

    event RandomnessGenerated(bytes32 indexed requestId, uint256 randomness);
    
    /**
     * @notice Constructor inherits VRFConsumerBase
     *
     * @dev NETWORK: KOVAN
     * @dev   Chainlink VRF Coordinator address: 0xdD3782915140c8f3b190B5D67eAc6dc5760C46E9
     * @dev   LINK token address:                0xa36085F69e2889c224210F603D836748e7dC0088
     * @dev   Key Hash:   0x6c3699283bda56ad74f6b855546325b68d482e983852a7a82979cc4807b641f4
     * @dev   Fee:        0.1 LINK (100000000000000000)
     *
     * @param vrfCoordinator address of the VRF Coordinator
     * @param link address of the LINK token
     * @param keyHash bytes32 representing the hash of the VRF job
     * @param fee uint256 fee to pay the VRF oracle
     */
    constructor(address vrfCoordinator, address link, bytes32 keyHash, uint256 fee)
        public
        VRFConsumerBase(vrfCoordinator, link)
    {
        s_keyHash = keyHash;
        s_fee = fee;
    }
    
    /**
     * @notice Requests randomness from a user-provided seed.
     * @dev This is only an example implementation and not necessarily suitable for mainnet.
     * @dev You must review your implementation details with extreme care.
     * @dev This contract should own enough LINK to pay the fee.
     *
     * @param userProvidedSeed uint256 unpredictable seed
     */
    function getRandomNumber(uint256 userProvidedSeed) public {
        require(LINK.balanceOf(address(this)) >= s_fee, "Not enough LINK to pay fee");
        requestRandomness(s_keyHash, s_fee, userProvidedSeed);
    }

    /**
     * @notice Callback function used by VRF Coordinator to return the random number
     * to this contract.
     * @dev This is where you can do something with the resulting randomness.
     * @dev The VRF Coordinator will only send this function verified responses.
     *
     * @param requestId bytes32
     * @param randomness The random result returned by the oracle
     */
    function fulfillRandomness(bytes32 requestId, uint256 randomness) internal override {
        s_randomResult = randomness;
        // Do something with randomness here!
        emit RandomnessGenerated(requestId, s_randomResult);
    }
}