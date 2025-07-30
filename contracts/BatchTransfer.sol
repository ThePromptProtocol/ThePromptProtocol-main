// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract BatchERC721Transfer is Ownable {
    bool public paused;

    constructor() {
        paused = false;
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }

    function batchTransfer(
        address nftContract,
        address from,
        address to,
        uint256[] calldata tokenIds
    ) external {
        require(!paused, "Contract is paused");
        require(from != address(0) && to != address(0), "Invalid address");
        
        IERC721 nft = IERC721(nftContract);
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(nft.ownerOf(tokenIds[i]) == from, "Not the owner");
            nft.safeTransferFrom(from, to, tokenIds[i]);
        }
    }
}
