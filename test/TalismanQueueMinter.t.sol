// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {TalismanQueueMinter} from "../src/TalismanQueueMinter.sol";
import {Talismans} from "../src/Talismans.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

interface Ownable2StepLike {
    function acceptOwnership() external;
}

contract EthRejector {
    function callWithdraw(TalismanQueueMinter minter) external {
        minter.withdraw();
    }

    function callWithdrawErc20(TalismanQueueMinter minter, IERC20 token) external {
        minter.withdrawErc20(token);
    }

    function acceptOwnership(address ownable) external {
        Ownable2StepLike(ownable).acceptOwnership();
    }

    receive() external payable {
        revert("nope");
    }
}

contract ReentrantWithdrawer {
    TalismanQueueMinter public minter;
    bool public attempted;
    bytes public lastInnerError;

    function setMinter(TalismanQueueMinter m) external {
        minter = m;
    }

    function callWithdraw() external {
        minter.withdraw();
    }

    function acceptOwnership(address ownable) external {
        Ownable2StepLike(ownable).acceptOwnership();
    }

    receive() external payable {
        if (!attempted) {
            attempted = true;
            try minter.withdraw() {}
            catch (bytes memory err) {
                lastInnerError = err;
            }
        }
    }
}

contract ReentrantMinter {
    TalismanQueueMinter public minter;
    bool public attempted;
    bytes public lastInnerError;

    function setMinter(TalismanQueueMinter m) external {
        minter = m;
    }

    function queue() external {
        minter.queueToMint();
    }

    function callMint(uint256 value) external payable {
        minter.mint{value: value}();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (!attempted) {
            attempted = true;
            try minter.mint() {}
            catch (bytes memory err) {
                lastInnerError = err;
            }
        }
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

contract TalismanQueueMinterTest is Test {
    using stdStorage for StdStorage;

    Talismans internal nft;
    TalismanQueueMinter internal minter;

    address internal owner = address(this);
    address internal treasury = address(0xBEEF);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCAFE);
    address internal dave = address(0xD00D);

    uint256 internal constant PRICE = 0.05 ether;
    uint256 internal constant SALE_DURATION = 1 hours;
    // setUp rolls to block 100 and picks 102 as the first mintable block, so an
    // entry queued in setUp blocks waits two blocks before it may mint — same
    // anti-bot story the prior BLOCK_DELAY constant gave, but expressed through
    // the new firstMintableBlockNumber parameter.
    uint256 internal constant FIRST_MINTABLE_BLOCK = 102;
    uint256 internal constant SPOTS_PER_BLOCK = 2;

    uint256 internal saleStart;
    uint256 internal saleEnd;

    function setUp() public {
        nft = new Talismans();
        minter = new TalismanQueueMinter(nft);
        nft.setMinter(address(minter));
        // Hand Talismans ownership to a plain address so concludeMint's
        // _safeMint-to-owner lands on an EOA-style receiver, not this test
        // contract (which doesn't implement onERC721Received).
        nft.transferOwnership(treasury);
        vm.prank(treasury);
        nft.acceptOwnership();

        vm.roll(100);
        vm.warp(1_700_000_000);
        saleStart = block.timestamp;
        saleEnd = saleStart + SALE_DURATION;
        minter.setMintConfig(saleStart, saleEnd, PRICE, FIRST_MINTABLE_BLOCK, SPOTS_PER_BLOCK);
    }

    // ─── helpers ──────────────────────────────────────────────────────────────

    function _queue(address who) internal {
        vm.prank(who);
        minter.queueToMint();
    }

    function _mint(address who, uint256 value) internal {
        vm.deal(who, value);
        vm.prank(who);
        minter.mint{value: value}();
    }

    function _readMintConfig() internal view returns (uint256 s, uint256 e, uint256 p, uint256 f, uint256 b) {
        (s, e, p, f, b) = minter.mintConfig();
    }

    function _forceQueueLength(uint256 v) internal {
        stdstore.target(address(minter)).sig(minter.mintingQueueLength.selector).checked_write(v);
    }

    function _forceQueueOf(address who, uint256 eligible) internal {
        stdstore.target(address(minter)).sig(minter.queueOf.selector).with_key(who).checked_write(eligible);
    }

    // ─── setMintConfig ────────────────────────────────────────────────────────

    function test_setMintConfig_emitsEventAndStores() public {
        vm.expectEmit(true, true, true, true);
        emit TalismanQueueMinter.MintConfigUpdated(123, 456, 789, 1000, 5);
        minter.setMintConfig(123, 456, 789, 1000, 5);

        (uint256 s, uint256 e, uint256 p, uint256 f, uint256 b) = _readMintConfig();
        assertEq(s, 123, "startTime");
        assertEq(e, 456, "mintEndTime");
        assertEq(p, 789, "mintPrice");
        assertEq(f, 1000, "firstMintableBlockNumber");
        assertEq(b, 5, "spotsPerBlock");
    }

    function test_setMintConfig_allowsUnconfiguredZeroStart() public {
        // Once unconfigured, queue entries revert MintNotConfigured even with
        // non-zero mintEndTime / mintPrice — the startTime == 0 sentinel takes
        // precedence and also short-circuits the spotsPerBlock != 0 check.
        minter.setMintConfig(0, 0, 0, 0, 0);
        minter.setMintConfig(0, 1, 1, 50, 0); // valid: startTime == 0 lets zero spotsPerBlock through
        (uint256 s,,,,) = _readMintConfig();
        assertEq(s, 0);
    }

    function test_setMintConfig_revertsWhenEndNotAfterStart() public {
        vm.expectRevert(TalismanQueueMinter.InvalidMintConfig.selector);
        minter.setMintConfig(100, 100, 1, FIRST_MINTABLE_BLOCK, SPOTS_PER_BLOCK);

        vm.expectRevert(TalismanQueueMinter.InvalidMintConfig.selector);
        minter.setMintConfig(100, 99, 1, FIRST_MINTABLE_BLOCK, SPOTS_PER_BLOCK);
    }

    function test_setMintConfig_revertsOnZeroSpotsPerBlock() public {
        vm.expectRevert(TalismanQueueMinter.InvalidMintConfig.selector);
        minter.setMintConfig(saleStart, saleEnd, PRICE, FIRST_MINTABLE_BLOCK, 0);
    }

    function test_setMintConfig_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        minter.setMintConfig(1, 2, 3, 4, 5);
    }

    // ─── queueToMint ──────────────────────────────────────────────────────────

    function test_queueToMint_setsEligibleBlockAndIncrementsQueue() public {
        vm.expectEmit(true, true, true, true);
        emit TalismanQueueMinter.Queued(alice, FIRST_MINTABLE_BLOCK, 1);
        _queue(alice);

        assertEq(minter.queueOf(alice), FIRST_MINTABLE_BLOCK, "slot 0 -> firstMintableBlockNumber");
        assertEq(minter.mintingQueueLength(), 1, "queueLength");
        assertEq(minter.totalQueued(), 1, "totalQueued");
    }

    function test_queueToMint_packsSpotsPerBlockBeforeAdvancing() public {
        // SPOTS_PER_BLOCK == 2: the first two queuers share the head block; the
        // next two share the block after; etc.
        _queue(alice);
        _queue(bob);
        _queue(carol);
        _queue(dave);

        assertEq(minter.queueOf(alice), FIRST_MINTABLE_BLOCK, "slot 0");
        assertEq(minter.queueOf(bob), FIRST_MINTABLE_BLOCK, "slot 1 shares the head block");
        assertEq(minter.queueOf(carol), FIRST_MINTABLE_BLOCK + 1, "slot 2 advances one block");
        assertEq(minter.queueOf(dave), FIRST_MINTABLE_BLOCK + 1, "slot 3 shares with slot 2");
        assertEq(minter.mintingQueueLength(), 4);
        assertEq(minter.totalQueued(), 4);
    }

    function test_queueToMint_advancesEveryBlockWhenSpotsPerBlockIsOne() public {
        // Tighten layout to one slot per block: queuers march block-by-block.
        minter.setMintConfig(saleStart, saleEnd, PRICE, FIRST_MINTABLE_BLOCK, 1);

        _queue(alice);
        _queue(bob);
        _queue(carol);

        assertEq(minter.queueOf(alice), FIRST_MINTABLE_BLOCK);
        assertEq(minter.queueOf(bob), FIRST_MINTABLE_BLOCK + 1);
        assertEq(minter.queueOf(carol), FIRST_MINTABLE_BLOCK + 2);
    }

    /// @dev A successful mint by an earlier queuer must not change the later
    ///      queuers' eligible blocks — slot indices, once issued, are fixed.
    function test_queueToMint_existingEntriesKeepTheirEligibleBlocks() public {
        _queue(alice);
        _queue(bob);
        uint256 bobEligible = minter.queueOf(bob);

        vm.roll(minter.queueOf(alice));
        _mint(alice, PRICE);

        assertEq(minter.queueOf(bob), bobEligible, "bob's eligibleBlock must not shift");
        assertEq(minter.mintingQueueLength(), 1);
        assertEq(minter.totalQueued(), 2, "totalQueued is monotonic");
    }

    function test_queueToMint_revertsWhenAlreadyQueued() public {
        _queue(alice);
        vm.prank(alice);
        vm.expectRevert(TalismanQueueMinter.AlreadyQueued.selector);
        minter.queueToMint();
    }

    function test_queueToMint_revertsWhenNotConfigured() public {
        minter.setMintConfig(0, 0, 0, 0, 0);
        vm.prank(alice);
        vm.expectRevert(TalismanQueueMinter.MintNotConfigured.selector);
        minter.queueToMint();
    }

    function test_queueToMint_revertsBeforeStart() public {
        minter.setMintConfig(block.timestamp + 10, block.timestamp + 100, PRICE, FIRST_MINTABLE_BLOCK, SPOTS_PER_BLOCK);
        vm.prank(alice);
        vm.expectRevert(TalismanQueueMinter.MintNotStarted.selector);
        minter.queueToMint();
    }

    function test_queueToMint_revertsAtMintEndTime() public {
        vm.warp(saleEnd);
        vm.prank(alice);
        vm.expectRevert(TalismanQueueMinter.MintEnded.selector);
        minter.queueToMint();
    }

    function test_queueToMint_revertsAfterMintEnded() public {
        vm.warp(saleEnd + 1);
        vm.prank(alice);
        vm.expectRevert(TalismanQueueMinter.MintEnded.selector);
        minter.queueToMint();
    }

    function test_queueToMint_revertsWhenSupplyReserved() public {
        // Inflate the queue all the way to MAX_GENESIS_SUPPLY: every slot is
        // already taken before the next queuer arrives.
        uint256 max = nft.MAX_GENESIS_SUPPLY();
        _forceQueueLength(max);

        vm.prank(alice);
        vm.expectRevert(TalismanQueueMinter.SoldOut.selector);
        minter.queueToMint();
    }

    function test_queueToMint_isNotPayable() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) =
            address(minter).call{value: 1 wei}(abi.encodeWithSelector(TalismanQueueMinter.queueToMint.selector));
        assertFalse(ok, "queueToMint must reject ETH");
    }

    /// @dev When the head block has already been overtaken, late queuers receive
    ///      a slot whose block is in the past — they may mint immediately.
    function test_queueToMint_pastBlockCanMintImmediately() public {
        // Set the head block to 50 — well before vm.roll(100) put the test.
        minter.setMintConfig(saleStart, saleEnd, PRICE, 50, SPOTS_PER_BLOCK);

        _queue(alice);
        assertEq(minter.queueOf(alice), 50, "slot 0 -> head block, in the past");

        // No vm.roll needed; mint succeeds in the same block.
        _mint(alice, PRICE);
        assertEq(nft.balanceOf(alice), 1);
    }

    // ─── mint ─────────────────────────────────────────────────────────────────

    function test_mint_happyPath() public {
        _queue(alice);
        vm.roll(minter.queueOf(alice));
        _mint(alice, PRICE);

        assertEq(nft.balanceOf(alice), 1, "alice receives one token");
        assertEq(nft.genesisMinted(), 1);
    }

    function test_mint_clearsEntryAndDecrementsQueue() public {
        _queue(alice);
        vm.roll(minter.queueOf(alice));
        _mint(alice, PRICE);

        assertEq(minter.queueOf(alice), 0, "queue entry cleared");
        assertEq(minter.mintingQueueLength(), 0, "live queue decremented");
        assertEq(minter.totalQueued(), 1, "totalQueued not rolled back");
    }

    function test_mint_allowsRequeueAfterMint() public {
        _queue(alice);
        vm.roll(minter.queueOf(alice));
        _mint(alice, PRICE);

        // Same wallet may queue again; a fresh slot is consumed.
        _queue(alice);
        // SPOTS_PER_BLOCK == 2: slot 1 still maps to FIRST_MINTABLE_BLOCK.
        assertEq(minter.queueOf(alice), FIRST_MINTABLE_BLOCK);
        assertEq(minter.totalQueued(), 2);
        // block.number is already past FIRST_MINTABLE_BLOCK, so alice mints right away.
        _mint(alice, PRICE);
        assertEq(nft.balanceOf(alice), 2);
    }

    function test_mint_revertsWithoutEntry() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(TalismanQueueMinter.NotQueued.selector);
        minter.mint{value: PRICE}();
    }

    function test_mint_revertsBeforeEligibleBlock() public {
        _queue(alice);
        uint256 eligible = minter.queueOf(alice);

        // One block before eligibility — must revert.
        vm.roll(eligible - 1);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TalismanQueueMinter.QueueNotReady.selector, eligible - 1, eligible));
        minter.mint{value: PRICE}();
    }

    function test_mint_revertsOnUnderpayment() public {
        _queue(alice);
        vm.roll(minter.queueOf(alice));

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TalismanQueueMinter.InsufficientPayment.selector, PRICE - 1, PRICE));
        minter.mint{value: PRICE - 1}();
    }

    function test_mint_acceptsOverpaymentAndKeepsExcess() public {
        _queue(alice);
        vm.roll(minter.queueOf(alice));

        _mint(alice, PRICE + 0.01 ether);
        assertEq(address(minter).balance, PRICE + 0.01 ether, "excess held for sweep");
    }

    /// @dev A wallet that already holds a queue entry may still mint after
    ///      `mintEndTime`; only new queue entries are gated by the window.
    function test_mint_allowedAfterMintEndTime() public {
        _queue(alice);
        vm.roll(minter.queueOf(alice));

        vm.warp(saleEnd + 1 days);
        _mint(alice, PRICE);
        assertEq(nft.balanceOf(alice), 1, "post-window mint of pre-window entry");
    }

    /// @dev The receiver's onERC721Received catches its inner re-entry attempt,
    ///      so the outer mint succeeds and the attacker receives its token —
    ///      what matters is that the inner call was rejected by the guard, not
    ///      that the outer reverted.
    function test_mint_reentryBlocked() public {
        ReentrantMinter attacker = new ReentrantMinter();
        attacker.setMinter(minter);

        attacker.queue();
        vm.roll(minter.queueOf(address(attacker)));

        vm.deal(address(attacker), 1 ether);
        attacker.callMint{value: PRICE}(PRICE);

        assertEq(nft.balanceOf(address(attacker)), 1, "outer mint must succeed");
        assertTrue(attacker.attempted(), "reentry attempt taken inside hook");
        assertEq(
            bytes32(attacker.lastInnerError()),
            bytes32(ReentrancyGuard.ReentrancyGuardReentrantCall.selector),
            "inner mint blocked by ReentrancyGuard"
        );
    }

    // ─── release ──────────────────────────────────────────────────────────────

    function test_release_clearsEntryAndDecrementsQueue() public {
        _queue(alice);
        uint256 eligible = minter.queueOf(alice);

        vm.expectEmit(true, true, true, true);
        emit TalismanQueueMinter.Released(alice, eligible);
        minter.release(alice);

        assertEq(minter.queueOf(alice), 0);
        assertEq(minter.mintingQueueLength(), 0);
        assertEq(minter.totalQueued(), 1, "totalQueued does not roll back on release");
    }

    function test_release_revertsForNonOwner() public {
        _queue(alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        minter.release(alice);
    }

    function test_release_revertsWhenNoEntry() public {
        vm.expectRevert(TalismanQueueMinter.NotQueued.selector);
        minter.release(alice);
    }

    function test_release_allowsRequeueAfterwards() public {
        _queue(alice);
        minter.release(alice);

        _queue(alice);
        // SPOTS_PER_BLOCK == 2: slot 1 / 2 == 0, so alice re-queues onto the head block.
        assertEq(minter.queueOf(alice), FIRST_MINTABLE_BLOCK);
        assertEq(minter.mintingQueueLength(), 1);
        assertEq(minter.totalQueued(), 2, "fresh slot index consumed on requeue");
    }

    /// @dev Releasing an earlier slot must not shift later wallets' assigned
    ///      blocks, and the next queueToMint must still consume a fresh slot.
    function test_release_doesNotShiftSlotsForLaterEntries() public {
        _queue(alice); // slot 0 → FIRST_MINTABLE_BLOCK
        _queue(bob); // slot 1 → FIRST_MINTABLE_BLOCK
        uint256 bobEligible = minter.queueOf(bob);

        minter.release(alice);

        _queue(carol); // slot 2 → FIRST_MINTABLE_BLOCK + 1
        assertEq(minter.queueOf(bob), bobEligible, "bob's slot must not shift");
        assertEq(minter.queueOf(carol), FIRST_MINTABLE_BLOCK + 1, "carol gets the next slot, not alice's");
        assertEq(minter.totalQueued(), 3);
        assertEq(minter.mintingQueueLength(), 2, "alice released, bob + carol live");
    }

    /// @dev When the queue is at the cap, a release must free exactly one supply
    ///      slot — the next queuer succeeds, but a third attempt fails again.
    function test_release_freesExactlyOneSupplySlot() public {
        uint256 max = nft.MAX_GENESIS_SUPPLY();
        // Pre-stage: alice holds a queue entry and the queue counter sits at the cap.
        _forceQueueLength(max);
        _forceQueueOf(alice, FIRST_MINTABLE_BLOCK);

        // Bob cannot queue while alice's slot still counts.
        vm.prank(bob);
        vm.expectRevert(TalismanQueueMinter.SoldOut.selector);
        minter.queueToMint();

        // Owner releases alice → one slot free.
        minter.release(alice);
        assertEq(minter.mintingQueueLength(), max - 1);

        // Bob can now claim it; carol cannot.
        _queue(bob);
        assertEq(minter.mintingQueueLength(), max);
        vm.prank(carol);
        vm.expectRevert(TalismanQueueMinter.SoldOut.selector);
        minter.queueToMint();
    }

    /// @dev A released wallet has no claim on its old eligible block — calling
    ///      mint() afterwards reverts with NotQueued, not QueueNotReady.
    function test_release_revokesMintRight() public {
        _queue(alice);
        minter.release(alice);

        vm.roll(FIRST_MINTABLE_BLOCK + 10);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(TalismanQueueMinter.NotQueued.selector);
        minter.mint{value: PRICE}();
    }

    // ─── concludeMint ─────────────────────────────────────────────────────────

    function test_concludeMint_sweepsToTalismansOwner() public {
        _queue(alice);
        vm.roll(minter.queueOf(alice));
        _mint(alice, PRICE);

        vm.warp(saleEnd);
        uint256 max = nft.MAX_GENESIS_SUPPLY();
        minter.concludeMint(max);

        assertEq(nft.genesisMinted(), max, "genesis filled");
        assertEq(nft.balanceOf(treasury), max - 1, "remainder swept to Talismans owner");
        assertEq(nft.balanceOf(alice), 1, "alice's mint untouched");
    }

    function test_concludeMint_revertsBeforeMintEnded() public {
        vm.expectRevert(TalismanQueueMinter.MintNotEnded.selector);
        minter.concludeMint(1);
    }

    function test_concludeMint_revertsAtMintEndTimeBoundary() public {
        vm.warp(saleEnd - 1);
        vm.expectRevert(TalismanQueueMinter.MintNotEnded.selector);
        minter.concludeMint(1);
    }

    function test_concludeMint_revertsWhenNotConfigured() public {
        minter.setMintConfig(0, 0, 0, 0, 0);
        vm.expectRevert(TalismanQueueMinter.MintNotConfigured.selector);
        minter.concludeMint(1);
    }

    function test_concludeMint_revertsAtZeroQuantity() public {
        vm.warp(saleEnd);
        vm.expectRevert(TalismanQueueMinter.InvalidQuantity.selector);
        minter.concludeMint(0);
    }

    function test_concludeMint_revertsForNonOwner() public {
        vm.warp(saleEnd);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        minter.concludeMint(1);
    }

    /// @dev Live queue entries reserve their slots even after `mintEndTime`. The
    ///      sweep must skip those slots; the queued wallets retain the right to
    ///      mint after the window has closed.
    function test_concludeMint_respectsLiveEntries() public {
        _queue(alice);
        _queue(bob);
        assertEq(minter.mintingQueueLength(), 2);

        vm.warp(saleEnd);
        uint256 max = nft.MAX_GENESIS_SUPPLY();
        minter.concludeMint(max);

        assertEq(nft.genesisMinted(), max - 2, "two slots held back for queued wallets");
        assertEq(nft.balanceOf(treasury), max - 2);

        // Each queued wallet can still mint.
        vm.roll(minter.queueOf(bob));
        _mint(alice, PRICE);
        _mint(bob, PRICE);
        assertEq(nft.genesisMinted(), max, "filled exactly after queued mints");
    }

    function test_concludeMint_revertsWhenAllSlotsReserved() public {
        _forceQueueLength(nft.MAX_GENESIS_SUPPLY());

        vm.warp(saleEnd);
        vm.expectRevert(TalismanQueueMinter.SoldOut.selector);
        minter.concludeMint(1);
    }

    function test_concludeMint_partialSweepAcrossCalls() public {
        vm.warp(saleEnd);
        minter.concludeMint(10);
        assertEq(nft.genesisMinted(), 10);
        minter.concludeMint(5);
        assertEq(nft.genesisMinted(), 15);
    }

    // ─── nextAvailableBlock ───────────────────────────────────────────────────

    function test_nextAvailableBlock_emptyQueue() public view {
        // totalQueued == 0 → slot 0 / spotsPerBlock == 0 → head block.
        assertEq(minter.nextAvailableBlock(), FIRST_MINTABLE_BLOCK);
    }

    /// @dev With SPOTS_PER_BLOCK == 2 the head block accepts two queuers before
    ///      the view advances to the next block.
    function test_nextAvailableBlock_advancesEverySpotsPerBlockEntries() public {
        assertEq(minter.nextAvailableBlock(), FIRST_MINTABLE_BLOCK);
        _queue(alice);
        assertEq(minter.nextAvailableBlock(), FIRST_MINTABLE_BLOCK, "still head block - second spot free");
        _queue(bob);
        assertEq(minter.nextAvailableBlock(), FIRST_MINTABLE_BLOCK + 1, "advances on third entry");
        _queue(carol);
        assertEq(minter.nextAvailableBlock(), FIRST_MINTABLE_BLOCK + 1, "still second block - second spot free");
        _queue(dave);
        assertEq(minter.nextAvailableBlock(), FIRST_MINTABLE_BLOCK + 2, "advances on fifth entry");
    }

    function test_nextAvailableBlock_revertsWhenUnconfigured() public {
        minter.setMintConfig(0, 0, 0, 0, 0);
        vm.expectRevert(TalismanQueueMinter.MintNotConfigured.selector);
        minter.nextAvailableBlock();
    }

    // ─── bot resistance scenarios ─────────────────────────────────────────────

    /// @dev A bot cannot stuff queue + mint into the same block while the head
    ///      block is in the future: the eligible block is FIRST_MINTABLE_BLOCK,
    ///      two ahead of vm.roll(100), so mint reverts.
    function test_botResistance_sameBlockQueueAndMintReverts() public {
        _queue(alice);
        uint256 eligible = minter.queueOf(alice);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TalismanQueueMinter.QueueNotReady.selector, block.number, eligible));
        minter.mint{value: PRICE}();
    }

    /// @dev One block after queueing is still not enough — FIRST_MINTABLE_BLOCK
    ///      is two ahead of the queueing block.
    function test_botResistance_oneBlockLaterStillReverts() public {
        _queue(alice);
        uint256 eligible = minter.queueOf(alice);
        vm.roll(block.number + 1);
        uint256 nowBlock = block.number;

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TalismanQueueMinter.QueueNotReady.selector, nowBlock, eligible));
        minter.mint{value: PRICE}();
    }

    /// @dev Exactly at the eligible block, the mint goes through.
    function test_botResistance_atEligibleBlockSucceeds() public {
        _queue(alice);
        vm.roll(minter.queueOf(alice));
        _mint(alice, PRICE);
        assertEq(nft.balanceOf(alice), 1);
    }

    // ─── withdraw (ETH) ───────────────────────────────────────────────────────

    function test_withdraw_ownerSweepsFullBalance() public {
        vm.deal(address(minter), 5 ether);
        uint256 ownerBefore = owner.balance;

        minter.withdraw();

        assertEq(address(minter).balance, 0);
        assertEq(owner.balance, ownerBefore + 5 ether);
    }

    function test_withdraw_revertsForNonOwner() public {
        vm.deal(address(minter), 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        minter.withdraw();
    }

    function test_withdraw_revertsWhenBalanceZero() public {
        vm.expectRevert(TalismanQueueMinter.NothingToWithdraw.selector);
        minter.withdraw();
    }

    function test_withdraw_includesProceedsFromMint() public {
        _queue(alice);
        vm.roll(minter.queueOf(alice));
        _mint(alice, PRICE + 7 wei);

        assertEq(address(minter).balance, PRICE + 7 wei);

        uint256 ownerBefore = owner.balance;
        minter.withdraw();
        assertEq(owner.balance, ownerBefore + PRICE + 7 wei);
        assertEq(address(minter).balance, 0);
    }

    function test_withdraw_revertsWhenReceiverRejectsEth() public {
        EthRejector rejector = new EthRejector();
        minter.transferOwnership(address(rejector));
        rejector.acceptOwnership(address(minter));

        vm.deal(address(minter), 1 ether);
        vm.expectRevert(bytes("nope"));
        rejector.callWithdraw(minter);

        assertEq(address(minter).balance, 1 ether, "balance preserved after failed sendValue");
    }

    function test_withdraw_reentryBlocked() public {
        ReentrantWithdrawer attacker = new ReentrantWithdrawer();
        attacker.setMinter(minter);
        minter.transferOwnership(address(attacker));
        attacker.acceptOwnership(address(minter));

        vm.deal(address(minter), 2 ether);
        attacker.callWithdraw();

        assertTrue(attacker.attempted(), "reentry attempt taken");
        assertEq(address(attacker).balance, 2 ether, "outer withdraw must succeed");
        assertEq(address(minter).balance, 0);
        assertEq(
            bytes32(attacker.lastInnerError()),
            bytes32(ReentrancyGuard.ReentrancyGuardReentrantCall.selector),
            "inner call blocked by ReentrancyGuard"
        );
    }

    // ─── withdrawErc20 ────────────────────────────────────────────────────────

    function test_withdrawErc20_ownerSweepsBalance() public {
        MockERC20 token = new MockERC20();
        token.mint(address(minter), 1_000e18);

        minter.withdrawErc20(IERC20(address(token)));
        assertEq(token.balanceOf(owner), 1_000e18);
        assertEq(token.balanceOf(address(minter)), 0);
    }

    function test_withdrawErc20_revertsForNonOwner() public {
        MockERC20 token = new MockERC20();
        token.mint(address(minter), 1e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        minter.withdrawErc20(IERC20(address(token)));
    }

    function test_withdrawErc20_revertsWhenBalanceZero() public {
        MockERC20 token = new MockERC20();
        vm.expectRevert(TalismanQueueMinter.NothingToWithdraw.selector);
        minter.withdrawErc20(IERC20(address(token)));
    }

    // ─── end-to-end deposit + recovery ────────────────────────────────────────

    /// @dev Everything deposited into the minter (mint proceeds, stray ETH,
    ///      stray ERC-20) must be fully recoverable by the owner.
    function test_recovery_endToEnd_allFundsRecoverable() public {
        _queue(alice);
        _queue(bob);
        vm.roll(minter.queueOf(bob));
        _mint(alice, PRICE);
        _mint(bob, PRICE + 1 ether); // overpayment

        // Stray ETH sent directly bounces (no receive); force-fund instead.
        vm.deal(carol, 3 ether);
        vm.prank(carol);
        (bool ok,) = address(minter).call{value: 3 ether}("");
        assertFalse(ok, "minter has no receive() - accidental sends bounce");
        vm.deal(address(minter), address(minter).balance + 2 ether);

        MockERC20 token = new MockERC20();
        token.mint(address(minter), 500e18);

        uint256 expectedEth = PRICE + PRICE + 1 ether + 2 ether;
        assertEq(address(minter).balance, expectedEth, "ETH accumulation");

        uint256 ownerEthBefore = owner.balance;
        minter.withdraw();
        assertEq(address(minter).balance, 0, "ETH fully swept");
        assertEq(owner.balance, ownerEthBefore + expectedEth, "owner received all ETH");

        minter.withdrawErc20(IERC20(address(token)));
        assertEq(token.balanceOf(address(minter)), 0, "ERC-20 fully swept");
        assertEq(token.balanceOf(owner), 500e18);
    }

    // ─── ownership ────────────────────────────────────────────────────────────

    function test_ownership_twoStepTransfer() public {
        minter.transferOwnership(alice);
        assertEq(minter.owner(), owner, "ownership not transferred until accepted");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        minter.setMintConfig(1, 2, 3, 4, 5);

        vm.prank(alice);
        minter.acceptOwnership();
        assertEq(minter.owner(), alice);

        vm.prank(alice);
        minter.setMintConfig(1, 2, 3, 4, 5);
    }

    /// @dev Anyone calling a non-existent setMinter on this contract would
    ///      revert; included to confirm the minter has no `setMinter` surface.
    function test_minter_hasNoSetMinter() public {
        (bool ok,) = address(minter).call(abi.encodeWithSignature("setMinter(address)", alice));
        assertFalse(ok, "minter must not expose setMinter");
    }

    // Owner needs receive() to accept ETH from withdraw.
    receive() external payable {}
}
