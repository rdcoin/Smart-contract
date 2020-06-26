pragma solidity 0.6.6;

import "../Owned.sol";
import "../LinkTokenReceiver.sol";
import "../interfaces/LinkTokenInterface.sol";
import "../interfaces/AggregatorProxyInterface.sol";
import "../interfaces/AggregatorV3Interface.sol";
import "../vendor/SafeMath.sol";
import "./AccessControllerInterface.sol";

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

  function hasAccess(
    address _user,
    bytes memory _data
  )
    public
    view
    override
    returns (bool)
  {
    return accessUntilBlock[_user][msg.sender] >= block.number
      || pricePerBlock[msg.sender] == 0
      || PREVIOUS.hasAccess(_user, _data)
      || _user == tx.origin;
  }

  function getChainlinkToken()
    public
    view
    override
    returns (address)
  {
    return address(LINK);
  }

  function getMaxPayment(
    address _reader,
    address _feed
  )
    external
    view
    returns (uint256)
  {
    return accessUntilBlock[_reader][_feed] < block.number
      ? getPaymentAmount(_feed, maxBlocks)
      : getPaymentAmount(_feed, block.number.add(maxBlocks)
                                            .sub(accessUntilBlock[_reader][_feed]));
  }

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

  function getMultiplier() internal view returns (uint256) {
    return 10 ** uint256(paymentPriceFeed.decimals());
  }

  function getRate() internal view returns (uint256) {
    (
      uint256 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint256 answeredInRound
    ) = paymentPriceFeed.latestRoundData();
    require(roundId.sub(answeredInRound) <= staleRounds, "Answered in stale round");
    require(updatedAt.sub(startedAt) <= staleRoundDuration, "Round is stale");
    require(block.timestamp.sub(updatedAt) <= staleTimestamp, "Answer is stale");
    return uint256(answer);
  }

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
}
