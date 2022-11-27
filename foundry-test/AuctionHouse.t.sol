// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../contracts/AuctionHouse.sol";
import "../contracts/LendingPool.sol";
import "../contracts/interfaces/ILendingPool.sol";
import "../contracts/mocks/MockNFT.sol";
import "./utils/SigUtils.sol";

contract AuctionHouseTest is Test {
    uint256 constant FEE = 1000; // 10%, in bips

    address owner = vm.addr(0x01);
    address lendingPoolOwner = vm.addr(0x02);
    address bidder = vm.addr(0x03);
    address borrower = vm.addr(0x04);
    uint256 lendingPoolOraclePrivateKey = 0x10;
    address lendingPoolOracle = vm.addr(lendingPoolOraclePrivateKey);

    AuctionHouse auctionHouse;
    LendingPool lendingPool;
    LendingPool.Interests lendingPoolInterests;
    MockNFT nft;
    SigUtils sigUtils;

    function setUp() public {
        nft = new MockNFT();
        sigUtils = new SigUtils();

        vm.startPrank(lendingPoolOwner);
        lendingPoolInterests = LendingPool.Interests(
            1, // maxVariableInterestPerEthPerSecond
            1, // minInterest
            0.5 ether // ltv
        );
        lendingPool = new LendingPool();
        lendingPool.initialize(
            lendingPoolOracle, // oracle
            10 ether, // maxPrice
            10 ether, // maxDailyBorrows
            "loan", // name
            "LOAN", // symbol
            lendingPoolInterests,
            lendingPoolOwner,
            address(nft),
            address(0), // factory
            100 // maxLoanLength
        );
        vm.stopPrank();

        vm.startPrank(owner);
        auctionHouse = new AuctionHouse();
        auctionHouse.initialize(address(lendingPool), FEE);
        vm.stopPrank();

        vm.prank(lendingPoolOwner);
        lendingPool.addLiquidator(address(auctionHouse));

        nft.mint(10, address(this)); // seed nft
        nft.transferFrom(address(this), address(auctionHouse), 1);
        nft.transferFrom(address(this), address(auctionHouse), 2);
        nft.transferFrom(address(this), address(auctionHouse), 3);
        nft.transferFrom(address(this), borrower, 4);
        nft.transferFrom(address(this), borrower, 5);

        vm.deal(bidder, 1000 ether); // seed ether balance
    }

    function test_Initialization() public {
        assertEq(auctionHouse.owner(), owner);
        assertEq(auctionHouse.lendingPool(), address(lendingPool));
        assertEq(address(auctionHouse.nftContract()), address(nft));
        assertEq(auctionHouse.fee(), FEE);
    }

    function test_InitializationRepeat() public {
        vm.expectRevert("Initializable: contract is already initialized");
        auctionHouse.initialize(address(lendingPool), FEE);
    }

    function test_InitializationInvalidFee() public {
        vm.startPrank(owner);
        LendingPool lendingPool2 = new LendingPool();
        lendingPool2.initialize(
            vm.addr(0x10),
            0,
            0,
            "loan",
            "LOAN",
            LendingPool.Interests(1, 1, 0.1 ether),
            owner,
            address(nft),
            address(0),
            0
        );
        AuctionHouse auctionHouse2 = new AuctionHouse();

        vm.expectRevert("fee greater than 5000");
        auctionHouse2.initialize(address(lendingPool), 5000 + 1);
        vm.stopPrank();
    }

    function test_StartAuction() public {
        vm.startPrank(owner);
        auctionHouse.startAuction(1, 10 ether, 5 ether, block.timestamp + 100);
        auctionHouse.startAuction(2, 100 ether, 50 ether, block.timestamp + 1000);
        vm.stopPrank();
        _assertAuction(1, 10 ether, 5 ether, block.timestamp, block.timestamp + 100, false);
        _assertAuction(2, 100 ether, 50 ether, block.timestamp, block.timestamp + 1000, false);
    }

    function test_StartClosedAuction() public {
        vm.startPrank(owner);
        vm.expectRevert("auction inactive");
        auctionHouse.endAuction(1);

        auctionHouse.startAuction(1, 10 ether, 5 ether, block.timestamp + 100);
        auctionHouse.endAuction(1);
        _assertAuction(1, 10 ether, 5 ether, block.timestamp, block.timestamp + 100, true);

        auctionHouse.startAuction(1, 100 ether, 50 ether, block.timestamp + 1000);
        vm.stopPrank();
        _assertAuction(1, 100 ether, 50 ether, block.timestamp, block.timestamp + 1000, false);
    }

    function testRevert_StartExistingAuction() public {
        vm.startPrank(owner);
        auctionHouse.startAuction(1, 10 ether, 5 ether, block.timestamp + 100);

        vm.expectRevert("auction active");
        auctionHouse.startAuction(1, 10 ether, 5 ether, block.timestamp + 100);
        vm.stopPrank();
    }

    function testRevert_StartAuctionWithInvalidParams() public {
        vm.expectRevert("Ownable: caller is not the owner");
        auctionHouse.startAuction(1, 10 ether, 5 ether, block.timestamp + 100);

        vm.startPrank(owner);
        vm.expectRevert("invalid tokenId");
        auctionHouse.startAuction(9, 10 ether, 5 ether, block.timestamp + 100);
        vm.expectRevert("ERC721: invalid token ID");
        auctionHouse.startAuction(99, 10 ether, 5 ether, block.timestamp + 100);
        vm.expectRevert("invalid price");
        auctionHouse.startAuction(1, 0 ether, 5 ether, block.timestamp + 100);
        vm.expectRevert("invalid price");
        auctionHouse.startAuction(1, 10 ether, 50 ether, block.timestamp + 100);
        vm.expectRevert("invalid time");
        auctionHouse.startAuction(1, 10 ether, 5 ether, block.timestamp - 1);
        vm.expectRevert("invalid time");
        auctionHouse.startAuction(1, 10 ether, 5 ether, 0);
        vm.stopPrank();
    }

    function testRevert_StartSameAuctionMoreThanOnce() public {
        vm.startPrank(owner);
        auctionHouse.startAuction(1, 10 ether, 5 ether, block.timestamp + 100);

        vm.expectRevert("auction active");
        auctionHouse.startAuction(1, 10 ether, 5 ether, block.timestamp + 100);
        vm.stopPrank();
    }

    function test_ScheduleAuction() public {
        vm.startPrank(owner);
        auctionHouse.scheduleAuction(1, 10 ether, 5 ether, block.timestamp + 1000, block.timestamp + 1100);
        auctionHouse.scheduleAuction(2, 100 ether, 50 ether, block.timestamp + 10000, block.timestamp + 11000);
        vm.stopPrank();
        _assertAuction(1, 10 ether, 5 ether, block.timestamp + 1000, block.timestamp + 1100, false);
        _assertAuction(2, 100 ether, 50 ether, block.timestamp + 10000, block.timestamp + 11000, false);
    }

    function testRevert_ScheduleAuctionWithInvalidParams() public {
        vm.expectRevert("Ownable: caller is not the owner");
        auctionHouse.scheduleAuction(1, 10 ether, 5 ether, block.timestamp + 1000, block.timestamp + 1100);

        vm.startPrank(owner);
        vm.expectRevert("invalid tokenId");
        auctionHouse.scheduleAuction(9, 10 ether, 5 ether, block.timestamp + 1000, block.timestamp + 1100);
        vm.expectRevert("ERC721: invalid token ID");
        auctionHouse.scheduleAuction(99, 10 ether, 5 ether, block.timestamp + 1000, block.timestamp + 1100);
        vm.expectRevert("invalid price");
        auctionHouse.scheduleAuction(1, 0 ether, 5 ether, block.timestamp + 1000, block.timestamp + 1100);
        vm.expectRevert("invalid price");
        auctionHouse.scheduleAuction(1, 10 ether, 50 ether, block.timestamp + 1000, block.timestamp + 1100);
        vm.expectRevert("invalid time");
        auctionHouse.scheduleAuction(1, 10 ether, 5 ether, block.timestamp - 1, block.timestamp + 1100);
        vm.expectRevert("invalid time");
        auctionHouse.scheduleAuction(1, 10 ether, 5 ether, 0, block.timestamp + 1100);
        vm.expectRevert("invalid time");
        auctionHouse.scheduleAuction(1, 10 ether, 5 ether, block.timestamp + 1000, block.timestamp - 1);
        vm.expectRevert("invalid time");
        auctionHouse.scheduleAuction(1, 10 ether, 5 ether, block.timestamp + 1000, 0);
        vm.stopPrank();
    }

    function test_BuyActiveAuction() public {
        vm.prank(bidder);
        vm.expectRevert("auction inactive");
        auctionHouse.buy{value: 10 ether}(1);

        vm.startPrank(owner);
        auctionHouse.startAuction(1, 10 ether, 5 ether, block.timestamp + 100);
        auctionHouse.startAuction(2, 10 ether, 5 ether, block.timestamp + 100);
        auctionHouse.startAuction(3, 10 ether, 5 ether, block.timestamp + 100);
        vm.stopPrank();

        vm.startPrank(bidder);
        auctionHouse.buy{value: 10 ether}(1); // price = 10, sufficient sent
        assertEq(bidder.balance, 990 ether); // spent 10
        assertEq(owner.balance, 1 ether); // received 1, on 10% fee
        assertEq(lendingPoolOwner.balance, 9 ether); // received 9, after 10% fee
        assertEq(nft.ownerOf(1), bidder);

        auctionHouse.buy{value: 11 ether}(2); // price = 10, surplus sent
        assertEq(bidder.balance, 980 ether); // spent 10
        assertEq(owner.balance, 2 ether); // received 1, on 10% fee
        assertEq(lendingPoolOwner.balance, 18 ether); // received 9, after 10% fee
        assertEq(nft.ownerOf(2), bidder);

        vm.warp(block.timestamp + 50);
        auctionHouse.buy{value: 7.5 ether}(3); // price = 7.5, sufficient sent
        assertEq(bidder.balance, 972.5 ether); // spent 7.5, sufficient sent
        assertEq(owner.balance, 2.75 ether); // received 0.75, on 10% fee
        assertEq(lendingPoolOwner.balance, 24.75 ether); // received 6.75, after 10% fee
        assertEq(nft.ownerOf(3), bidder);

        vm.expectRevert("auction inactive");
        auctionHouse.buy{value: 10 ether}(1);
        vm.expectRevert("auction inactive");
        auctionHouse.buy{value: 10 ether}(2);
        vm.expectRevert("auction inactive");
        auctionHouse.buy{value: 7.5 ether}(3);
        vm.stopPrank();
    }

    function testRevert_BuyClosedAuction() public {
        vm.prank(bidder);
        vm.expectRevert("auction inactive");
        auctionHouse.buy{value: 10 ether}(1);

        vm.startPrank(owner);
        auctionHouse.startAuction(1, 10 ether, 5 ether, block.timestamp + 100);
        auctionHouse.startAuction(2, 10 ether, 5 ether, block.timestamp + 100);
        auctionHouse.startAuction(3, 10 ether, 5 ether, block.timestamp + 100);
        vm.stopPrank();

        vm.startPrank(bidder);
        auctionHouse.buy{value: 10 ether}(1); // price = 10, sufficient sent
        vm.expectRevert("auction inactive");
        auctionHouse.buy{value: 10 ether}(1);

        auctionHouse.buy{value: 11 ether}(2); // price = 10, surplus sent
        vm.expectRevert("auction inactive");
        auctionHouse.buy{value: 10 ether}(2);

        vm.warp(block.timestamp + 50);
        auctionHouse.buy{value: 7.5 ether}(3); // price = 7.5, sufficient sent
        vm.expectRevert("auction inactive");
        auctionHouse.buy{value: 7.5 ether}(3);
        vm.stopPrank();
    }

    function test_Withdraw() public {
        vm.startPrank(lendingPoolOwner);
        auctionHouse.withdraw(1);
        auctionHouse.withdraw(2);
        auctionHouse.withdraw(3);
        vm.stopPrank();

        (,,,,, bool isActive1) = auctionHouse.auctions(1);
        (,,,,, bool isActive2) = auctionHouse.auctions(2);
        (,,,,, bool isActive3) = auctionHouse.auctions(3);
        assertEq(isActive1, false);
        assertEq(isActive2, false);
        assertEq(isActive3, false);
        assertEq(nft.ownerOf(1), lendingPoolOwner);
        assertEq(nft.ownerOf(2), lendingPoolOwner);
        assertEq(nft.ownerOf(3), lendingPoolOwner);
    }

    function testRevert_WithdrawInvalidCaller() public {
        vm.expectRevert("caller is not the lending pool owner");
        auctionHouse.withdraw(1);

        vm.prank(owner);
        vm.expectRevert("caller is not the lending pool owner");
        auctionHouse.withdraw(1);
    }

    function test_Deposit() public {
        ILendingPool.Loan[] memory loans = _setupLendingPool();
        assertEq(nft.ownerOf(4), address(lendingPool));
        assertEq(nft.ownerOf(5), address(lendingPool));

        vm.warp(block.timestamp + 1000); // past loan deadline

        vm.startPrank(owner);
        auctionHouse.deposit(loans[0]); // id = 4
        auctionHouse.deposit(loans[1]); // id = 5
        vm.stopPrank();
        assertEq(nft.ownerOf(4), address(auctionHouse));
        assertEq(nft.ownerOf(5), address(auctionHouse));
    }

    function test_DepositInvalidCaller() public {
        ILendingPool.Loan[] memory loans = _setupLendingPool();
        assertEq(nft.ownerOf(4), address(lendingPool));
        assertEq(nft.ownerOf(5), address(lendingPool));

        vm.warp(block.timestamp + 1000); // past loan deadline

        vm.expectRevert("Ownable: caller is not the owner");
        auctionHouse.deposit(loans[0]); // id = 4
    }

    function test_SetFee() public {
        vm.startPrank(owner);
        auctionHouse.setFee(100); // 1%
        assertEq(auctionHouse.fee(), 100);

        auctionHouse.setFee(1000); // 10%
        assertEq(auctionHouse.fee(), 1000);
        vm.stopPrank();
    }

    function test_SetFeeInvalidAmount() public {
        vm.prank(owner);
        vm.expectRevert("fee greater than 5000");
        auctionHouse.setFee(5001); // 50.01%
    }

    function test_SetFeeInvalidCaller() public {
        vm.expectRevert("Ownable: caller is not the owner");
        auctionHouse.setFee(100); // 1%
    }

    function test_SpotPrice() public {
        vm.prank(owner);
        // start price at 10, decrease to 5 over 100s
        // gradient is -0.05, so every second the price decreases by 0.05
        auctionHouse.startAuction(1, 10 ether, 5 ether, block.timestamp + 100);

        assertEq(auctionHouse.getSpotPrice(1), 10 ether);
        vm.warp(block.timestamp + 1);
        assertEq(auctionHouse.getSpotPrice(1), 9.95 ether);
        vm.warp(block.timestamp + 1);
        assertEq(auctionHouse.getSpotPrice(1), 9.9 ether);
        vm.warp(block.timestamp + 48);
        assertEq(auctionHouse.getSpotPrice(1), 7.5 ether);
        vm.warp(block.timestamp + 50);
        assertEq(auctionHouse.getSpotPrice(1), 5 ether);
        vm.warp(block.timestamp + 1); // exceed endTime
        assertEq(auctionHouse.getSpotPrice(1), 5 ether);
    }

    function _assertAuction(
        uint256 _tokenId,
        uint256 _startPrice,
        uint256 _endPrice,
        uint256 _startTime,
        uint256 _endTime,
        bool _isActive
    ) private {
        (uint256 tokenId, uint256 startPrice, uint256 endPrice, uint256 startTime, uint256 endTime, bool isActive) =
            auctionHouse.auctions(_tokenId);
        assertEq(tokenId, _tokenId);
        assertEq(startPrice, _startPrice);
        assertEq(endPrice, _endPrice);
        assertEq(startTime, _startTime);
        assertEq(endTime, _endTime);
        assertEq(isActive, _isActive);
        assertEq(nft.ownerOf(_tokenId), address(auctionHouse));
    }

    function _setupLendingPool() private returns (ILendingPool.Loan[] memory loan) {
        vm.deal(lendingPoolOwner, 10 ether); // seed ether balance
        vm.prank(lendingPoolOwner);
        uint256 initialDeposit = 5 ether;
        lendingPool.deposit{value: initialDeposit}();

        uint256[] memory nftIds = new uint256[](2);
        nftIds[0] = 4;
        nftIds[1] = 5;
        uint256 price = 1 ether;
        uint256 totalToBorrow = uint256(price) * nftIds.length * lendingPoolInterests.ltv / 1 ether; // ltv = 0.5

        uint256 deadline = block.timestamp + 100;
        bytes32 digest = sigUtils.getDigest(uint216(price), deadline, address(nft), block.chainid);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(lendingPoolOraclePrivateKey, digest); // signed by oracle

        vm.startPrank(borrower);
        nft.setApprovalForAll(address(lendingPool), true);
        lendingPool.borrow(nftIds, uint216(price), deadline, 1 ether, totalToBorrow, v, r, s);
        vm.stopPrank();

        ILendingPool.Loan[] memory loans = new ILendingPool.Loan[](2);
        loans[0] = _generateLoan(4, totalToBorrow, 0, initialDeposit, price, lendingPoolInterests.ltv);
        loans[1] = _generateLoan(5, totalToBorrow, 0, initialDeposit, price, lendingPoolInterests.ltv);
        return loans;
    }

    function _generateLoan(
        uint256 nftId,
        uint256 totalToBorrow,
        uint256 totalBorrowedBeforeLoan,
        uint256 lendingPoolEthBalanceBeforeLoan,
        uint256 price,
        uint256 ltv
    ) private view returns (ILendingPool.Loan memory) {
        return ILendingPool.Loan(
            nftId,
            _calculateInterest(totalToBorrow, totalBorrowedBeforeLoan, lendingPoolEthBalanceBeforeLoan),
            uint40(block.timestamp),
            uint216((price * ltv) / 1e18)
        );
    }

    function _calculateInterest(
        uint256 priceOfNextItems,
        uint256 totalBorrowedBeforeLoan,
        uint256 lendingPoolEthBalanceBeforeLoan
    ) private view returns (uint256) {
        uint256 borrowed = priceOfNextItems / 2 + totalBorrowedBeforeLoan;
        uint256 variableRate = (borrowed * lendingPoolInterests.maxVariableInterestPerEthPerSecond)
            / (lendingPoolEthBalanceBeforeLoan + totalBorrowedBeforeLoan);
        return lendingPoolInterests.minimumInterest + variableRate;
    }
}
