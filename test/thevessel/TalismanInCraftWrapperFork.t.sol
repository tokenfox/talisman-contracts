// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LibString} from "solady/utils/LibString.sol";
import {Talismans} from "../../src/Talismans.sol";
import {IVessel, TalismanInCraftWrapper} from "../../src/thevessel/TalismanInCraftWrapper.sol";
import {IVesselRead, TalismanInCraft} from "../../script/thevessel/TalismanInCraft.sol";

/// @dev Shared mainnet-fork setup: the Talismans owner holding a revealed
///      Talisman, and the largest free exact-fit craft. Skipped when
///      MAINNET_RPC_URL is unset.
abstract contract WrapperForkBase is Test {
    Talismans internal constant TALISMANS = Talismans(TalismanInCraft.TALISMANS);
    IVesselRead internal constant VESSEL = IVesselRead(TalismanInCraft.VESSEL);

    address internal holder;
    address internal buyer = makeAddr("buyer");
    uint256 internal talismanId;
    uint256 internal craftId;

    function setUp() public virtual {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        holder = TALISMANS.owner();
        for (uint256 i = 1; i < 400; ++i) {
            address o = TALISMANS.ownerOf(i);
            if (o.code.length == 0 && TALISMANS.isRevealed(i)) {
                talismanId = i;
                vm.prank(o);
                TALISMANS.transferFrom(o, holder, i);
                break;
            }
        }
        require(talismanId != 0, "no revealed Talisman held by an EOA");
        craftId = TalismanInCraft.findCraft(2500, 10_000, false);
        require(craftId != 0, "no free exact-fit craft");
        vm.deal(holder, 10 ether);
    }

    function _image(uint256 n) internal pure returns (bytes memory image) {
        image = new bytes(n - 32);
        for (uint256 i; i < image.length; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            image[i] = bytes1(uint8(i % 256));
        }
    }

    function _wrap() internal returns (TalismanInCraftWrapper wrapper) {
        address predicted = vm.computeCreateAddress(holder, vm.getNonce(holder));
        vm.startPrank(holder, holder);
        TALISMANS.approve(predicted, talismanId);
        wrapper = new TalismanInCraftWrapper{value: craftId * TalismanInCraft.PRICE_PER_BYTE}(
            talismanId, craftId, _image(craftId)
        );
        vm.stopPrank();
        assertEq(address(wrapper), predicted);
    }

    function _sellAndUnwrap(TalismanInCraftWrapper wrapper) internal {
        vm.prank(holder);
        VESSEL.transferFrom(holder, buyer, craftId);
        vm.prank(buyer);
        wrapper.unwrap();
        assertEq(TALISMANS.ownerOf(talismanId), buyer);
        assertEq(VESSEL.craftToPayload(craftId).length, 0);
    }
}

