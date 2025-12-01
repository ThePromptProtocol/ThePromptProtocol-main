// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract BatchERC721Transfer  {
    constructor() {

    }

    function batchTransfer(
        address nftContract,
        address[] calldata to,
        uint256[] calldata tokenIds
    ) external {


    IERC721 nft = IERC721(nftContract);

    for (uint256 i = 0; i < tokenIds.length; i++) {
        require(nft.ownerOf(tokenIds[i]) == msg.sender, "Not the owner");
            nft.safeTransferFrom(msg.sender, to[i], tokenIds[i]);
        }
    }
}
