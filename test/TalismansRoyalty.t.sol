// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Talismans} from "../src/Talismans.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev EIP-2981 royalty behaviour for {Talismans}: defaults, the owner-only
///      {setRoyalty} mutator, the hardcoded 0–10% range, recipient handling,
///      ERC-165 advertisement, and interaction with two-step ownership.
contract TalismansRoyaltyTest is Test {
    Talismans internal nft;

    address internal deployer = address(this);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal payee = address(0xBEEF);

    // EIP-2981's fixed denominator (OZ default): bps are out of 10000.
    uint256 internal constant DENOM = 10000;

    event RoyaltyUpdated(address indexed receiver, uint96 bps);

    function setUp() public {
        nft = new Talismans();
    }

    // ─── Defaults ──────────────────────────────────────────────────────────────

    function test_constants() public view {
        assertEq(nft.DEFAULT_ROYALTY_BPS(), 500, "default 5%");
        assertEq(nft.MAX_ROYALTY_BPS(), 1000, "ceiling 10%");
    }

    function test_defaultRoyalty_isFivePercentToOwner() public view {
        // Default recipient is the deployer (initial owner).
        (address receiver, uint256 amount) = nft.royaltyInfo(1, 10_000);
        assertEq(receiver, deployer, "receiver defaults to owner/deployer");
        assertEq(amount, 500, "5% of 10000");
    }

    function test_defaultRoyalty_scalesWithSalePrice() public view {
        (, uint256 amount) = nft.royaltyInfo(1, 1 ether);
        assertEq(amount, 0.05 ether, "5% of 1 ETH");

        (, uint256 amount2) = nft.royaltyInfo(7, 2.5 ether);
        assertEq(amount2, 0.125 ether, "5% of 2.5 ETH");
    }

    function test_royalty_appliesToAnyTokenId() public view {
        // EIP-2981 is collection-wide here, so any id returns the default.
        (address r1, uint256 a1) = nft.royaltyInfo(1, 1 ether);
        (address r2, uint256 a2) = nft.royaltyInfo(999_999, 1 ether);
        assertEq(r1, r2);
        assertEq(a1, a2);
    }

    // ─── ERC-165 advertisement ───────────────────────────────────────────────

    function test_supportsInterface_advertisesAll() public view {
        assertTrue(nft.supportsInterface(0x01ffc9a7), "ERC-165");
        assertTrue(nft.supportsInterface(0x80ac58cd), "ERC-721");
        assertTrue(nft.supportsInterface(0x5b5e139f), "ERC-721 Metadata");
        assertTrue(nft.supportsInterface(0x49064906), "ERC-4906");
        assertTrue(nft.supportsInterface(0x2a55205a), "EIP-2981");
        // Sanity: a bogus id is still rejected.
        assertFalse(nft.supportsInterface(0xdeadbeef));
        assertFalse(nft.supportsInterface(0xffffffff));
    }

    function test_supportsInterface_matchesTypeIds() public view {
        assertTrue(nft.supportsInterface(type(IERC165).interfaceId));
        assertTrue(nft.supportsInterface(type(IERC721).interfaceId));
        assertTrue(nft.supportsInterface(type(IERC721Metadata).interfaceId));
        assertTrue(nft.supportsInterface(type(IERC2981).interfaceId));
    }

    // ─── setRoyalty: happy path ──────────────────────────────────────────────

    function test_setRoyalty_updatesRateAndReceiver() public {
        nft.setRoyalty(payee, 250); // 2.5%
        (address receiver, uint256 amount) = nft.royaltyInfo(1, 1 ether);
        assertEq(receiver, payee);
        assertEq(amount, 0.025 ether);
    }

    function test_setRoyalty_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(nft));
        emit RoyaltyUpdated(payee, 750);
        nft.setRoyalty(payee, 750);
    }

    function test_setRoyalty_atCeiling_tenPercent() public {
        nft.setRoyalty(payee, 1000); // exactly 10% — allowed
        (, uint256 amount) = nft.royaltyInfo(1, 1 ether);
        assertEq(amount, 0.1 ether);
    }

    function test_setRoyalty_zeroWaivesButKeepsReceiver() public {
        nft.setRoyalty(payee, 0);
        (address receiver, uint256 amount) = nft.royaltyInfo(1, 1 ether);
        assertEq(receiver, payee, "receiver retained");
        assertEq(amount, 0, "royalty waived");
    }

    function test_setRoyalty_canChangeReceiverOnly() public {
        nft.setRoyalty(payee, 500); // same 5%, new receiver
        (address receiver, uint256 amount) = nft.royaltyInfo(1, 1 ether);
        assertEq(receiver, payee);
        assertEq(amount, 0.05 ether);
    }

    // ─── setRoyalty: bounds & validation ─────────────────────────────────────

    function test_setRoyalty_aboveCeiling_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Talismans.RoyaltyTooHigh.selector, uint96(1001)));
        nft.setRoyalty(payee, 1001);
    }

    function test_setRoyalty_wayAboveCeiling_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Talismans.RoyaltyTooHigh.selector, uint96(10_000)));
        nft.setRoyalty(payee, 10_000);
    }

    function test_setRoyalty_zeroReceiver_reverts() public {
        // OZ ERC2981 rejects a zero receiver for a non-zero fee.
        vm.expectRevert(abi.encodeWithSelector(ERC2981.ERC2981InvalidDefaultRoyaltyReceiver.selector, address(0)));
        nft.setRoyalty(address(0), 500);
    }

    // ─── Owner protection ─────────────────────────────────────────────────────

    function test_setRoyalty_onlyOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nft.setRoyalty(alice, 250);
    }

    function test_setRoyalty_onlyOwner_revertsEvenWithinRange() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        nft.setRoyalty(bob, 0);
    }

    /// @dev A non-owner attempt must not mutate state.
    function test_setRoyalty_failedCallLeavesStateUnchanged() public {
        vm.prank(alice);
        vm.expectRevert();
        nft.setRoyalty(alice, 1000);

        (address receiver, uint256 amount) = nft.royaltyInfo(1, 1 ether);
        assertEq(receiver, deployer, "still default receiver");
        assertEq(amount, 0.05 ether, "still default 5%");
    }

    // ─── Interaction with two-step ownership ─────────────────────────────────

    function test_royaltyReceiver_doesNotAutoFollowOwnership() public {
        nft.transferOwnership(alice);
        vm.prank(alice);
        nft.acceptOwnership();
        assertEq(nft.owner(), alice);

        // Receiver is still the original deployer — EIP-2981 recipient is set
        // independently, not derived from the live owner.
        (address receiver,) = nft.royaltyInfo(1, 1 ether);
        assertEq(receiver, deployer, "receiver unchanged by ownership transfer");
    }

    function test_newOwner_canSetRoyalty_oldOwnerCannot() public {
        nft.transferOwnership(alice);
        vm.prank(alice);
        nft.acceptOwnership();

        // New owner can set.
        vm.prank(alice);
        nft.setRoyalty(alice, 800);
        (address receiver, uint256 amount) = nft.royaltyInfo(1, 1 ether);
        assertEq(receiver, alice);
        assertEq(amount, 0.08 ether);

        // Old owner can no longer.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        nft.setRoyalty(deployer, 500);
    }

    // ─── Fuzz ────────────────────────────────────────────────────────────────

    function testFuzz_setRoyalty_withinRange(uint96 bps, address receiver, uint256 salePrice) public {
        bps = uint96(bound(bps, 0, nft.MAX_ROYALTY_BPS()));
        vm.assume(receiver != address(0));
        salePrice = bound(salePrice, 0, 1e30);

        nft.setRoyalty(receiver, bps);
        (address r, uint256 amount) = nft.royaltyInfo(1, salePrice);
        assertEq(r, receiver);
        assertEq(amount, (salePrice * bps) / DENOM);
    }

    function testFuzz_setRoyalty_aboveCeilingAlwaysReverts(uint96 bps) public {
        bps = uint96(bound(bps, nft.MAX_ROYALTY_BPS() + 1, type(uint96).max));
        vm.expectRevert(abi.encodeWithSelector(Talismans.RoyaltyTooHigh.selector, bps));
        nft.setRoyalty(payee, bps);
    }

    function testFuzz_setRoyalty_onlyOwner(address caller) public {
        vm.assume(caller != deployer);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        nft.setRoyalty(caller, 100);
    }
}
