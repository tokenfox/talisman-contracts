// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {TalismanInCraftWrapper} from "../../src/thevessel/TalismanInCraftWrapper.sol";
import {MockVessel} from "./mocks/MockVessel.sol";
import {MockTalismans} from "../mocks/MockTalismans.sol";
import {MockRelics} from "./mocks/MockRelics.sol";

/// @dev A contract craft holder with no ERC-721 receiver hook.
contract BareCraftOwner {
    function unwrap(TalismanInCraftWrapper wrapper) external {
        wrapper.unwrap();
    }
}

/// @dev A contract craft holder that tries to unwrap again from inside the
///      Talisman's receiver hook.
contract ReentrantCraftOwner {
    TalismanInCraftWrapper internal _wrapper;
    bytes public reentryError;
    uint256 public received;

    function unwrap(TalismanInCraftWrapper wrapper) external {
        _wrapper = wrapper;
        wrapper.unwrap();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        ++received;
        try _wrapper.unwrap() {}
        catch (bytes memory err) {
            reentryError = err;
        }
        return this.onERC721Received.selector;
    }
}

/// @dev Unit suite against mocks etched at the wrapper's constant addresses. The
///      live Vessel, Talismans and transfer validator are covered by
///      TalismanInCraftWrapperFork.t.sol and TalismanInCraftWrapperPolicyFork.t.sol.
contract TalismanInCraftWrapperTest is Test {
    MockVessel internal vessel;
    MockTalismans internal talismans;

    address internal holder = makeAddr("holder");
    address internal buyer = makeAddr("buyer");

    uint256 internal constant TALISMAN = 7;
    uint256 internal constant CRAFT = 1364; // 37 cols: 36 full rows + one 32-cell address row

    function setUp() public {
        vm.etch(address(0xECb92Cc7112b80A2234936315BbB493fb48d1463), address(new MockVessel()).code);
        vm.etch(address(0x724D5bEffe9A84a87AD1Af83713F80600E5f5774), address(new MockTalismans()).code);
        vessel = MockVessel(0xECb92Cc7112b80A2234936315BbB493fb48d1463);
        talismans = MockTalismans(0x724D5bEffe9A84a87AD1Af83713F80600E5f5774);
        talismans.mint(holder, TALISMAN);
        vm.deal(holder, 10 ether);
    }

    function _image(uint256 craftId) internal pure returns (bytes memory image) {
        image = new bytes(craftId - 32);
        for (uint256 i; i < image.length; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            image[i] = bytes1(uint8(i % 251) + 1);
        }
    }

    function _wrap(uint256 craftId) internal returns (TalismanInCraftWrapper wrapper) {
        address predicted = vm.computeCreateAddress(holder, vm.getNonce(holder));
        vm.startPrank(holder);
        talismans.approve(predicted, TALISMAN);
        wrapper = new TalismanInCraftWrapper{value: craftId * 0.00001 ether}(TALISMAN, craftId, _image(craftId));
        vm.stopPrank();
        assertEq(address(wrapper), predicted);
    }

    function _relics(MockRelics.Answer answer) internal returns (MockRelics relics) {
        relics = new MockRelics();
        relics.setAnswer(answer);
        vessel.setRelics(address(relics));
    }

    function _assertUnwrapKeepsArt(TalismanInCraftWrapper wrapper) internal {
        vm.prank(holder);
        wrapper.unwrap();
        assertEq(talismans.ownerOf(TALISMAN), holder);
        assertEq(vessel.storedPayload(CRAFT), bytes.concat(_image(CRAFT), abi.encode(address(wrapper))));
        assertTrue(wrapper.unwrapped());
    }

    function _expectWrapReverts(uint256 craftId, uint256 value, bytes memory image, bytes memory err) internal {
        address predicted = vm.computeCreateAddress(holder, vm.getNonce(holder));
        vm.startPrank(holder);
        talismans.approve(predicted, TALISMAN);
        vm.expectRevert(err);
        new TalismanInCraftWrapper{value: value}(TALISMAN, craftId, image);
        vm.stopPrank();
        assertEq(talismans.ownerOf(TALISMAN), holder);
    }

    // --- wrapping -------------------------------------------------------------

    function test_Wrap_ClaimsCraftWithImageAndAddressWord() public {
        TalismanInCraftWrapper wrapper = _wrap(CRAFT);
        assertEq(vessel.craftToPayload(CRAFT), bytes.concat(_image(CRAFT), abi.encode(address(wrapper))));
        assertEq(vessel.craftToPayload(CRAFT).length, CRAFT);
    }

    function test_Wrap_HandsCraftToDeployerAndTakesTalisman() public {
        TalismanInCraftWrapper wrapper = _wrap(CRAFT);
        assertEq(vessel.ownerOf(CRAFT), holder);
        assertEq(talismans.ownerOf(TALISMAN), address(wrapper));
        assertEq(wrapper.talismanId(), TALISMAN);
        assertEq(wrapper.craftId(), CRAFT);
        assertFalse(wrapper.unwrapped());
    }

    function test_Wrap_DelegatesCraftToWrapperAsSteward() public {
        TalismanInCraftWrapper wrapper = _wrap(CRAFT);
        assertEq(vessel.craftToDelegate(CRAFT), address(wrapper));
        assertEq(vessel.craftToRole(CRAFT), 2);
    }

    function test_Wrap_RevertsOnMachine() public {
        vessel.setType(CRAFT, true, false);
        _expectWrapReverts(
            CRAFT,
            CRAFT * 0.00001 ether,
            _image(CRAFT),
            abi.encodeWithSelector(TalismanInCraftWrapper.NotCapsule.selector)
        );
    }

    function test_Wrap_RevertsOnVault() public {
        vessel.setType(CRAFT, false, true);
        _expectWrapReverts(
            CRAFT,
            CRAFT * 0.00001 ether,
            _image(CRAFT),
            abi.encodeWithSelector(TalismanInCraftWrapper.NotCapsule.selector)
        );
    }

    function test_Wrap_RevertsOnRelic() public {
        vessel.setRelic(CRAFT, true);
        _expectWrapReverts(
            CRAFT,
            CRAFT * 0.00001 ether,
            _image(CRAFT),
            abi.encodeWithSelector(TalismanInCraftWrapper.NotCapsule.selector)
        );
    }

    function test_Wrap_RevertsOnRevertingRelics() public {
        _relics(MockRelics.Answer.Reverts);
        _expectWrapReverts(
            CRAFT,
            CRAFT * 0.00001 ether,
            _image(CRAFT),
            abi.encodeWithSelector(TalismanInCraftWrapper.NotCapsule.selector)
        );
    }

    function test_Wrap_RevertsOnCodelessRelics() public {
        vessel.setRelics(address(0));
        _expectWrapReverts(
            CRAFT,
            CRAFT * 0.00001 ether,
            _image(CRAFT),
            abi.encodeWithSelector(TalismanInCraftWrapper.NotCapsule.selector)
        );
    }

    function test_Wrap_RevertsOnShortRelicsAnswer() public {
        _relics(MockRelics.Answer.ShortWord);
        _expectWrapReverts(
            CRAFT,
            CRAFT * 0.00001 ether,
            _image(CRAFT),
            abi.encodeWithSelector(TalismanInCraftWrapper.NotCapsule.selector)
        );
    }

    function test_Wrap_WithExternalRelicsAnsweringFalse() public {
        _relics(MockRelics.Answer.NotRelic);
        TalismanInCraftWrapper wrapper = _wrap(CRAFT);
        assertEq(talismans.ownerOf(TALISMAN), address(wrapper));
    }

    function test_Wrap_RevertsOnWrongImageLength() public {
        _expectWrapReverts(
            CRAFT,
            CRAFT * 0.00001 ether,
            _image(CRAFT - 1),
            abi.encodeWithSelector(TalismanInCraftWrapper.WrongImageLength.selector)
        );
    }

    function test_Wrap_RevertsOnWrongPrice() public {
        _expectWrapReverts(
            CRAFT, CRAFT * 0.00001 ether - 1, _image(CRAFT), abi.encodeWithSelector(MockVessel.PriceIncorrect.selector)
        );
    }

    // A craft someone else claimed cannot be wrapped into, paid for or not.
    function test_Wrap_RevertsOnCraftHeldByAnother() public {
        _claimTo(buyer, CRAFT);
        _expectWrapReverts(
            CRAFT,
            CRAFT * 0.00001 ether,
            _image(CRAFT),
            abi.encodeWithSelector(TalismanInCraftWrapper.NotCraftOwner.selector)
        );
        _expectWrapReverts(
            CRAFT, 0, _image(CRAFT), abi.encodeWithSelector(TalismanInCraftWrapper.NotCraftOwner.selector)
        );
    }

    // --- wrapping into a craft the deployer already holds --------------------

    function _claimTo(address to, uint256 id) internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vessel.claim{value: id * 0.00001 ether}(to, ids, "an earlier image", address(0));
    }

    /// @dev Delegates the craft to the next wrapper, approves it, and deploys it with no payment.
    function _wrapHeld(uint256 craftId) internal returns (TalismanInCraftWrapper wrapper) {
        address predicted = vm.computeCreateAddress(holder, vm.getNonce(holder));
        vm.startPrank(holder);
        vessel.setDelegate(craftId, predicted);
        talismans.approve(predicted, TALISMAN);
        wrapper = new TalismanInCraftWrapper(TALISMAN, craftId, _image(craftId));
        vm.stopPrank();
        assertEq(address(wrapper), predicted);
    }

    function _expectHeldWrapReverts(uint256 value, bool delegate, bytes memory err) internal {
        address predicted = vm.computeCreateAddress(holder, vm.getNonce(holder));
        vm.startPrank(holder);
        if (delegate) {
            vessel.setDelegate(CRAFT, predicted);
        }
        talismans.approve(predicted, TALISMAN);
        vm.expectRevert(err);
        new TalismanInCraftWrapper{value: value}(TALISMAN, CRAFT, _image(CRAFT));
        vm.stopPrank();
        assertEq(talismans.ownerOf(TALISMAN), holder);
        assertEq(vessel.storedPayload(CRAFT), bytes("an earlier image"));
    }

    function test_WrapHeld_WritesImageAndKeepsCraftWithDeployer() public {
        _claimTo(holder, CRAFT);
        uint8 role = vessel.craftToRole(CRAFT);
        TalismanInCraftWrapper wrapper = _wrapHeld(CRAFT);
        assertEq(vessel.storedPayload(CRAFT), bytes.concat(_image(CRAFT), abi.encode(address(wrapper))));
        assertEq(vessel.ownerOf(CRAFT), holder);
        assertEq(vessel.craftToDelegate(CRAFT), address(wrapper));
        assertEq(vessel.craftToRole(CRAFT), role, "nothing is claimed, so the claim traits stay");
        assertEq(talismans.ownerOf(TALISMAN), address(wrapper));
        assertEq(address(wrapper).balance, 0);
    }

    function test_WrapHeld_UnwrapBySuccessorBlanks() public {
        _claimTo(holder, CRAFT);
        TalismanInCraftWrapper wrapper = _wrapHeld(CRAFT);
        vm.prank(holder);
        vessel.transferFrom(holder, buyer, CRAFT);
        vm.prank(buyer);
        wrapper.unwrap();
        assertEq(talismans.ownerOf(TALISMAN), buyer);
        assertEq(vessel.storedPayload(CRAFT).length, 0);
    }

    function test_WrapHeld_RevertsWithoutDelegate() public {
        _claimTo(holder, CRAFT);
        _expectHeldWrapReverts(0, false, abi.encodeWithSelector(TalismanInCraftWrapper.WrapperNotDelegate.selector));
    }

    function test_WrapHeld_RevertsWhenLocked() public {
        _claimTo(holder, CRAFT);
        vessel.setLocked(CRAFT, true);
        _expectHeldWrapReverts(0, true, abi.encodeWithSelector(TalismanInCraftWrapper.CraftLocked.selector));
    }

    // Nothing is claimed, so ETH sent along would be stranded in the wrapper.
    function test_WrapHeld_RevertsWithPayment() public {
        _claimTo(holder, CRAFT);
        _expectHeldWrapReverts(
            CRAFT * 0.00001 ether, true, abi.encodeWithSelector(TalismanInCraftWrapper.UnexpectedPayment.selector)
        );
    }

    // Anyone holding a Talisman and a craft can wrap one into the other.
    function test_WrapHeld_AnyHolderWrapsIntoTheirCraft() public {
        _claimTo(buyer, CRAFT);
        talismans.mint(buyer, 99);
        address predicted = vm.computeCreateAddress(buyer, vm.getNonce(buyer));
        vm.startPrank(buyer);
        vessel.setDelegate(CRAFT, predicted);
        talismans.approve(predicted, 99);
        TalismanInCraftWrapper wrapper = new TalismanInCraftWrapper(99, CRAFT, _image(CRAFT));
        vm.stopPrank();
        assertEq(talismans.ownerOf(99), address(wrapper));
        assertEq(vessel.ownerOf(CRAFT), buyer);
        assertEq(vessel.storedPayload(CRAFT), bytes.concat(_image(CRAFT), abi.encode(address(wrapper))));
    }

    function test_Wrap_RevertsWithoutApproval() public {
        vm.prank(holder);
        vm.expectRevert();
        new TalismanInCraftWrapper{value: CRAFT * 0.00001 ether}(TALISMAN, CRAFT, _image(CRAFT));
        assertEq(talismans.ownerOf(TALISMAN), holder);
        assertFalse(vessel.craftToClaimed(CRAFT));
    }

    // Nobody can wrap someone else's Talisman, even with that holder's
    // approval: the Talisman is pulled from the deployer.
    function test_Wrap_RevertsWhenDeployerDoesNotOwnTalisman() public {
        address collector = makeAddr("collector");
        talismans.mint(collector, 99);
        vm.prank(collector);
        talismans.approve(vm.computeCreateAddress(holder, vm.getNonce(holder)), 99);
        vm.prank(holder);
        vm.expectRevert();
        new TalismanInCraftWrapper{value: CRAFT * 0.00001 ether}(99, CRAFT, _image(CRAFT));
        assertEq(talismans.ownerOf(99), collector);
        assertFalse(vessel.craftToClaimed(CRAFT));
    }

    function test_Wrap_AnyHolderWrapsTheirTalisman() public {
        address collector = makeAddr("collector");
        vm.deal(collector, 1 ether);
        talismans.mint(collector, 99);
        vm.startPrank(collector);
        talismans.approve(vm.computeCreateAddress(collector, vm.getNonce(collector)), 99);
        TalismanInCraftWrapper wrapper =
            new TalismanInCraftWrapper{value: CRAFT * 0.00001 ether}(99, CRAFT, _image(CRAFT));
        vm.stopPrank();
        assertEq(talismans.ownerOf(99), address(wrapper));
        assertEq(vessel.ownerOf(CRAFT), collector);
    }

    // The released, verified wrapper. A change here means a different wrapper, which
    // frontends and the transfer-policy exemption would not recognise.
    function test_CodehashIsTheReleasedOne() public pure {
        assertEq(
            keccak256(type(TalismanInCraftWrapper).runtimeCode),
            0x20b85506f7e46a35bd50b146a0ecf299b693e651c93e9d2c430c2d2a5d3309f8
        );
    }

    function test_Wrap_SameCodeHashForEveryWrapper() public {
        TalismanInCraftWrapper a = _wrap(CRAFT);
        talismans.mint(holder, TALISMAN + 1);
        address predicted = vm.computeCreateAddress(holder, vm.getNonce(holder));
        vm.startPrank(holder);
        talismans.approve(predicted, TALISMAN + 1);
        TalismanInCraftWrapper b =
            new TalismanInCraftWrapper{value: 1154 * 0.00001 ether}(TALISMAN + 1, 1154, _image(1154));
        vm.stopPrank();
        assertEq(address(a).codehash, address(b).codehash);
        assertEq(address(a).codehash, keccak256(type(TalismanInCraftWrapper).runtimeCode));
    }

    // --- no way in after birth -----------------------------------------------

    function test_NoWayIn_SafeTransferOfAnotherTalismanReverts() public {
        TalismanInCraftWrapper wrapper = _wrap(CRAFT);
        talismans.mint(holder, 99);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(wrapper)));
        talismans.safeTransferFrom(holder, address(wrapper), 99);
    }

    function test_NoWayIn_SafeTransferOfTheCraftReverts() public {
        TalismanInCraftWrapper wrapper = _wrap(CRAFT);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(wrapper)));
        vessel.safeTransferFrom(holder, address(wrapper), CRAFT);
    }

    function test_NoWayIn_TalismanRejectedAfterUnwrap() public {
        TalismanInCraftWrapper wrapper = _wrap(CRAFT);
        vm.prank(holder);
        wrapper.unwrap();
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(wrapper)));
        talismans.safeTransferFrom(holder, address(wrapper), TALISMAN);
    }

    // --- unwrap --------------------------------------------------------------

    function test_Unwrap_ReturnsTalismanAndBlanksCraft() public {
        TalismanInCraftWrapper wrapper = _wrap(CRAFT);
        vm.prank(holder);
        wrapper.unwrap();
        assertEq(talismans.ownerOf(TALISMAN), holder);
        assertEq(vessel.craftToPayload(CRAFT).length, 0);
        assertTrue(wrapper.unwrapped());
    }

    function test_Unwrap_OnlyCurrentCraftOwnerAfterSale() public {
        TalismanInCraftWrapper wrapper = _wrap(CRAFT);
        vm.prank(holder);
        vessel.transferFrom(holder, buyer, CRAFT);

        vm.prank(holder);
        vm.expectRevert(TalismanInCraftWrapper.NotCraftOwner.selector);
        wrapper.unwrap();

        vm.prank(buyer);
        wrapper.unwrap();
        assertEq(talismans.ownerOf(TALISMAN), buyer);
    }

    function test_Unwrap_DelegateCannotUnwrap() public {
        TalismanInCraftWrapper wrapper = _wrap(CRAFT);
        address delegate = makeAddr("delegate");
        vm.prank(holder);
        vessel.setDelegate(CRAFT, delegate);
        vm.prank(delegate);
        vm.expectRevert(TalismanInCraftWrapper.NotCraftOwner.selector);
        wrapper.unwrap();
    }

    function test_Unwrap_OnlyOnce() public {
        TalismanInCraftWrapper wrapper = _wrap(CRAFT);
        vm.prank(holder);
        wrapper.unwrap();
        vm.prank(holder);
        vm.expectRevert(TalismanInCraftWrapper.AlreadyUnwrapped.selector);
        wrapper.unwrap();
    }

    function test_Unwrap_RevertsWhenDelegateClearedThenSucceedsAfterRedelegation() public {
        TalismanInCraftWrapper wrapper = _wrap(CRAFT);
        vm.prank(holder);
        vessel.setDelegate(CRAFT, address(0));
        vm.prank(holder);
        vm.expectRevert(TalismanInCraftWrapper.WrapperNotDelegate.selector);
        wrapper.unwrap();

        vm.startPrank(holder);
        vessel.setDelegate(CRAFT, address(wrapper));
        wrapper.unwrap();
        vm.stopPrank();
        assertEq(talismans.ownerOf(TALISMAN), holder);
        assertEq(vessel.craftToPayload(CRAFT).length, 0);
    }

    function test_Unwrap_LockedCraftKeepsArtAndReturnsTalisman() public {
        TalismanInCraftWrapper wrapper = _wrap(CRAFT);
        vessel.setLocked(CRAFT, true);
        vm.prank(holder);
        vessel.setDelegate(CRAFT, address(0));
        vm.prank(holder);
        wrapper.unwrap();
        assertEq(talismans.ownerOf(TALISMAN), holder);
        assertEq(vessel.craftToPayload(CRAFT).length, CRAFT);
    }

    function test_Unwrap_RelicCraftKeepsArtAndReturnsTalisman() public {
        TalismanInCraftWrapper wrapper = _wrap(CRAFT);
        vessel.setRelic(CRAFT, true);
        _assertUnwrapKeepsArt(wrapper);
        assertEq(vessel.craftToPayload(CRAFT), "relic");
    }

    function test_Unwrap_RelicsSwappedToRelicKeepsArtAndReturnsTalisman() public {
        TalismanInCraftWrapper wrapper = _wrap(CRAFT);
        _relics(MockRelics.Answer.Relic);
        _assertUnwrapKeepsArt(wrapper);
    }

    function test_Unwrap_RelicsSwappedToRevertingKeepsArtAndReturnsTalisman() public {
        TalismanInCraftWrapper wrapper = _wrap(CRAFT);
        _relics(MockRelics.Answer.Reverts);
        _assertUnwrapKeepsArt(wrapper);
    }

    function test_Unwrap_RelicsSwappedToZeroAddressKeepsArtAndReturnsTalisman() public {
        TalismanInCraftWrapper wrapper = _wrap(CRAFT);
        vessel.setRelics(address(0));
        _assertUnwrapKeepsArt(wrapper);
    }

    function test_Unwrap_RelicsSwappedToCodelessKeepsArtAndReturnsTalisman() public {
        TalismanInCraftWrapper wrapper = _wrap(CRAFT);
        vessel.setRelics(makeAddr("codeless"));
        _assertUnwrapKeepsArt(wrapper);
    }

    function test_Unwrap_RelicsSwappedToShortAnswerKeepsArtAndReturnsTalisman() public {
        TalismanInCraftWrapper wrapper = _wrap(CRAFT);
        _relics(MockRelics.Answer.ShortWord);
        _assertUnwrapKeepsArt(wrapper);
    }

    function test_Unwrap_RelicsSwappedToNonBoolAnswerKeepsArtAndReturnsTalisman() public {
        TalismanInCraftWrapper wrapper = _wrap(CRAFT);
        _relics(MockRelics.Answer.NonBoolWord);
        _assertUnwrapKeepsArt(wrapper);
    }

    function test_Unwrap_TwoFacedRevertingRelicsKeepsArtAndReturnsTalisman() public {
        TalismanInCraftWrapper wrapper = _wrap(CRAFT);
        _relics(MockRelics.Answer.TwoFacedReverts);
        _assertUnwrapKeepsArt(wrapper);
    }

    function test_Unwrap_TwoFacedRelicRelicsKeepsArtAndReturnsTalisman() public {
        TalismanInCraftWrapper wrapper = _wrap(CRAFT);
        _relics(MockRelics.Answer.TwoFacedRelic);
        _assertUnwrapKeepsArt(wrapper);
    }

    // Whatever gas the caller sends, an unwrap that succeeds has blanked a
    // writable craft: starving the ignored write cannot keep the art.
    function test_Unwrap_NoGasLimitSucceedsWithoutBlanking() public {
        TalismanInCraftWrapper wrapper = _wrap(CRAFT);
        bytes memory blank = "";
        for (uint256 g = 30_000; g < 400_000; g += 1_500) {
            uint256 snapshot = vm.snapshotState();
            vm.prank(holder);
            try wrapper.unwrap{gas: g}() {
                assertEq(vessel.storedPayload(CRAFT), blank, "an unwrap that succeeded kept the art");
            } catch {}
            vm.revertToState(snapshot);
        }
    }

    function test_Unwrap_RelicsSwappedToFalseStillBlanks() public {
        TalismanInCraftWrapper wrapper = _wrap(CRAFT);
        _relics(MockRelics.Answer.NotRelic);
        vm.prank(holder);
        wrapper.unwrap();
        assertEq(talismans.ownerOf(TALISMAN), holder);
        assertEq(vessel.craftToPayload(CRAFT).length, 0);
    }

    function test_Unwrap_ContractOwnerWithoutReceiverRevertsAndStaysWrapped() public {
        TalismanInCraftWrapper wrapper = _wrap(CRAFT);
        BareCraftOwner owner = new BareCraftOwner();
        vm.prank(holder);
        vessel.transferFrom(holder, address(owner), CRAFT);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(owner)));
        owner.unwrap(wrapper);
        assertFalse(wrapper.unwrapped());
        assertEq(talismans.ownerOf(TALISMAN), address(wrapper));
        assertEq(vessel.craftToPayload(CRAFT).length, CRAFT);
    }

    function test_Unwrap_ReentrantReceiverGetsTalismanOnce() public {
        TalismanInCraftWrapper wrapper = _wrap(CRAFT);
        ReentrantCraftOwner owner = new ReentrantCraftOwner();
        vm.prank(holder);
        vessel.transferFrom(holder, address(owner), CRAFT);
        owner.unwrap(wrapper);
        assertEq(owner.received(), 1);
        assertEq(owner.reentryError(), abi.encodeWithSelector(TalismanInCraftWrapper.AlreadyUnwrapped.selector));
        assertEq(talismans.ownerOf(TALISMAN), address(owner));
        assertEq(vessel.craftToPayload(CRAFT).length, 0);
    }

    function test_Unwrap_BuyerMustRedelegateWhenSellerKeptDelegate() public {
        TalismanInCraftWrapper wrapper = _wrap(CRAFT);
        vm.startPrank(holder);
        vessel.setDelegate(CRAFT, holder);
        vessel.transferFrom(holder, buyer, CRAFT);
        vm.stopPrank();
        // The delegate survives a transfer, so the seller still holds it.
        assertEq(vessel.craftToDelegate(CRAFT), holder);

        vm.prank(buyer);
        vm.expectRevert(TalismanInCraftWrapper.WrapperNotDelegate.selector);
        wrapper.unwrap();
        vm.prank(holder);
        vm.expectRevert(TalismanInCraftWrapper.NotCraftOwner.selector);
        wrapper.unwrap();

        vm.startPrank(buyer);
        vessel.setDelegate(CRAFT, address(wrapper));
        wrapper.unwrap();
        vm.stopPrank();
        assertEq(talismans.ownerOf(TALISMAN), buyer);
        assertEq(vessel.craftToPayload(CRAFT).length, 0);
    }

    function test_Unwrap_AfterHolderOverwritesCraft() public {
        TalismanInCraftWrapper wrapper = _wrap(CRAFT);
        vm.startPrank(holder);
        vessel.setPayloadHolder(CRAFT, hex"deadbeef");
        wrapper.unwrap();
        vm.stopPrank();
        assertEq(talismans.ownerOf(TALISMAN), holder);
        assertEq(vessel.craftToPayload(CRAFT).length, 0);
    }

    // --- stranding (expected) --------------------------------------------------

    function test_Strand_PlainTransferIntoUnwrappedWrapperIsUnrecoverable() public {
        TalismanInCraftWrapper wrapper = _wrap(CRAFT);
        vm.startPrank(holder);
        wrapper.unwrap();
        // A plain transferFrom skips the receiver check, and the wrapper has no way out after unwrap.
        talismans.transferFrom(holder, address(wrapper), TALISMAN);
        vm.expectRevert(TalismanInCraftWrapper.AlreadyUnwrapped.selector);
        wrapper.unwrap();
        vm.stopPrank();
        assertEq(talismans.ownerOf(TALISMAN), address(wrapper));
    }

    function test_Strand_CraftSentToItsOwnWrapperIsUnrecoverable() public {
        TalismanInCraftWrapper wrapper = _wrap(CRAFT);
        vm.prank(holder);
        vessel.transferFrom(holder, address(wrapper), CRAFT);
        // The wrapper owns its craft but never calls unwrap itself, so no one can.
        vm.prank(holder);
        vm.expectRevert(TalismanInCraftWrapper.NotCraftOwner.selector);
        wrapper.unwrap();
        assertEq(vessel.ownerOf(CRAFT), address(wrapper));
        assertEq(talismans.ownerOf(TALISMAN), address(wrapper));
    }
}
