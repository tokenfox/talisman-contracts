// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Talismans} from "../src/Talismans.sol";
import {CreatorTokenBase} from "../src/CreatorTokenBase.sol";
import {ICreatorToken, ICreatorTokenLegacy, ITransferValidator} from "../src/ICreatorToken.sol";
import {MockTransferValidator} from "./mocks/MockTransferValidator.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev ERC-721C royalty enforcement for {Talismans}: the transfer-validator
///      surface marketplaces detect, the validator actually gating secondary
///      transfers, that mints are never gated, and the one-way
///      {disableRoyaltyEnforcementForever} switch that relaxes enforcement for
///      good. The canonical validator has no code locally, so a
///      {MockTransferValidator} stands in wherever a transfer must be gated.
contract CreatorTokenEnforcementTest is Test {
    Talismans internal nft;
    MockTransferValidator internal validator;

    address internal deployer = address(this);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal market = address(0x3A2E7); // a marketplace operator

    address internal constant CANONICAL = 0x721C008fdff27BF06E7E123956E2Fe03B63342e3;

    event TransferValidatorUpdated(address oldValidator, address newValidator);
    event RoyaltyEnforcementDisabledForever();

    function setUp() public {
        nft = new Talismans();
        validator = new MockTransferValidator();
        // Mint token 1 to alice. Self as minter keeps the test self-contained;
        // transfers don't require reveal.
        nft.setMinter(address(this));
        nft.mintWithCommitment(alice);
    }

    function _mintTo(address to) internal returns (uint256 tokenId) {
        (tokenId,) = nft.mintWithCommitment(to);
    }

    // ─── The creator-token surface marketplaces read ─────────────────────────

    function test_defaultValidator_isCanonical() public view {
        assertEq(nft.getTransferValidator(), CANONICAL, "defaults to canonical validator");
        assertEq(nft.DEFAULT_TRANSFER_VALIDATOR(), CANONICAL);
        assertFalse(nft.royaltyEnforcementFrozen(), "not frozen at deploy");
    }

    function test_supportsInterface_creatorToken() public view {
        assertTrue(nft.supportsInterface(type(ICreatorToken).interfaceId), "ICreatorToken");
        assertTrue(nft.supportsInterface(type(ICreatorTokenLegacy).interfaceId), "ICreatorTokenLegacy");
    }

    function test_getTransferValidationFunction() public view {
        (bytes4 sig, bool isView) = nft.getTransferValidationFunction();
        assertEq(sig, ITransferValidator.validateTransfer.selector, "validateTransfer selector");
        assertEq(sig, bytes4(keccak256("validateTransfer(address,address,address,uint256)")));
        assertTrue(isView, "validation is a view call");
    }

    // ─── setTransferValidator ────────────────────────────────────────────────

    function test_setTransferValidator_updatesAndEmits() public {
        vm.expectEmit(false, false, false, true, address(nft));
        emit TransferValidatorUpdated(CANONICAL, address(validator));
        nft.setTransferValidator(address(validator));
        assertEq(nft.getTransferValidator(), address(validator));
    }

    function test_setTransferValidator_onlyOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nft.setTransferValidator(address(validator));
    }

    function test_setTransferValidator_rejectsNonContract() public {
        vm.expectRevert(CreatorTokenBase.InvalidTransferValidatorContract.selector);
        nft.setTransferValidator(address(0xDEAD));
    }

    function test_setTransferValidator_acceptsZero() public {
        nft.setTransferValidator(address(0));
        assertEq(nft.getTransferValidator(), address(0), "zero sticks (no fallback to default)");
    }

    // ─── Enforcement: the validator gates secondary transfers ────────────────

    function test_enforcement_blocksDisallowedOperator() public {
        nft.setTransferValidator(address(validator)); // nobody allowed yet

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MockTransferValidator.OperatorNotAllowed.selector, alice));
        nft.transferFrom(alice, bob, 1);

        assertEq(nft.ownerOf(1), alice, "transfer was blocked");
    }

    function test_enforcement_allowsWhitelistedOperator() public {
        nft.setTransferValidator(address(validator));
        validator.setAllowedOperator(market, true);

        // alice lists on the market and approves it; the market moves the token.
        vm.prank(alice);
        nft.setApprovalForAll(market, true);
        vm.prank(market);
        nft.transferFrom(alice, bob, 1);

        assertEq(nft.ownerOf(1), bob, "whitelisted operator settles the sale");
    }

    function test_enforcement_mintsAreNeverGated() public {
        nft.setTransferValidator(address(validator)); // blocks everyone

        // A mint (from == address(0)) must still succeed under a blocking policy.
        uint256 id = _mintTo(bob);
        assertEq(nft.ownerOf(id), bob, "mint not gated by the validator");
    }

    function test_noValidatorCode_transfersPass() public {
        // Default canonical validator has no code on this chain → no gating.
        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);
        assertEq(nft.ownerOf(1), bob);
    }

    // ─── disableRoyaltyEnforcementForever: the one-way off switch ─────────────

    function test_disable_oneCall_relaxesAndLocks() public {
        nft.setTransferValidator(address(validator)); // enforcement on

        // Blocked while enforcing.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MockTransferValidator.OperatorNotAllowed.selector, alice));
        nft.transferFrom(alice, bob, 1);

        // One owner call switches enforcement off for good.
        vm.expectEmit(false, false, false, false, address(nft));
        emit RoyaltyEnforcementDisabledForever();
        nft.disableRoyaltyEnforcementForever();

        assertTrue(nft.royaltyEnforcementFrozen(), "frozen");
        assertEq(nft.getTransferValidator(), address(0), "validator zeroed");

        // The same transfer now settles anywhere.
        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);
        assertEq(nft.ownerOf(1), bob);
    }

    function test_disable_thenSetValidator_reverts() public {
        nft.disableRoyaltyEnforcementForever();
        vm.expectRevert(Talismans.RoyaltyEnforcementFrozen.selector);
        nft.setTransferValidator(address(validator));
    }

    function test_disable_twice_reverts() public {
        nft.disableRoyaltyEnforcementForever();
        vm.expectRevert(Talismans.RoyaltyEnforcementFrozen.selector);
        nft.disableRoyaltyEnforcementForever();
    }

    function test_disable_onlyOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nft.disableRoyaltyEnforcementForever();
    }

    function test_disable_leavesRoyaltyRateLive() public {
        nft.disableRoyaltyEnforcementForever();

        // EIP-2981 still reports a royalty — it's now a request, not a gate.
        (address receiver, uint256 amount) = nft.royaltyInfo(1, 1 ether);
        assertEq(receiver, deployer);
        assertEq(amount, 0.05 ether, "default 5% still signalled");

        // And the owner can still tune the rate.
        nft.setRoyalty(bob, 750);
        (address r2, uint256 a2) = nft.royaltyInfo(1, 1 ether);
        assertEq(r2, bob);
        assertEq(a2, 0.075 ether);
    }

    function test_disable_byNewOwnerAfterHandover() public {
        nft.transferOwnership(alice);
        vm.prank(alice);
        nft.acceptOwnership();

        vm.prank(alice);
        nft.disableRoyaltyEnforcementForever();
        assertTrue(nft.royaltyEnforcementFrozen());
    }

    // ─── Fuzz ────────────────────────────────────────────────────────────────

    function testFuzz_setTransferValidator_onlyOwner(address caller) public {
        vm.assume(caller != deployer);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        nft.setTransferValidator(address(validator));
    }

    function testFuzz_afterDisable_validatorAlwaysZero(address anyValidator) public {
        nft.disableRoyaltyEnforcementForever();
        vm.expectRevert(Talismans.RoyaltyEnforcementFrozen.selector);
        nft.setTransferValidator(anyValidator);
        assertEq(nft.getTransferValidator(), address(0));
    }
}
