// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ITalismanHost {
    function owner() external view returns (address);
    function coresOf(uint256 tokenId) external view returns (uint256[] memory);
}
