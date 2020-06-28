pragma solidity 0.6.6;

import "../Owned.sol";
import "../LinkTokenReceiver.sol";
import "../interfaces/LinkTokenInterface.sol";
import "../interfaces/AggregatorProxyInterface.sol";
import "../interfaces/AggregatorV3Interface.sol";
import "../vendor/SafeMath.sol";
import "./AccessControllerInterface.sol";

/**
 * @title AccessPerBlock
 * @notice This contract allows readers to pay for access to a feed for
 * a duration of time measured in blocks. Each feed can have its own
 * unique price and access will be granted by default if no price is set.
 */
contract AccessPerBlock is Owned, LinkTokenReceiver, AccessControllerInterface {
  using SafeMath for uint256;

  LinkTokenInterface immutable public LINK;
  AccessControllerInterface immutable public PREVIOUS;
  bool public acceptingPayments;
  AggregatorV3Interface public paymentPriceFeed;
  uint256 public staleRounds;
  uint256 public staleRoundDuration;
  uint256 public staleTimestamp;
  uint256 public maxBlocks;
  // Reader => Feed => Blocknumber
  mapping(address => mapping(address => uint256)) public accessUntilBlock;
  mapping(address => uint256) public pricePerBlock;

  event PaymentReceived(
    address indexed reader,
    address indexed feed,
    uint256 blocks
  );
  event PriceFeedSet(
    address indexed oldFeed,
    address indexed newFeed
  );
  event PriceSet(
    address indexed feed,
    uint256 indexed price
  );
  event PriceFeedTolerancesSet(
    uint256 staleRounds,
    uint256 staleRoundDuration,
    uint256 staleTimeout
  );
  event MaxBlocksSet(
    uint256 oldMaxBlocks,
    uint256 newMaxBlocks
  );
  event AcceptingPayments(
    bool acceptingPayments
  );

  /**
   * @param _link The LINK token address
   * @param _previousAccessController the previous access control
   * contract to fall back to when checking a reader's access
   * @param _paymentPriceFeed The contract containing the price
   * of LINK in which this contract will use to convert amounts
   * @param _maxBlocks The maximum amount of time a user can pay
   * for a reader to access a feed at once
   * @param _staleRounds The number of stale rounds the price
   * feed can report
   * @param _staleRoundDuration The length of time between a
   * round started on the price feed and when it was last updated
   * in the same round
   * @param _staleTimestamp The maximum amount of time since the
   * last update on the price feed
   * @param _acceptingPayments Switch to turn off allowing users
   * to pay for access
   */
  constructor(
    address _link,
    address _previousAccessController,
    address _paymentPriceFeed,
    uint256 _maxBlocks,
    uint256 _staleRounds,
    uint256 _staleRoundDuration,
    uint256 _staleTimestamp,
    bool _acceptingPayments
  )
    public
  {
    LINK = LinkTokenInterface(_link);
    PREVIOUS = AccessControllerInterface(_previousAccessController);
    setPaymentPriceFeed(_paymentPriceFeed);
    setMaxBlocks(_maxBlocks);
    setPriceFeedTolerances(_staleRounds, _staleRoundDuration, _staleTimestamp);
    setAcceptingPayments(_acceptingPayments);
  }

  /**
   * @notice Returns the access of an address for a specified feed. Uses the
   * following order of precedence:
   * 1. The _user has paid for access in this contract
   * 2. The querying address (the feed) does not have a price set
   * 3. The address to check (the _user) has access on the previous access
   * controller
   * 4. The check is being performed from off-chain
   * @param _feed The address of the feed which access is requested
   * @param _user The address to query
   * @param _data The bytes data included in the query (this is only
   * used to send to the previous access controller)
   * @return bool access
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
    return accessUntilBlock[_user][_feed] >= block.number
      || pricePerBlock[_feed] == 0
      || PREVIOUS.hasAccessTo(_feed, _user, _data)
      || _user == tx.origin;
  }

  /**
   * @notice Returns the access of an address. Uses the following order
   * of precedence:
   * 1. The _user has paid for access in this contract
   * 2. The querying address (the feed) does not have a price set
   * 3. The address to check (the _user) has access on the previous access
   * controller
   * 4. The check is being performed from off-chain
   * @param _user The address to query
   * @param _data The bytes data included in the query (this is only
   * used to send to the previous access controller)
   * @return bool access
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
   * @notice Get the maximum allowed payment for a given feed
   * by a user
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
    returns (uint256)
  {
    uint256 currentAccessBlock = accessUntilBlock[_reader][_feed];
    return currentAccessBlock < block.number
      ? getPaymentAmount(_feed, maxBlocks)
      : getPaymentAmount(_feed, maxBlocks.add(block.number)
                                         .sub(currentAccessBlock));
  }

  /**
   * @notice Get the amount of payment in LINK needed for the
   * specified feed and the number of blocks. Converts the
   * price of the feed with the current rate of LINK/USD to
   * determine the payment amount of LINK.
   * @param _feed The address of the feed for which access is being
   * paid for
   * @param _blocks The number of blocks to calculate the payment
   * @return uint256 The amount of LINK to pay for the given feed
   * and blocks
   */
  function getPaymentAmount(
    address _feed,
    uint256 _blocks
  )
    public
    view
    returns (uint256)
  {
    return pricePerBlock[_feed].mul(getMultiplier())
                               .div(getRate())
                               .mul(_blocks);
  }

  /**
   * @notice Triggered when the user pays for access with transferAndCall.
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
    require(acceptingPayments);
    (address reader, address feed) = abi.decode(_data, (address, address));
    uint256 priceUsd = pricePerBlock[feed];
    require(priceUsd > 0);
    uint256 currentAccessBlock = accessUntilBlock[reader][feed];
    uint256 blocks = priceUsd.mul(getMultiplier()).div(getRate());
    blocks = _amount.div(blocks);
    require(blocks > 0 && blocks <= maxBlocks &&
            blocks.add(currentAccessBlock) <= maxBlocks.add(block.number));
    accessUntilBlock[reader][feed] = currentAccessBlock < block.number
      ? blocks.add(block.number)
      : blocks.add(currentAccessBlock);
    address aggregator = address(AggregatorProxyInterface(feed).aggregator());
    LINK.transferAndCall(aggregator, _amount, "");
    emit PaymentReceived(reader, feed, blocks);
  }

  /**
   * @dev Converts the decimals of an aggregator to a multiplier.
   * Example: 8 decimals converts to 100000000.
   */
  function getMultiplier() internal view returns (uint256) {
    return 10 ** uint256(paymentPriceFeed.decimals());
  }

  /**
   * @dev Safely obtain the current LINK/USD rate from the price feed.
   * Utilizes configurable tolerances to ensure bad data is not
   * ingested. staleRounds if the answer was calculated in a previous
   * round and not the current round. staleRoundDuration, if the answer
   * has been calculated with new and old data. staleTimestamp if the
   * answer has not been updated for some period of time.
   * @return uint256 The current rate of LINK/USD
   */
  function getRate() internal view returns (uint256) {
    (
      uint256 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint256 answeredInRound
    ) = paymentPriceFeed.latestRoundData();
    require(answer > int256(0), "Invalid answer");
    require(roundId.sub(answeredInRound) <= staleRounds, "Answered in stale round");
    require(updatedAt.sub(startedAt) <= staleRoundDuration, "Round is stale");
    require(block.timestamp.sub(updatedAt) <= staleTimestamp, "Answer is stale");
    return uint256(answer);
  }

  /**
   * @notice Called by the owner to set tolerances for ingesting price
   * feed data.
   * @param _staleRounds The number of rounds that an answer can be
   * carried over from
   * @param _staleRoundDuration The difference between the time a round
   * started and when it was last updated
   * @param _staleTimestamp The time the latest answer was updated at
   */
  function setPriceFeedTolerances(
    uint256 _staleRounds,
    uint256 _staleRoundDuration,
    uint256 _staleTimestamp
  )
    public
    onlyOwner()
  {
    require(_staleRounds > 0
      && _staleRoundDuration > 0
      && _staleTimestamp > 0,
      "Can not set to zero");
    staleRounds = _staleRounds;
    staleRoundDuration = _staleRoundDuration;
    staleTimestamp = _staleTimestamp;
    emit PriceFeedTolerancesSet(_staleRounds, _staleRoundDuration, _staleTimestamp);
  }

  /**
   * @notice Called by the owner to set the address of the price feed
   * used to convert LINK/USD rates to LINK amounts
   * @param _paymentPriceFeed The address of the price feed
   */
  function setPaymentPriceFeed(
    address _paymentPriceFeed
  )
    public
    onlyOwner()
  {
    require(address(paymentPriceFeed) != _paymentPriceFeed, "Price feed already set to value");
    require(address(0) != _paymentPriceFeed, "Can not set to zero address");
    address oldPriceFeed = address(paymentPriceFeed);
    paymentPriceFeed = AggregatorV3Interface(_paymentPriceFeed);
    emit PriceFeedSet(oldPriceFeed, _paymentPriceFeed);
  }

  /**
   * @notice Called by the owner to set a price denominated in USD to
   * 8 decimals per feed. For example, $0.01 per block would be 1000000.
   * @param _feed The address of the feed which the price is being set for
   * @param _pricePerBlock The USD price per block for the feed
   */
  function setPricePerBlock(
    address _feed,
    uint256 _pricePerBlock
  )
    public
    onlyOwner()
  {
    require(pricePerBlock[_feed] != _pricePerBlock, "Price already set to value");
    pricePerBlock[_feed] = _pricePerBlock;
    emit PriceSet(_feed, _pricePerBlock);
  }

  /**
   * @notice Called by the owner to set the maximum number of blocks that
   * a user can pay for access for any feed.
   * @param _maxBlocks The number of blocks to set the maximum to
   */
  function setMaxBlocks(
    uint256 _maxBlocks
  )
    public
    onlyOwner()
  {
    require(maxBlocks != _maxBlocks, "Max blocks already set to value");
    uint256 oldMaxBlocks = maxBlocks;
    maxBlocks = _maxBlocks;
    emit MaxBlocksSet(oldMaxBlocks, _maxBlocks);
  }

  /**
   * @notice Called by the owner to flag that the contract is acceping
   * payments
   * @param _acceptingPayments Boolean to allow or disallow payments to
   * this contract
   */
  function setAcceptingPayments(
    bool _acceptingPayments
  )
    public
    onlyOwner()
  {
    require(acceptingPayments != _acceptingPayments, "Accepting payments already set");
    acceptingPayments = _acceptingPayments;
    emit AcceptingPayments(_acceptingPayments);
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
