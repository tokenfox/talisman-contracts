// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TalismanInCraftWrapper} from "../../src/thevessel/TalismanInCraftWrapper.sol";
import {VesselRaster} from "./VesselRaster.sol";

/// @notice The read surface of The Vessel (mainnet) the tooling needs, beyond
///         the calls a wrapper itself makes.
interface IVesselRead {
    function PRICE_PER_UNIT() external view returns (uint256);
    function blockEvents(uint256 index) external view returns (uint256);
    function claimIsActive() external view returns (bool);
    function claimIsPaused() external view returns (bool);
    function lockStart() external view returns (uint256);
    function craftToClaimed(uint256 id) external view returns (bool);
    function craftToMachineStatus(uint256 id) external view returns (bool);
    function craftToVaultStatus(uint256 id) external view returns (bool);
    function craftToColorMode(uint256 id) external view returns (uint8);
    function craftToLocked(uint256 id) external view returns (bool);
    function craftToLockBlock(uint256 id) external view returns (uint256);
    function craftToDelegate(uint256 id) external view returns (address);
    function craftToPayload(uint256 id) external view returns (bytes memory);
    function craftToSVG(uint256 id) external view returns (string memory);
    function relics() external view returns (address);
    function ownerOf(uint256 id) external view returns (address);
    function transferFrom(address from, address to, uint256 id) external;
    function setDelegate(uint256 id, address delegate) external;
}

interface IVesselRelicsRead {
    function isRelic(uint256 id) external view returns (bool);
}

struct CollectionSecurityPolicy {
    uint8 rulesetId;
    uint48 listId;
    address customRuleset;
    uint8 globalOptions;
    uint16 rulesetOptions;
    uint16 tokenType;
}

/// @notice The management and simulation surface of Limit Break's
///         CreatorTokenTransferValidator (mainnet 0x721C...42e3).
interface ITransferValidatorAdmin {
    function getCollectionSecurityPolicy(address collection) external view returns (CollectionSecurityPolicy memory);
    function validateTransferSim(address collection, address caller, address from, address to)
        external
        view
        returns (bool isTransferAllowed, bytes4 errorCode);
    function listOwners(uint48 id) external view returns (address);
    function isAccountInList(uint48 id, uint8 listType, address account) external view returns (bool);
    function isCodeHashInList(uint48 id, uint8 listType, bytes32 codehash) external view returns (bool);
    function isAccountInListByCollection(address collection, uint8 listType, address account)
        external
        view
        returns (bool);
    function getListAccounts(uint48 id, uint8 listType) external view returns (address[] memory);
    function getListCodeHashes(uint48 id, uint8 listType) external view returns (bytes32[] memory);
    function createList(string calldata name) external returns (uint48 id);
    function reassignOwnershipOfList(uint48 id, address newOwner) external;
    function addAccountsToList(uint48 id, uint8 listType, address[] calldata accounts) external;
    function addCodeHashesToList(uint48 id, uint8 listType, bytes32[] calldata codehashes) external;
    function applyListToCollection(address collection, uint48 id) external;
    function setRulesetOfCollection(
        address collection,
        uint8 rulesetId,
        address customRuleset,
        uint8 globalOptions,
        uint16 rulesetOptions
    ) external;
}

