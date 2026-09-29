// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TalismanInCraftWrapper} from "../../src/thevessel/TalismanInCraftWrapper.sol";
import {
    CollectionSecurityPolicy,
    ITransferValidatorAdmin,
    WrapperPolicy,
    TalismanInCraft
} from "../../script/thevessel/TalismanInCraft.sol";
import {WrapperForkBase} from "./TalismanInCraftWrapperFork.t.sol";

/// @dev A contract that moves someone else's Talisman with an approval - the
///      generic wrapper the wrapper exemption must not let through.
contract GenericOperator {
    function pull(address token, address from, uint256 id) external {
        (bool ok, bytes memory ret) =
            token.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", from, address(this), id));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}

/// @dev The ERC-721C policy steps of the WrapperPolicy library in
///      script/thevessel/TalismanInCraft.sol, run as the Talismans owner against the live
///      validator.
contract TalismanInCraftWrapperPolicyForkTest is WrapperForkBase {
    uint8 internal constant LIST_AUTHORIZERS = 2;

    address internal collector = makeAddr("collector");
    address internal attacker = makeAddr("attacker");

    function _exempt() internal {
        vm.startPrank(holder);
        WrapperPolicy.applyExemption(holder);
        vm.stopPrank();
    }

    function _createList() internal returns (uint48 id) {
        vm.prank(holder);
        id = WrapperPolicy.createList();
    }

    function configureAsHolder(uint48 id) external {
        vm.startPrank(holder);
        WrapperPolicy.configure(id, holder);
        vm.stopPrank();
    }

    function _assertPolicy(CollectionSecurityPolicy memory a, CollectionSecurityPolicy memory b) internal pure {
        assertEq(a.rulesetId, b.rulesetId, "rulesetId");
        assertEq(a.listId, b.listId, "listId");
        assertEq(a.customRuleset, b.customRuleset, "customRuleset");
        assertEq(a.globalOptions, b.globalOptions, "globalOptions");
        assertEq(a.rulesetOptions, b.rulesetOptions, "rulesetOptions");
        assertEq(a.tokenType, b.tokenType, "tokenType");
    }

    function _setOptions(uint8 rulesetId, uint16 rulesetOptions) internal {
        CollectionSecurityPolicy memory p = WrapperPolicy.policy();
        vm.prank(holder);
        ITransferValidatorAdmin(TalismanInCraft.VALIDATOR)
            .setRulesetOfCollection(TalismanInCraft.TALISMANS, rulesetId, address(0), p.globalOptions, rulesetOptions);
    }

    function _strict() internal {
        _setOptions(
            WrapperPolicy.RULESET_WHITELIST,
            WrapperPolicy.FLAG_BLOCK_ALL_OTC | WrapperPolicy.FLAG_BLOCK_SMART_WALLET_RECEIVERS
        );
    }

    function _giveToCollector() internal {
        vm.prank(holder);
        TALISMANS.transferFrom(holder, collector, talismanId);
    }

    function test_Policy_TodayIsBlacklistWithEmptyList() public view {
        CollectionSecurityPolicy memory p = WrapperPolicy.policy();
        assertEq(p.rulesetId, WrapperPolicy.RULESET_BLACKLIST);
        (bool ok,) = WrapperPolicy.probeOperator(address(this), collector);
        assertTrue(ok, "any operator passes today");
    }

    function test_Policy_ExemptionIsNeutralToday() public {
        _exempt();
        (bool codehashListed, bool deployerListed) = WrapperPolicy.isExempt(holder);
        assertTrue(codehashListed && deployerListed);
        assertEq(WrapperPolicy.policy().rulesetId, WrapperPolicy.RULESET_BLACKLIST);

        _giveToCollector();
        GenericOperator w = new GenericOperator();
        vm.prank(collector);
        TALISMANS.approve(address(w), talismanId);
        w.pull(address(TALISMANS), collector, talismanId);
        assertEq(TALISMANS.ownerOf(talismanId), address(w));
    }

    function test_Policy_ExemptionIsIdempotent() public {
        _exempt();
        uint48 first = WrapperPolicy.policy().listId;
        _exempt();
        assertEq(WrapperPolicy.policy().listId, first);
    }

    // A later wrapper version: the list keeps the earlier code hash while old
    // wrappers are wrapped, and configure must still accept the list it applied.
    function test_Policy_ConfigureAcceptsItsAppliedListAfterAnUpgrade() public {
        uint48 id = _createList();
        this.configureAsHolder(id);
        bytes32[] memory previous = new bytes32[](1);
        previous[0] = keccak256("an earlier TalismanInCraftWrapper version");
        vm.prank(holder);
        WrapperPolicy.validator().addCodeHashesToList(id, WrapperPolicy.LIST_WHITELIST, previous);
        this.configureAsHolder(id);
        assertEq(WrapperPolicy.policy().listId, id);
    }

    function test_Policy_ConfigureIsIdempotent() public {
        uint48 id = _createList();
        this.configureAsHolder(id);
        CollectionSecurityPolicy memory configured = WrapperPolicy.policy();
        assertEq(configured.listId, id);
        assertEq(
            configured.globalOptions & WrapperPolicy.FLAG_SUPPLEMENTS_DEFAULT_LIST,
            WrapperPolicy.FLAG_SUPPLEMENTS_DEFAULT_LIST
        );

        // A second run finds everything in place and sends nothing.
        vm.recordLogs();
        this.configureAsHolder(id);
        assertEq(vm.getRecordedLogs().length, 0, "second configure wrote nothing");
        _assertPolicy(WrapperPolicy.policy(), configured);
        assertEq(WrapperPolicy.validator().getListAccounts(id, WrapperPolicy.LIST_WHITELIST).length, 1);
        assertEq(WrapperPolicy.validator().getListCodeHashes(id, WrapperPolicy.LIST_WHITELIST).length, 1);
    }

    function test_Policy_ValidatorAppliesAnyExistingList() public {
        // Why configure checks ownership: the validator only checks that the
        // caller owns the collection.
        vm.prank(attacker);
        uint48 foreign = WrapperPolicy.validator().createList("squatter");
        vm.prank(holder);
        WrapperPolicy.validator().applyListToCollection(TalismanInCraft.TALISMANS, foreign);
        assertEq(WrapperPolicy.policy().listId, foreign);
    }

    function test_Policy_ListIdRace_ConfigureRefusesTheTakenId() public {
        CollectionSecurityPolicy memory before = WrapperPolicy.policy();

        // Our createList was simulated as the next id; the attacker's lands first.
        vm.prank(attacker);
        uint48 taken = WrapperPolicy.validator().createList(WrapperPolicy.LIST_NAME);
        uint48 ours = _createList();
        assertEq(ours, taken + 1);

        vm.expectRevert(bytes("list is not owned by the deployer"));
        this.configureAsHolder(taken);
        _assertPolicy(WrapperPolicy.policy(), before);

        this.configureAsHolder(ours);
        assertEq(WrapperPolicy.policy().listId, ours);
        (bool codehashListed, bool deployerListed) = WrapperPolicy.isExempt(holder);
        assertTrue(codehashListed && deployerListed);
    }

    function test_Policy_ListIdRace_ConfigureRefusesAReassignedForeignList() public {
        CollectionSecurityPolicy memory before = WrapperPolicy.policy();
        ITransferValidatorAdmin v = WrapperPolicy.validator();

        // The attacker fills the taken id, then hands it to us.
        vm.startPrank(attacker);
        uint48 taken = v.createList(WrapperPolicy.LIST_NAME);
        address[] memory accounts = new address[](1);
        accounts[0] = attacker;
        v.addAccountsToList(taken, LIST_AUTHORIZERS, accounts);
        v.reassignOwnershipOfList(taken, holder);
        vm.stopPrank();
        assertEq(v.listOwners(taken), holder);

        vm.expectRevert(bytes("list holds foreign entries"));
        this.configureAsHolder(taken);
        _assertPolicy(WrapperPolicy.policy(), before);
    }

    function test_Policy_ListIdRace_ConfigureRefusesAForeignWhitelistEntry() public {
        ITransferValidatorAdmin v = WrapperPolicy.validator();
        vm.startPrank(attacker);
        uint48 taken = v.createList(WrapperPolicy.LIST_NAME);
        address[] memory accounts = new address[](1);
        accounts[0] = attacker;
        v.addAccountsToList(taken, WrapperPolicy.LIST_WHITELIST, accounts);
        v.reassignOwnershipOfList(taken, holder);
        vm.stopPrank();

        vm.expectRevert(bytes("list whitelists a foreign account"));
        this.configureAsHolder(taken);
    }

    function test_Policy_OwnListStartsEmptyAndDefaultListStillApplies() public {
        ITransferValidatorAdmin v = WrapperPolicy.validator();
        address[] memory defaults = v.getListAccounts(0, WrapperPolicy.LIST_WHITELIST);
        assertGt(defaults.length, 0, "the default list whitelists accounts");

        uint48 id = _createList();
        for (uint8 t; t < WrapperPolicy.LIST_TYPE_COUNT; ++t) {
            assertEq(v.getListAccounts(id, t).length, 0);
            assertEq(v.getListCodeHashes(id, t).length, 0);
        }
        this.configureAsHolder(id);
        assertEq(v.getListAccounts(id, LIST_AUTHORIZERS).length, 0, "no copied authorizers");
        for (uint256 i; i < defaults.length; ++i) {
            assertFalse(
                v.isAccountInListByCollection(TalismanInCraft.TALISMANS, WrapperPolicy.LIST_WHITELIST, defaults[i])
            );
        }

        // Under a strict whitelist, an operator on the default list still passes.
        _strict();
        address operator = defaults[0];
        (bool ok,) = WrapperPolicy.probeOperator(operator, collector);
        assertTrue(ok, "the default list applies live through the flag");

        CollectionSecurityPolicy memory p = WrapperPolicy.policy();
        vm.prank(holder);
        v.setRulesetOfCollection(
            TalismanInCraft.TALISMANS,
            p.rulesetId,
            address(0),
            p.globalOptions & ~WrapperPolicy.FLAG_SUPPLEMENTS_DEFAULT_LIST,
            p.rulesetOptions
        );
        (ok,) = WrapperPolicy.probeOperator(operator, collector);
        assertFalse(ok, "without the flag only our list counts");
    }

    function test_Policy_UndoRestoresTodaysPolicy() public {
        CollectionSecurityPolicy memory today = WrapperPolicy.policy();
        _exempt();
        vm.startPrank(holder);
        WrapperPolicy.validator().applyListToCollection(TalismanInCraft.TALISMANS, 0);
        WrapperPolicy.validator().setRulesetOfCollection(TalismanInCraft.TALISMANS, 3, address(0), 0, 6);
        vm.stopPrank();
        CollectionSecurityPolicy memory undone = WrapperPolicy.policy();
        _assertPolicy(undone, today);
        _assertPolicy(
            undone,
            CollectionSecurityPolicy({
                rulesetId: 3, listId: 0, customRuleset: address(0), globalOptions: 0, rulesetOptions: 6, tokenType: 0
            })
        );
    }

    function test_Policy_WrappersWorkToday() public {
        _sellAndUnwrap(_wrap());
    }

    function test_Policy_StrictWithExemption_WrapAndUnwrap() public {
        _exempt();
        _strict();
        _sellAndUnwrap(_wrap());
    }

    function test_Policy_StrictWithExemption_GenericOperatorBlocked() public {
        _exempt();
        _strict();
        _giveToCollector();
        GenericOperator w = new GenericOperator();
        vm.prank(collector);
        TALISMANS.approve(address(w), talismanId);
        vm.expectRevert();
        w.pull(address(TALISMANS), collector, talismanId);
    }

    function test_Policy_StrictWithoutExemption_WrapRevertsAndTalismanStays() public {
        _strict();
        address predicted = vm.computeCreateAddress(holder, vm.getNonce(holder));
        vm.startPrank(holder, holder);
        TALISMANS.approve(predicted, talismanId);
        vm.expectRevert(abi.encodeWithSignature("CreatorTokenTransferValidator__CallerOrFromMustBeWhitelisted()"));
        new TalismanInCraftWrapper{value: craftId * TalismanInCraft.PRICE_PER_BYTE}(
            talismanId, craftId, _image(craftId)
        );
        vm.stopPrank();
        assertEq(TALISMANS.ownerOf(talismanId), holder);
    }

    function test_Policy_EoaVerification_NeedsPerWrapperEntry() public {
        _exempt();
        _setOptions(WrapperPolicy.RULESET_WHITELIST, WrapperPolicy.FLAG_BLOCK_UNVERIFIED_EOA_RECEIVERS);
        assertTrue(WrapperPolicy.needsPerWrapperEntry());

        address predicted = vm.computeCreateAddress(holder, vm.getNonce(holder));
        (bool ok,) = WrapperPolicy.probeWrap(holder, predicted);
        assertFalse(ok, "the wrap's receiver is a wrapper with no code hash yet");

        vm.startPrank(holder);
        WrapperPolicy.addWrapperAccount(predicted);
        vm.stopPrank();
        (ok,) = WrapperPolicy.probeWrap(holder, predicted);
        assertTrue(ok);
        TalismanInCraftWrapper wrapper = _wrap();
        assertEq(TALISMANS.ownerOf(talismanId), address(wrapper));

        // Unwrapping to an unverified EOA stays blocked under this option.
        (ok,) = WrapperPolicy.probeUnwrap(address(wrapper), buyer);
        assertFalse(ok);
    }
}
