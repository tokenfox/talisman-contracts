// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

interface IMockRelics {
    function isRelic(uint256 id) external view returns (bool);
    function relicToPayload(uint256 id) external view returns (bytes memory);
}

/// @dev The subset of The Vessel (mainnet 0xECb9...1463) a wrapper touches, with
///      the same rules: a craft's id is its byte capacity, the claim price is
///      exact, a craft's first write pushes and every later write replaces,
///      writes are open to the holder or the delegate, and the delegate survives
///      a transfer. Type, lock and relic status are test switches instead of the
///      live permutation and lock clock. Built to be `vm.etch`ed onto the real
///      address, so it keeps no constructor state and is its own relics contract
///      until `setRelics` points it elsewhere, as The Vessel owner can. Relic
///      checks are plain high-level calls, so a broken relics contract reverts
///      writes and reads just as it does on the real Vessel.
contract MockVessel is ERC721 {
    uint256 public constant PRICE_PER_UNIT = 0.00001 ether;

    error AlreadyClaimed();
    error PriceIncorrect();
    error BytesExceedCapacity();
    error MustBeHolderOrDelegate();
    error CraftLocked();
    error IsRelic();
    error WrongType();

    mapping(uint256 => bytes[]) private _payloads;
    mapping(uint256 => bool) public craftToClaimed;
    mapping(uint256 => address) public craftToDelegate;
    mapping(uint256 => uint8) public craftToRole;
    mapping(address => uint8) public addressToRole;
    mapping(uint256 => bool) public craftToMachineStatus;
    mapping(uint256 => bool) public craftToVaultStatus;
    mapping(uint256 => bool) public craftToLocked;
    mapping(uint256 => bool) public isRelic;
    address private _relics;
    bool private _relicsSet;

    constructor() ERC721("The Vessel", "VESSEL") {}

    function relics() public view returns (address) {
        return _relicsSet ? _relics : address(this);
    }

    function setRelics(address relics_) external {
        _relics = relics_;
        _relicsSet = true;
    }

    function relicToPayload(uint256) external pure returns (bytes memory) {
        return "relic";
    }

    function setType(uint256 id, bool machine, bool vault) external {
        craftToMachineStatus[id] = machine;
        craftToVaultStatus[id] = vault;
    }

    function setLocked(uint256 id, bool locked) external {
        craftToLocked[id] = locked;
    }

    function setRelic(uint256 id, bool relic) external {
        isRelic[id] = relic;
    }

    function setRole(uint8 role) external {
        addressToRole[msg.sender] = role;
    }

    function claim(address to, uint256[] calldata ids, bytes calldata payload, address) external payable {
        uint256 sum;
        for (uint256 i; i < ids.length; ++i) {
            if (craftToClaimed[ids[i]]) {
                revert AlreadyClaimed();
            }
            sum += ids[i];
        }
        if (msg.value != PRICE_PER_UNIT * sum) {
            revert PriceIncorrect();
        }
        if (payload.length > sum) {
            revert BytesExceedCapacity();
        }
        uint256 offset;
        for (uint256 i; i < ids.length; ++i) {
            uint256 take = payload.length - offset < ids[i] ? payload.length - offset : ids[i];
            if (take != 0) {
                _payloads[ids[i]].push(payload[offset:offset + take]);
            }
            offset += take;
            craftToClaimed[ids[i]] = true;
            craftToRole[ids[i]] = addressToRole[msg.sender];
            _safeMint(to, ids[i]);
        }
    }

    function setDelegate(uint256 id, address delegate) external {
        if (msg.sender != ownerOf(id)) {
            revert MustBeHolderOrDelegate();
        }
        craftToDelegate[id] = delegate;
    }

    function setPayloadHolder(uint256 id, bytes calldata payload) external {
        if (msg.sender != ownerOf(id) && msg.sender != craftToDelegate[id]) {
            revert MustBeHolderOrDelegate();
        }
        if (craftToMachineStatus[id]) {
            revert WrongType();
        }
        if (craftToLocked[id]) {
            revert CraftLocked();
        }
        if (IMockRelics(relics()).isRelic(id)) {
            revert IsRelic();
        }
        if (payload.length > id) {
            revert BytesExceedCapacity();
        }
        if (_payloads[id].length == 0) {
            _payloads[id].push(payload);
        } else {
            _payloads[id][0] = payload;
        }
    }

    function craftToPayload(uint256 id) external view returns (bytes memory) {
        if (IMockRelics(relics()).isRelic(id)) {
            return IMockRelics(relics()).relicToPayload(id);
        }
        return storedPayload(id);
    }

    function storedPayload(uint256 id) public view returns (bytes memory) {
        return _payloads[id].length == 0 ? bytes("") : _payloads[id][0];
    }
}