/// @notice Addresses and pure helpers shared by the TalismanInCraftWrapper scripts and tests.
library TalismanInCraft {
    address internal constant TALISMANS = 0x724D5bEffe9A84a87AD1Af83713F80600E5f5774;
    address internal constant VESSEL = 0xECb92Cc7112b80A2234936315BbB493fb48d1463;
    address internal constant VALIDATOR = 0x721C008fdff27BF06E7E123956E2Fe03B63342e3;

    uint256 internal constant PRICE_PER_BYTE = 0.00001 ether;

    // THE_VESSEL type split: machine if r <= 1500, vault if 1500 <= r <= 5150.
    uint256 private constant MACHINE_CEILING = 1500;
    uint256 private constant VAULT_CEILING = 5150;
    uint256 private constant MAX_SUPPLY = 10_000;
    uint256 private constant W_GREY = 9540;
    uint256 private constant W_TOTAL = 9695;

    /// @notice The runtime code hash of the released, verified TalismanInCraftWrapper.
    bytes32 internal constant RELEASED_WRAPPER_CODEHASH =
        0x20b85506f7e46a35bd50b146a0ecf299b693e651c93e9d2c430c2d2a5d3309f8;

    function wrapperCodehash() internal pure returns (bytes32) {
        return keccak256(type(TalismanInCraftWrapper).runtimeCode);
    }

    /// @notice Refuses to go on if the compiled wrapper is not the released one, so a
    ///         change of toolchain or source can never deploy a wrapper frontends and
    ///         the transfer policy would not recognise.
    function requireReleasedWrapper() internal pure {
        require(
            wrapperCodehash() == RELEASED_WRAPPER_CODEHASH,
            "compiled TalismanInCraftWrapper is not the released one - check the source and the toolchain"
        );
    }

    /// @notice THE_VESSEL._permute, recomputed off-chain so a search spends RPC
    ///         calls only on real candidates.
    function permute(uint256 x, uint256 seed) internal pure returns (uint256) {
        uint256 v = x - 1;
        while (true) {
            uint256 l = v & 127;
            uint256 r = (v >> 7) & 127;
            for (uint256 round; round < 6; ++round) {
                uint256 f = uint256(keccak256(abi.encodePacked(r, seed, round))) & 127;
                (l, r) = (r, (l ^ f) & 127);
            }
            uint256 y = l | (r << 7);
            if (y < MAX_SUPPLY) {
                return y + 1;
            }
            v = y;
        }
        return 0;
    }

    function isCapsule(uint256 id, uint256 seed) internal pure returns (bool) {
        return permute(id, seed) > VAULT_CEILING;
    }

    function isMachine(uint256 id, uint256 seed) internal pure returns (bool) {
        return permute(id, seed) <= MACHINE_CEILING;
    }

    /// @notice THE_VESSEL.craftToColorMode == 0, recomputed off-chain.
    function isGreyscale(uint256 id, uint256 seed) internal pure returns (bool) {
        return uint256(keccak256(abi.encodePacked(seed, id))) % W_TOTAL < W_GREY;
    }

    /// @notice The largest free, exact-fit craft in [minBytes, maxBytes], or 0.
    function findCraft(uint256 minBytes, uint256 maxBytes, bool allowTinted) internal view returns (uint256) {
        return findCraft(minBytes, maxBytes, allowTinted, false);
    }

    /// @notice The largest free, exact-fit craft in [minBytes, maxBytes] - or, with
    ///         `cheapest`, the smallest (the claim price is linear in size) - or 0.
    function findCraft(uint256 minBytes, uint256 maxBytes, bool allowTinted, bool cheapest)
        internal
        view
        returns (uint256)
    {
        IVesselRead vessel = IVesselRead(VESSEL);
        IVesselRelicsRead relics = IVesselRelicsRead(vessel.relics());
        uint256 seed = vessel.blockEvents(0);
        if (maxBytes > MAX_SUPPLY) {
            maxBytes = MAX_SUPPLY;
        }
        if (minBytes == 0) {
            minBytes = 1;
        }
        if (minBytes > maxBytes) {
            return 0;
        }
        uint256 span = maxBytes - minBytes;
        for (uint256 i; i <= span; ++i) {
            uint256 n = cheapest ? minBytes + i : maxBytes - i;
            if (!VesselRaster.isExactFit(n) || !isCapsule(n, seed)) {
                continue;
            }
            if (!allowTinted && !isGreyscale(n, seed)) {
                continue;
            }
            if (vessel.craftToClaimed(n) || relics.isRelic(n)) {
                continue;
            }
            return n;
        }
        return 0;
    }

    /// @notice Why craft `n` cannot hold a wrapper, or "" when it can. Who holds a
    ///         claimed craft is the caller's question, not this one's.
    function craftProblem(uint256 n, bool allowTinted) internal view returns (string memory) {
        IVesselRead vessel = IVesselRead(VESSEL);
        if (n == 0 || n > MAX_SUPPLY) {
            return "no such craft";
        }
        if (vessel.craftToClaimed(n) && vessel.craftToLocked(n)) {
            return "craft is locked";
        }
        if (vessel.craftToMachineStatus(n) || vessel.craftToVaultStatus(n)) {
            return "craft is not of type Capsule";
        }
        if (IVesselRelicsRead(vessel.relics()).isRelic(n)) {
            return "craft is a relic";
        }
        if (!allowTinted && vessel.craftToColorMode(n) != 0) {
            return "craft is tinted (set ALLOW_TINTED=true to accept)";
        }
        if (n < VesselRaster.ADDRESS_WORD) {
            return "craft is too small to hold the wrapper's address";
        }
        return "";
    }
}