/// @dev The wrapper against the live Vessel, Talismans and transfer validator.
contract TalismanInCraftWrapperForkTest is WrapperForkBase {
    function test_Fork_WrapSellUnwrap() public {
        TalismanInCraftWrapper wrapper = _wrap();
        assertEq(TALISMANS.ownerOf(talismanId), address(wrapper));
        assertEq(VESSEL.ownerOf(craftId), holder);
        assertEq(VESSEL.craftToDelegate(craftId), address(wrapper));
        _sellAndUnwrap(wrapper);

        vm.prank(buyer);
        vm.expectRevert();
        TALISMANS.safeTransferFrom(buyer, address(wrapper), talismanId);
    }

    function test_Fork_PayloadEndsInWrapperWordAndRenders() public {
        TalismanInCraftWrapper wrapper = _wrap();
        bytes memory payload = VESSEL.craftToPayload(craftId);
        assertEq(payload.length, craftId);
        bytes32 word;
        assembly ("memory-safe") {
            word := mload(add(payload, mload(payload)))
        }
        assertEq(word, bytes32(uint256(uint160(address(wrapper)))));
        assertGt(bytes(VESSEL.craftToSVG(craftId)).length, craftId * 40);
    }

    function test_Fork_UnwrappedCraftRendersBlack() public {
        TalismanInCraftWrapper wrapper = _wrap();
        assertTrue(LibString.contains(VESSEL.craftToSVG(craftId), "rgb(1"), "the wrapped craft shows grey levels");
        vm.prank(holder);
        wrapper.unwrap();
        string memory svg = VESSEL.craftToSVG(craftId);
        assertGt(bytes(svg).length, craftId * 40, "a written-then-blanked craft still renders its grid");
        assertTrue(LibString.contains(svg, "rgb(0,0,0)"), "cells render black");
        // A greyscale cell is rgb(v,v,v): any non-zero level starts with a digit 1-9.
        for (uint256 d = 1; d <= 9; ++d) {
            string memory lit = string.concat("rgb(", LibString.toString(d));
            assertFalse(LibString.contains(svg, lit), string.concat("no cell starts with ", lit));
        }
    }

    // Against the live collection: any holder can wrap their own Talisman, and the craft's next holder unwraps it.
    function test_Fork_AnyHolderWraps() public {
        address collector = makeAddr("collector");
        vm.prank(holder);
        TALISMANS.transferFrom(holder, collector, talismanId);
        vm.deal(collector, 1 ether);
        address predicted = vm.computeCreateAddress(collector, vm.getNonce(collector));
        vm.startPrank(collector, collector);
        TALISMANS.approve(predicted, talismanId);
        TalismanInCraftWrapper wrapper = new TalismanInCraftWrapper{value: craftId * TalismanInCraft.PRICE_PER_BYTE}(
            talismanId, craftId, _image(craftId)
        );
        VESSEL.transferFrom(collector, buyer, craftId);
        vm.stopPrank();
        assertEq(address(wrapper).codehash, TalismanInCraft.wrapperCodehash());
        vm.prank(buyer);
        wrapper.unwrap();
        assertEq(TALISMANS.ownerOf(talismanId), buyer);
    }

    // A craft the deployer already holds: nothing is claimed, the image is written in as its delegate.
    function test_Fork_WrapIntoHeldCraft() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = craftId;
        vm.startPrank(holder, holder);
        IVessel(address(VESSEL)).claim{value: craftId * TalismanInCraft.PRICE_PER_BYTE}(
            holder, ids, hex"01", address(0)
        );
        uint256 balance = holder.balance;
        address predicted = vm.computeCreateAddress(holder, vm.getNonce(holder));
        VESSEL.setDelegate(craftId, predicted);
        TALISMANS.approve(predicted, talismanId);
        TalismanInCraftWrapper wrapper = new TalismanInCraftWrapper(talismanId, craftId, _image(craftId));
        vm.stopPrank();
        assertEq(address(wrapper), predicted);
        assertEq(holder.balance, balance, "no claim price the second time");
        assertEq(VESSEL.craftToPayload(craftId), bytes.concat(_image(craftId), abi.encode(address(wrapper))));
        assertEq(VESSEL.ownerOf(craftId), holder);
        assertEq(TALISMANS.ownerOf(talismanId), address(wrapper));
        _sellAndUnwrap(wrapper);
    }

    // The cheapest free craft whose last row is exactly the address.
    function test_Fork_CheapestCraftIsAFreeExactFitCapsule() public view {
        uint256 cheapest = TalismanInCraft.findCraft(33, 10_000, false, true);
        assertGt(cheapest, 0);
        assertLe(cheapest, craftId, "no larger than the largest free craft");
        assertEq(bytes(TalismanInCraft.craftProblem(cheapest, false)).length, 0);
    }

    function test_Fork_CodehashMatchesCompiledWrapper() public {
        TalismanInCraftWrapper wrapper = _wrap();
        assertEq(address(wrapper).codehash, TalismanInCraft.wrapperCodehash());
    }
}
