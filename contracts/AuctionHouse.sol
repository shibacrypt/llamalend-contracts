//SPDX-License-Identifier: None
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "./interfaces/ILendingPool.sol";
import "./libs/LinearCurve.sol";

/**
 * @dev Auction for selling of NFTs along a decreasing linear price curve
 *
 * The auction house is ran by a trusted party of the lending pool
 */
contract AuctionHouse is OwnableUpgradeable {
    using Address for address payable;
    using SafeCast for uint256;
    using SafeCast for int256;

    struct Auction {
        uint256 tokenId;
        uint256 startPrice;
        uint256 endPrice;
        uint256 startTime;
        uint256 endTime;
        bool isActive;
    }

    address public lendingPool;
    IERC721 public nftContract;
    uint256 public fee; // in bips
    mapping(uint256 => Auction) public auctions;

    /**
     * @dev Throws if called by any account other than the owner of the lending pool.
     */
    modifier onlyLendingPoolOwner() {
        require(msg.sender == ILendingPool(lendingPool).owner(), "caller is not the lending pool owner");
        _;
    }

    function initialize(address _lendingPool, uint256 _fee) public initializer {
        require(_lendingPool != address(0), "lendingPool is zero address");
        require(_fee <= 5000, "fee greater than 5000"); // 50%

        __Ownable_init();
        lendingPool = _lendingPool;
        nftContract = ILendingPool(_lendingPool).nftContract();
        fee = _fee;
    }

    /**
     * @dev Deposits NFT from the lending pool and start an auction immediately
     */
    function depositAndStartAuction(
        ILendingPool.Loan calldata _loan,
        uint256 _startPrice,
        uint256 _endPrice,
        uint256 _endTime
    ) external onlyOwner {
        deposit(_loan);
        startAuction(uint256(_loan.nft), _startPrice, _endPrice, _endTime);
    }

    /**
     * @dev Deposits NFT from the lending pool and schedule an auction
     */
    function depositAndScheduleAuction(
        ILendingPool.Loan calldata _loan,
        uint256 _startPrice,
        uint256 _endPrice,
        uint256 _startTime,
        uint256 _endTime
    ) external onlyOwner {
        deposit(_loan);
        scheduleAuction(uint256(_loan.nft), _startPrice, _endPrice, _startTime, _endTime);
    }

    /**
     * @dev Start an auction immediately
     */
    function startAuction(uint256 _tokenId, uint256 _startPrice, uint256 _endPrice, uint256 _endTime)
        public
        onlyOwner
    {
        scheduleAuction(_tokenId, _startPrice, _endPrice, block.timestamp, _endTime);
    }

    /**
     * @dev Schedule an auction
     */
    function scheduleAuction(
        uint256 _tokenId,
        uint256 _startPrice,
        uint256 _endPrice,
        uint256 _startTime,
        uint256 _endTime
    ) public onlyOwner {
        require(auctions[_tokenId].startTime == 0 || auctions[_tokenId].isActive, "auction active");
        require(_startTime >= block.timestamp && _endTime > _startTime, "invalid time");
        require(_endPrice <= _startPrice, "invalid price");
        require(nftContract.ownerOf(_tokenId) == address(this), "invalid tokenId");

        auctions[_tokenId] = Auction(_tokenId, _startPrice, _endPrice, _startTime, _endTime, false);
    }

    /**
     * @dev End an auction
     */
    function endAuction(uint256 _tokenId) external onlyOwner {
        require(auctions[_tokenId].startTime > 0 && !auctions[_tokenId].isActive, "auction inactive");

        auctions[_tokenId].isActive = true;
    }

    /**
     * @dev Bids an auction at spot price
     *
     * Bidder receives the NFT, liquidator gets ETH fee, owner of lending pool gets the rest
     */
    function buy(uint256 _tokenId) external payable returns (uint256) {
        Auction memory auction = auctions[_tokenId];
        require(
            block.timestamp >= auction.startTime && block.timestamp <= auction.endTime && !auction.isActive,
            "auction inactive"
        );

        uint256 price = getSpotPrice(_tokenId);
        require(price > 0 && price <= auction.startPrice && price >= auction.endPrice, "invalid price");
        require(msg.value >= price, "insufficient ETH sent");
        require(nftContract.ownerOf(_tokenId) == address(this), "invalid tokenId");

        auctions[_tokenId].isActive = true;
        uint256 fees = price * fee / 10000;
        if (msg.value > price) {
            _refundExcess(msg.value - price);
        }
        _takeFee(fees);
        _takeProfit(price - fees);

        nftContract.transferFrom(address(this), msg.sender, auction.tokenId);
        return price;
    }

    /**
     * @dev Withdraws NFT back to the lending pool
     *
     * Owner of the lending pool can forcefully withdraw any NFTs
     */
    function withdraw(uint256 _tokenId) external onlyLendingPoolOwner {
        if (auctions[_tokenId].isActive) {
            auctions[_tokenId].isActive = false;
        }
        nftContract.transferFrom(address(this), ILendingPool(lendingPool).owner(), _tokenId);
    }

    /**
     * @dev Deposits NFT from the lending pool
     *
     * Liquidator (owner of this contract) must be added to the lending pool
     */
    function deposit(ILendingPool.Loan calldata _loan) public onlyOwner {
        ILendingPool(lendingPool).doEffectiveAltruism(_loan, address(this));
    }

    /**
     * @dev Set fee (in bips)
     */
    function setFee(uint256 _fee) external onlyOwner {
        require(_fee <= 5000, "fee greater than 5000"); // 50%
        fee = _fee;
    }

    /**
     * @dev Returns current price (positive) of auction along the curve
     *
     * X = time, Y = price
     * Auction-related assertions should be made independently
     */
    function getSpotPrice(uint256 _tokenId) public view returns (uint256) {
        Auction memory auction = auctions[_tokenId];
        uint256 price = LinearCurve.getY(
            (block.timestamp - auction.startTime).toInt256(),
            auction.startTime.toInt256(),
            auction.startPrice.toInt256(),
            auction.endTime.toInt256(),
            auction.endPrice.toInt256()
        ).toUint256();

        if (price < auction.endPrice) {
            return auction.endPrice;
        }
        if (price > auction.startPrice) {
            return auction.startPrice;
        }
        return price;
    }

    function _refundExcess(uint256 _amount) private {
        payable(msg.sender).sendValue(_amount);
    }

    function _takeFee(uint256 _amount) private {
        payable(owner()).sendValue(_amount);
    }

    function _takeProfit(uint256 _amount) private {
        payable(ILendingPool(lendingPool).owner()).sendValue(_amount);
    }
}
