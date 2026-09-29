// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @dev A plain ERC-721 standing in for Talismans at its mainnet address. A
///      wrapper only uses the ERC-721 surface, so unit tests need nothing more;
///      the real token and its transfer validator are exercised by the fork suites.
contract MockTalismans is ERC721 {
    constructor() ERC721("Talismans", "TALISMAN") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}