/// @notice The ERC-721C policy steps and probes for wrappers. Every function that
///         writes is called by the Talismans owner, from a script broadcast or a
///         pranked test, so the script's steps are exactly what the tests run.
library WrapperPolicy {
    uint8 internal constant LIST_WHITELIST = 1;
    uint8 internal constant RULESET_DEFAULT = 0;
    uint8 internal constant RULESET_BLACKLIST = 3;
    uint8 internal constant RULESET_WHITELIST = 4;
    uint8 internal constant FLAG_SUPPLEMENTS_DEFAULT_LIST = 1 << 3;
    uint16 internal constant FLAG_BLOCK_ALL_OTC = 1 << 0;
    uint16 internal constant FLAG_BLOCK_SMART_WALLET_RECEIVERS = 1 << 3;
    uint16 internal constant FLAG_BLOCK_UNVERIFIED_EOA_RECEIVERS = 1 << 4;

    // Blacklist, whitelist, authorizers and the three whitelist expansion types:
    // every list type the validator's rulesets read.
    uint8 internal constant LIST_TYPE_COUNT = 6;

    string internal constant LIST_NAME = "Talisman wrappers";

    function validator() internal pure returns (ITransferValidatorAdmin) {
        return ITransferValidatorAdmin(TalismanInCraft.VALIDATOR);
    }

    function policy() internal view returns (CollectionSecurityPolicy memory) {
        return validator().getCollectionSecurityPolicy(TalismanInCraft.TALISMANS);
    }

    function isWhitelistRuleset(uint8 rulesetId) internal pure returns (bool) {
        return rulesetId == RULESET_DEFAULT || rulesetId == RULESET_WHITELIST;
    }

    /// @notice Whether the live policy checks the wrap's receiver for a verified
    ///         EOA - the one setting that needs a per-wrapper list entry.
    function needsPerWrapperEntry() internal view returns (bool) {
        CollectionSecurityPolicy memory p = policy();
        return isWhitelistRuleset(p.rulesetId) && (p.rulesetOptions & FLAG_BLOCK_UNVERIFIED_EOA_RECEIVERS) != 0;
    }

    /// @notice Whether the exemption is in place for `deployer` and the current
    ///         wrapper code hash.
    function isExempt(address deployer) internal view returns (bool codehashListed, bool deployerListed) {
        CollectionSecurityPolicy memory p = policy();
        if (p.listId == 0) {
            return (false, false);
        }
        codehashListed = validator().isCodeHashInList(p.listId, LIST_WHITELIST, TalismanInCraft.wrapperCodehash());
        deployerListed = validator().isAccountInList(p.listId, LIST_WHITELIST, deployer);
    }

    /// @notice Whether the collection already reads a list `deployer` owns.
    function hasOwnList(address deployer) internal view returns (bool) {
        uint48 id = policy().listId;
        return id != 0 && validator().listOwners(id) == deployer;
    }

    /// @notice Step one: an empty list owned by the caller. Empty rather than a
    ///         copy of the default list, which keeps applying live through
    ///         FLAG_SUPPLEMENTS_DEFAULT_LIST; a copy would freeze its entries.
    function createList() internal returns (uint48) {
        return validator().createList(LIST_NAME);
    }

    /// @notice Step two, on the id step one actually produced: whitelist the wrapper
    ///         code hash and `deployer`, apply the list and set the supplement flag,
    ///         keeping the ruleset and its options. Idempotent: skips what is in
    ///         place.
    function configure(uint48 id, address deployer) internal {
        // The id is fixed before step one lands, so another createList can take
        // it; applyListToCollection would accept that list anyway. Only a list
        // `deployer` owns and that holds nothing but our entries goes on.
        requireOwnCleanList(id, deployer);
        ITransferValidatorAdmin v = validator();
        bytes32 hash = TalismanInCraft.wrapperCodehash();
        if (!v.isCodeHashInList(id, LIST_WHITELIST, hash)) {
            bytes32[] memory hashes = new bytes32[](1);
            hashes[0] = hash;
            v.addCodeHashesToList(id, LIST_WHITELIST, hashes);
        }
        if (!v.isAccountInList(id, LIST_WHITELIST, deployer)) {
            address[] memory accounts = new address[](1);
            accounts[0] = deployer;
            v.addAccountsToList(id, LIST_WHITELIST, accounts);
        }
        CollectionSecurityPolicy memory p = policy();
        // The flag goes on before the list swap so the default list never stops
        // applying, even when the two land in different blocks.
        if ((p.globalOptions & FLAG_SUPPLEMENTS_DEFAULT_LIST) == 0) {
            v.setRulesetOfCollection(
                TalismanInCraft.TALISMANS,
                p.rulesetId,
                p.customRuleset,
                p.globalOptions | FLAG_SUPPLEMENTS_DEFAULT_LIST,
                p.rulesetOptions
            );
        }
        if (p.listId != id) {
            v.applyListToCollection(TalismanInCraft.TALISMANS, id);
        }
    }

    /// @notice Reverts unless `deployer` owns list `id` and the list holds no entry
    ///         but the wrapper code hash, `deployer`, and wrappers on the whitelist.
    /// @dev A list can be reassigned to `deployer` after someone else filled it, so
    ///      ownership alone does not make it ours. Whitelisted accounts beyond
    ///      `deployer` must carry the wrapper code hash: wrapped wrappers that
    ///      `addWrapperAccount` listed. A listed address with no code yet cannot be
    ///      told apart from a foreign one, so it is refused. The list Talismans
    ///      already reads passed this check when it was applied and only its
    ///      owner can have edited it since - for an earlier wrapper version's code
    ///      hash or a per-wrapper entry - so for that list ownership suffices.
    function requireOwnCleanList(uint48 id, address deployer) internal view {
        ITransferValidatorAdmin v = validator();
        require(id != 0 && v.listOwners(id) == deployer, "list is not owned by the deployer");
        if (policy().listId == id) {
            return;
        }
        bytes32 hash = TalismanInCraft.wrapperCodehash();
        for (uint8 t; t < LIST_TYPE_COUNT; ++t) {
            address[] memory accounts = v.getListAccounts(id, t);
            bytes32[] memory hashes = v.getListCodeHashes(id, t);
            if (t != LIST_WHITELIST) {
                require(accounts.length == 0 && hashes.length == 0, "list holds foreign entries");
                continue;
            }
            for (uint256 i; i < hashes.length; ++i) {
                require(hashes[i] == hash, "list holds a foreign code hash");
            }
            for (uint256 i; i < accounts.length; ++i) {
                address a = accounts[i];
                require(a == deployer || a.codehash == hash, "list whitelists a foreign account");
            }
        }
    }

    /// @notice createList and configure in one go, for simulations and tests
    ///         only: broadcast from one script run, the id configure uses would
    ///         be the simulated one. Reuses the collection's list when `deployer`
    ///         already owns it.
    function applyExemption(address deployer) internal returns (uint48 id) {
        id = hasOwnList(deployer) ? policy().listId : createList();
        configure(id, deployer);
    }

    /// @notice Adds one predicted wrapper address to the collection's list.
    function addWrapperAccount(address wrapper) internal {
        address[] memory accounts = new address[](1);
        accounts[0] = wrapper;
        validator().addAccountsToList(policy().listId, LIST_WHITELIST, accounts);
    }

    /// @notice The constructor pull: caller is the wrapper before it has code.
    function probeWrap(address deployer, address wrapperWithoutCode) internal view returns (bool ok, bytes4 err) {
        return
            validator().validateTransferSim(TalismanInCraft.TALISMANS, wrapperWithoutCode, deployer, wrapperWithoutCode);
    }

    /// @notice The unwrap: the wrapper moves its own Talisman out.
    function probeUnwrap(address wrapper, address recipient) internal view returns (bool ok, bytes4 err) {
        return validator().validateTransferSim(TalismanInCraft.TALISMANS, wrapper, wrapper, recipient);
    }

    /// @notice A contract operator moving a collector's token: the transfer the
    ///         exemption must not open up for anything but wrappers.
    function probeOperator(address operator, address collector) internal view returns (bool ok, bytes4 err) {
        return validator().validateTransferSim(TalismanInCraft.TALISMANS, operator, collector, operator);
    }
}
