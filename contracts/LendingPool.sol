//SPDX-License-Identifier: None
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "./libs/ERC721A.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract LendingPool is Ownable, ERC721A {
    using Address for address payable;

    struct Loan {
        uint nft;
        uint interest;
        uint40 startTime; // safe until year 231,800
        uint216 borrowed; // would need to borrow 1e+47 ETH -> that much ETH doesnt even exist
    }

    IERC721 public immutable nftContract;
    uint256 public immutable maxLoanLength;
    uint256 public maxInterestPerEthPerSecond; // eg: 80% p.a. = 25367833587 ~ 0.8e18 / 1 years;
    uint256 public minimumInterest; // eg: 40% p.a. = 12683916793 ~ 0.4e18 / 1 years;
    address public immutable factory;
    uint256 public maxPrice;
    address public oracle;
    uint public totalBorrowed; // = 0;
    mapping(uint=>Loan) public loans;
    string private baseURI = "https://nft.llamalend.com/nft/";
    uint maxDailyBorrows; // IMPORTANT: an attacker can borrow up to 150% of this limit if they prepare beforehand
    uint216 currentDailyBorrows;
    uint40 lastUpdateDailyBorrows;
    address[] public liquidators;

    event Borrowed(uint currentDailyBorrows, uint newBorrowedAmount);
    event ReducedDailyBorrows(uint currentDailyBorrows, uint amountReduced);

    constructor(address _oracle, uint _maxPrice, address _nftContract,
        uint _maxDailyBorrows, string memory _name, string memory _symbol,
        uint _maxLoanLength, uint _maxInterestPerEthPerSecond, uint _minimumInterest, address _owner) ERC721A(_name, _symbol)
    {
        require(_oracle != address(0), "oracle can't be 0");
        oracle = _oracle;
        maxPrice = _maxPrice;
        nftContract = IERC721(_nftContract);
        maxDailyBorrows = _maxDailyBorrows;
        lastUpdateDailyBorrows = uint40(block.timestamp);
        maxLoanLength = _maxLoanLength;
        maxInterestPerEthPerSecond = _maxInterestPerEthPerSecond;
        minimumInterest = _minimumInterest;
        transferOwnership(_owner);
        factory = msg.sender;
    }

    function addDailyBorrows(uint216 toAdd) internal {
        uint elapsed = block.timestamp - lastUpdateDailyBorrows;
        uint toReduce = (maxDailyBorrows*elapsed)/(1 days);
        if(toReduce > currentDailyBorrows){
            currentDailyBorrows = toAdd;
        } else {
            currentDailyBorrows = uint216(currentDailyBorrows - toReduce) + toAdd;
        }
        require(currentDailyBorrows < maxDailyBorrows, "max daily borrow");
        lastUpdateDailyBorrows = uint40(block.timestamp);
        emit Borrowed(currentDailyBorrows, toAdd);
    }

    function _borrow(
        uint nftId,
        uint216 price,
        uint interest,
        uint index) internal {
        require(nftContract.ownerOf(nftId) == msg.sender, "not owner");
        loans[_nextTokenId() + index] = Loan(nftId, interest, uint40(block.timestamp), price);
        nftContract.transferFrom(msg.sender, address(this), nftId);
    }

    function calculateInterest(uint priceOfNextItems) internal view returns (uint interest) {
        uint borrowed = priceOfNextItems/2 + totalBorrowed;
        uint variableRate = (borrowed * maxInterestPerEthPerSecond) / (address(this).balance + totalBorrowed);
        return minimumInterest + variableRate;
    }

    function borrow(
        uint[] calldata nftId,
        uint216 price,
        uint256 deadline,
        uint256 maxInterest,
        uint8 v,
        bytes32 r,
        bytes32 s) external {
        checkOracle(price, deadline, v, r, s);
        uint length = nftId.length;
        uint borrowedNow = price * length;
        uint interest = calculateInterest(borrowedNow);
        require(interest <= maxInterest);
        for(uint i=0; i<length; i++){
            _borrow(nftId[i], price, interest, i);
        }
        totalBorrowed += borrowedNow;
        // it's okay to restrict borrowedNow to uint216 because we will send that amount in ETH, and that much ETH doesnt exist
        addDailyBorrows(uint216(borrowedNow));
        _mint(msg.sender, length);
        payable(msg.sender).sendValue(borrowedNow);
    }

    function _repay(uint loanId) internal returns (uint) {
        require(ownerOf(loanId) == msg.sender, "not owner");
        Loan storage loan = loans[loanId];
        uint borrowed = loan.borrowed;
        uint sinceLoanStart = block.timestamp - loan.startTime;
        uint interest = (sinceLoanStart * loan.interest * borrowed) / 1e18;
        if(sinceLoanStart > maxLoanLength){
            uint loanEnd = loan.startTime + maxLoanLength;
            interest += ((block.timestamp - loanEnd)*borrowed)/(1 days);
        }
        _burn(loanId);
        totalBorrowed -= borrowed;

        if(sinceLoanStart < (1 days)){
            uint until24h;
            unchecked {
                until24h = (1 days) - sinceLoanStart;
            }
            uint toReduce = (borrowed*until24h)/(1 days);
            if(toReduce < currentDailyBorrows){
                unchecked {
                    // toReduce < currentDailyBorrows always so it's fine to restrict to uint216 because currentDailyBorrows is uint216 already
                    currentDailyBorrows = currentDailyBorrows - uint216(toReduce);
                }
                emit ReducedDailyBorrows(currentDailyBorrows, toReduce);
            } else {
                emit ReducedDailyBorrows(0, currentDailyBorrows);
                currentDailyBorrows = 0;
            }
        }

        nftContract.transferFrom(address(this), msg.sender, loan.nft);
        return interest + borrowed;
    }

    function repay(uint[] calldata loanIds) external payable {
        uint length = loanIds.length;
        uint totalToRepay = 0;
        for(uint i=0; i<length; i++){
            totalToRepay += _repay(loanIds[i]);
        }
        payable(msg.sender).sendValue(msg.value - totalToRepay); // overflow checks implictly check that amount is enough
    }

    function claw(uint loanId, uint liquidatorIndex) external {
        require(liquidators[liquidatorIndex] == msg.sender);
        Loan storage loan = loans[loanId];
        require(_exists(loanId), "loan closed");
        require(block.timestamp > (loan.startTime + maxLoanLength), "not expired");
        _burn(loanId);
        totalBorrowed -= loan.borrowed;
        nftContract.transferFrom(address(this), msg.sender, loan.nft);
    }

    function setOracle(address newValue) external onlyOwner {
        require(newValue != address(0), "oracle can't be 0");
        oracle = newValue;
    }

    function setMaxDailyBorrows(uint _maxDailyBorrows) external onlyOwner {
        maxDailyBorrows = _maxDailyBorrows;
    }

    function deposit() external payable onlyOwner {}

    function withdraw(uint amount) external onlyOwner {
        payable(msg.sender).sendValue(amount);
    }

    function checkOracle(
        uint216 price,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public view {
        require(block.timestamp < deadline, "deadline over");
        require(
            ecrecover(
                keccak256(
                    abi.encodePacked(
                        "\x19Ethereum Signed Message:\n111",
                        price,
                        deadline,
                        block.chainid,
                        address(nftContract)
                    )
                ),
                v,
                r,
                s
            ) == oracle,
            "not oracle"
        );
        require(price < maxPrice, "max price");
    }

    function infoToRepayLoan(uint loanId) view external returns (uint deadline, uint totalRepay, uint principal, uint interest, uint lateFees){
        Loan storage loan = loans[loanId];
        deadline = loan.startTime + maxLoanLength;
        interest = ((block.timestamp - loan.startTime) * loan.interest * loan.borrowed) / 1e18;
        if(block.timestamp > deadline){
            lateFees = ((block.timestamp - deadline)*loan.borrowed)/(1 days);
        } else {
            lateFees = 0;
        }
        principal = loan.borrowed;
        totalRepay = principal + interest + lateFees;
    }

    function currentAnnualInterest(uint priceOfNextItem) external view returns (uint interest) {
        return calculateInterest(priceOfNextItem) * 365 days;
    }

    function getDailyBorrows() external view returns (uint maxInstantBorrow, uint dailyBorrows, uint maxDailyBorrowsLimit) {
        uint elapsed = block.timestamp - lastUpdateDailyBorrows;
        dailyBorrows = currentDailyBorrows - Math.min((maxDailyBorrows*elapsed)/(1 days), currentDailyBorrows);
        maxDailyBorrowsLimit = maxDailyBorrows;
        maxInstantBorrow = Math.min(address(this).balance, maxDailyBorrows - dailyBorrows);
    }

    function _baseURI() internal view override returns (string memory) {
        return string(abi.encodePacked(baseURI, Strings.toString(block.chainid), "/", Strings.toHexString(uint160(address(this)), 20), "/", Strings.toHexString(uint160(address(nftContract)), 20), "/"));
    }

    function setMaxPrice(uint newMaxPrice) external onlyOwner {
        maxPrice = newMaxPrice;
    }

    function changeInterest(uint _maxInterestPerEthPerSecond, uint _minimumInterest) external onlyOwner {
        maxInterestPerEthPerSecond = _maxInterestPerEthPerSecond;
        minimumInterest = _minimumInterest;
    }

    function addLiquidator(address liq) external onlyOwner {
        liquidators.push(liq);
    }

    function removeLiquidator(uint index) external onlyOwner {
        liquidators[index] = address(0);
    }

    function liquidatorsLength() external view returns (uint){
        return liquidators.length;
    }

    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        baseURI = newBaseURI;
    }

    function emergencyShutdown() external {
        require(msg.sender == factory);
        maxPrice = 0; // prevents new borrows
    }

    fallback() external {
        // money can still be received through self-destruct, which makes it possible to change balance without calling updateInterest, but if
        // owner does that -> they are lowering the money they earn through interest
        // debtor does that -> they always lose money because all loans are < 2 weeks
        revert();
    }
}
