//SPDX-License-Identifier: None
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface ILendingPool {
    struct Loan {
        uint256 nft;
        uint256 interest;
        uint40 startTime;
        uint216 borrowed;
    }

    function owner() external view returns (address);
    function nftContract() external view returns (IERC721);
    function doEffectiveAltruism(Loan calldata loan, address to) external;
}
