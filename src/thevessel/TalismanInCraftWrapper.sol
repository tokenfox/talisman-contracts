// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface IVessel {
    function claim(address to, uint256[] calldata tokenIds, bytes calldata payload, address machine) external payable;
    function setRole(uint8 role) external;
    function setDelegate(uint256 tokenId, address delegate) external;
    function setPayloadHolder(uint256 tokenId, bytes calldata payload) external;
    function transferFrom(address from, address to, uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
    function craftToClaimed(uint256 tokenId) external view returns (bool);
    function craftToDelegate(uint256 tokenId) external view returns (address);
    function craftToLocked(uint256 tokenId) external view returns (bool);
    function craftToMachineStatus(uint256 tokenId) external view returns (bool);
    function craftToVaultStatus(uint256 tokenId) external view returns (bool);
    function relics() external view returns (address);
}

interface IRelics {
    function isRelic(uint256 tokenId) external view returns (bool);
}

/// @title TalismanInCraftWrapper
/// @notice Holds one Talisman wrapped in a craft of The Vessel until the craft's holder unwraps it.
contract TalismanInCraftWrapper {
    IERC721 public constant TALISMANS = IERC721(0x724D5bEffe9A84a87AD1Af83713F80600E5f5774);
    IVessel public constant VESSEL = IVessel(0xECb92Cc7112b80A2234936315BbB493fb48d1463);

    uint8 private constant STEWARD = 2;

    uint256 public talismanId;
    uint256 public craftId;
    bool public unwrapped;

    error NotCapsule();
    error WrongImageLength();
    error NotCraftOwner();
    error WrapperNotDelegate();
    error CraftLocked();
    error UnexpectedPayment();
    error AlreadyUnwrapped();

    /**
     * @notice Wraps your Talisman in a Capsule craft of The Vessel, writing an image and this wrapper's address into
     *         the craft. An unclaimed craft is claimed for you; a craft you hold is written into.
     * @dev Requires ERC-721 approval of this wrapper's address for the Talisman. Claiming takes exactly The Vessel's
     *      price, `craftId_ * 0.00001 ether`. Writing into a held craft needs this wrapper set as the craft's delegate
     *      first and takes no ETH, since nothing is claimed and the wrapper cannot pay ETH out. Reverts {NotCapsule}
     *      for a Machine, Vault or relic craft.
     * @param talismanId_ The Talisman to wrap.
     * @param craftId_ The craft. Its id is its capacity in bytes.
     * @param image The image, one pixel per byte, `craftId_ - 32` bytes long.
     */
    constructor(uint256 talismanId_, uint256 craftId_, bytes memory image) payable {
        if (
            _read(IVessel.craftToMachineStatus.selector, craftId_) != 0
                || _read(IVessel.craftToVaultStatus.selector, craftId_) != 0 || _relicOrUnreadable(craftId_)
        ) {
            revert NotCapsule();
        }
        if (image.length + 32 != craftId_) {
            revert WrongImageLength();
        }
        talismanId = talismanId_;
        craftId = craftId_;

        bytes memory payload = bytes.concat(image, abi.encode(address(this)));
        if (_read(IVessel.craftToClaimed.selector, craftId_) != 0) {
            if (_read(IVessel.ownerOf.selector, craftId_) != uint160(msg.sender)) {
                revert NotCraftOwner();
            }
            if (_read(IVessel.craftToDelegate.selector, craftId_) != uint160(address(this))) {
                revert WrapperNotDelegate();
            }
            if (_read(IVessel.craftToLocked.selector, craftId_) != 0) {
                revert CraftLocked();
            }
            if (msg.value != 0) {
                revert UnexpectedPayment();
            }
            VESSEL.setPayloadHolder(craftId_, payload);
        } else {
            uint256[] memory ids = new uint256[](1);
            ids[0] = craftId_;
            VESSEL.setRole(STEWARD);
            // No code yet, so The Vessel's _safeMint does not call back.
            VESSEL.claim{value: msg.value}(address(this), ids, payload, address(0));
            VESSEL.setDelegate(craftId_, address(this));
            VESSEL.transferFrom(address(this), msg.sender, craftId_);
        }
        TALISMANS.transferFrom(msg.sender, address(this), talismanId_);
    }

    /**
     * @notice Gives the Talisman to the craft's holder and blanks the craft's image. Only the craft's current holder
     *         can unwrap, and only once.
     * @dev Reverts {WrapperNotDelegate} while the craft is writable but no longer delegated to this wrapper; the
     *      holder can delegate it to this wrapper again. A locked or relic craft keeps its image, and the holder still
     *      gets the Talisman.
     */
    function unwrap() external {
        uint256 id = craftId;
        if (_read(IVessel.ownerOf.selector, id) != uint160(msg.sender)) {
            revert NotCraftOwner();
        }
        if (unwrapped) {
            revert AlreadyUnwrapped();
        }
        unwrapped = true;
        if (_read(IVessel.craftToLocked.selector, id) == 0 && !_relicOrUnreadable(id)) {
            if (_read(IVessel.craftToDelegate.selector, id) != uint160(address(this))) {
                revert WrapperNotDelegate();
            }
            _blank(id);
        }
        TALISMANS.safeTransferFrom(address(this), msg.sender, talismanId);
    }

    // One word from a view getter of The Vessel; a failed call reverts with its reason.
    function _read(bytes4 selector, uint256 id) private view returns (uint256 word) {
        address vessel = address(VESSEL);
        assembly ("memory-safe") {
            mstore(0x00, selector)
            mstore(0x04, id)
            let ok := staticcall(gas(), vessel, 0x00, 0x24, 0x00, 0x20)
            if iszero(and(ok, gt(returndatasize(), 0x1f))) {
                let p := mload(0x40)
                returndatacopy(p, 0x00, returndatasize())
                revert(p, returndatasize())
            }
            word := mload(0x00)
        }
    }

    // Failure is ignored and no return data is copied, so no relics contract can keep the Talisman in. Starving the
    // call cannot keep the image: the 1/64 of gas left cannot pay for the transfer that follows.
    function _blank(uint256 id) private {
        bytes4 selector = IVessel.setPayloadHolder.selector;
        address vessel = address(VESSEL);
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, selector)
            mstore(add(p, 0x04), id)
            mstore(add(p, 0x24), 0x40)
            mstore(add(p, 0x44), 0)
            pop(call(gas(), vessel, 0, p, 0x64, 0x00, 0x00))
        }
    }

    // The Vessel's owner can repoint `relics`, so only a clean `false` counts as writable; at most one word is read
    // back.
    function _relicOrUnreadable(uint256 id) private view returns (bool relic) {
        // relics() takes no argument; the id word after its selector is ignored.
        address relics = address(uint160(_read(IVessel.relics.selector, 0)));
        bytes4 selector = IRelics.isRelic.selector;
        assembly ("memory-safe") {
            mstore(0x00, selector)
            mstore(0x04, id)
            let ok := staticcall(gas(), relics, 0x00, 0x24, 0x00, 0x20)
            relic := or(iszero(and(ok, gt(returndatasize(), 0x1f))), iszero(iszero(mload(0x00))))
        }
    }
}
