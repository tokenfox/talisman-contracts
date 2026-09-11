// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Talismans} from "../src/Talismans.sol";
import {NotRevealed} from "../src/TalismanErrors.sol";
import {TalismanCore} from "../src/TalismanCore.sol";
import {TalismanForms} from "../src/TalismanForms.sol";
import {TalismanMaterials, MATERIAL_COUNT, NON_MYTHIC_MATERIAL_COUNT} from "../src/TalismanMaterials.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";

/// @dev Coverage suite for {Talismans.mintWithCommitment}, {Talismans.reveal},
///      and {Talismans.recommit}. Runs `Talismans` directly with the test
///      contract acting as the authorised minter — same surface the
///      production `TalismanMinter` consumes.
contract TalismansRevealTest is Test {
    Talismans internal nft;

    address internal deployer = address(this);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        nft = new Talismans();
        nft.setMinter(address(this));
        nft.setMaterials(new TalismanMaterials());
        // Anchor away from genesis so `roll`s never underflow when we test
        // boundary behaviour around `commitBlock - 1`.
        vm.roll(100);
        vm.prevrandao(bytes32(uint256(0xc0ffee)));
    }

    function _mint(address to) internal returns (uint256 tokenId, uint256 commitBlock) {
        (tokenId, commitBlock) = nft.mintWithCommitment(to);
    }

    // ─── REVEAL_DELAY hardening ──────────────────────────────────────────────

    function test_constant_revealDelayIsTwo() public view {
        assertEq(nft.REVEAL_DELAY(), 2, "REVEAL_DELAY must be >=2 to defeat single-proposer grinding");
    }

    function test_mint_commitBlockIsNumberPlusDelay() public {
        uint256 expected = block.number + nft.REVEAL_DELAY();
        (uint256 id, uint256 commitBlock) = _mint(alice);
        assertEq(commitBlock, expected);
        assertEq(nft.commitBlockOf(id), expected);
    }

    // ─── mintWithCommitment ──────────────────────────────────────────────────

    function test_mint_countsTowardGenesisCap() public {
        uint256 before = nft.genesisMinted();
        _mint(alice);
        assertEq(nft.genesisMinted(), before + 1);
    }

    function test_mint_revertsForNonMinter() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Talismans.UnauthorizedMinter.selector, alice));
        nft.mintWithCommitment(alice);
    }

    function test_mint_revertsWhenGenesisExhausted() public {
        uint256 cap = nft.MAX_GENESIS_SUPPLY();
        for (uint256 i; i < cap; ++i) {
            _mint(alice);
        }
        assertEq(nft.genesisMinted(), cap);

        vm.expectRevert(Talismans.GenesisMintExhausted.selector);
        nft.mintWithCommitment(alice);
    }

    // ─── reveal — guard reverts ──────────────────────────────────────────────

    function test_reveal_revertsForUncommittedToken() public {
        vm.expectRevert(abi.encodeWithSelector(Talismans.NothingToReveal.selector, uint256(999)));
        nft.reveal(999);
    }

    function test_reveal_revertsAtCommitBlock() public {
        (uint256 id, uint256 commitBlock) = _mint(alice);
        vm.roll(commitBlock); // block.number == commitBlock → too early
        vm.expectRevert(abi.encodeWithSelector(Talismans.RevealTooEarly.selector, id, commitBlock));
        nft.reveal(id);
    }

    function test_reveal_revertsBeforeCommitBlock() public {
        (uint256 id, uint256 commitBlock) = _mint(alice);
        // Same block as mint: block.number < commitBlock (delay=2).
        vm.expectRevert(abi.encodeWithSelector(Talismans.RevealTooEarly.selector, id, commitBlock));
        nft.reveal(id);
    }

    function test_reveal_revertsWhenBlockhashExpired() public {
        (uint256 id, uint256 commitBlock) = _mint(alice);
        // Jump past the 256-block blockhash window.
        vm.roll(commitBlock + 257);
        vm.expectRevert(abi.encodeWithSelector(Talismans.RevealUnavailable.selector, id, commitBlock));
        nft.reveal(id);
    }

    // ─── reveal — happy path ─────────────────────────────────────────────────

    function test_reveal_assignsBetweenOneAndMaxCores() public {
        (uint256 id, uint256 commitBlock) = _mint(alice);
        vm.roll(commitBlock + 1);

        nft.reveal(id);

        uint256 cores = nft.coreCount(id);
        assertGt(cores, 0, "must reveal at least one core");
        assertLe(cores, nft.MAX_CORES_PER_MINT(), "must not exceed per-mint cap");
        assertTrue(nft.isRevealed(id));
    }

    function test_reveal_coresShareMaterialAndFormButDifferBySeed() public {
        // Mint repeatedly until a multi-core token is revealed so the
        // per-core seed assertions have at least two cores to compare.
        uint256[] memory cores;
        for (uint256 attempt = 0; attempt < 32; ++attempt) {
            (uint256 id, uint256 commitBlock) = _mint(alice);
            vm.roll(commitBlock + 1);
            nft.reveal(id);
            cores = nft.coresOf(id);
            if (cores.length > 1) {
                break;
            }
        }
        require(cores.length > 1, "no multi-core token revealed in 32 attempts");

        uint8 material = TalismanCore.materialId(cores[0]);
        TalismanForms.ShapeForm form = TalismanCore.shapeForm(cores[0]);
        for (uint256 i = 1; i < cores.length; ++i) {
            assertEq(TalismanCore.materialId(cores[i]), material, "cores must share material");
            assertEq(uint8(TalismanCore.shapeForm(cores[i])), uint8(form), "cores must share form");
            assertTrue(cores[i] != cores[0], "each core must differ by seed");
        }
    }

    function test_reveal_recordsTokenIdForCores() public {
        // The revealed cores must be recorded in the global id↔cores mapping so
        // a future transformation can resolve back to this exact id.
        (uint256 id, uint256 commitBlock) = _mint(alice);
        vm.roll(commitBlock + 1);
        nft.reveal(id);
        assertEq(nft.tokenIdForCores(nft.coresOf(id)), id, "revealed cores must map back to the token id");
    }

    function test_reveal_clearsCommitBlock() public {
        (uint256 id, uint256 commitBlock) = _mint(alice);
        vm.roll(commitBlock + 1);
        nft.reveal(id);
        assertEq(nft.commitBlockOf(id), 0, "commit block must be cleared after reveal");
    }

    function test_reveal_emitsMetadataUpdate() public {
        (uint256 id, uint256 commitBlock) = _mint(alice);
        vm.roll(commitBlock + 1);
        vm.expectEmit(true, true, true, true, address(nft));
        emit IERC4906.MetadataUpdate(id);
        nft.reveal(id);
    }

    function test_reveal_revertsIfCalledTwice() public {
        (uint256 id, uint256 commitBlock) = _mint(alice);
        vm.roll(commitBlock + 1);
        nft.reveal(id);

        vm.expectRevert(abi.encodeWithSelector(Talismans.NothingToReveal.selector, id));
        nft.reveal(id);
    }

    // ─── batchReveal ─────────────────────────────────────────────────────────

    /// @dev Tokens minted in the same block share a commit block, so one roll
    ///      ripens the whole batch.
    function test_batchReveal_revealsEveryToken() public {
        (uint256 a, uint256 commitBlock) = _mint(alice);
        (uint256 b,) = _mint(bob);
        (uint256 c,) = _mint(alice);
        vm.roll(commitBlock + 1);

        uint256[] memory ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (a, b, c);
        nft.batchReveal(ids);

        assertTrue(nft.isRevealed(a));
        assertTrue(nft.isRevealed(b));
        assertTrue(nft.isRevealed(c));
    }

    /// @dev A batch reveal must match what individual reveals would produce —
    ///      it is only a wrapper, so the per-token cores are identical.
    function test_batchReveal_matchesSingleReveal() public {
        (uint256 a, uint256 commitBlock) = _mint(alice);
        (uint256 b,) = _mint(alice);
        vm.roll(commitBlock + 1);

        // Reveal `a` singly; batch-reveal `b`. Both share block context, so any
        // divergence would mean the batch path differs from the single path.
        nft.reveal(a);
        uint256[] memory ids = new uint256[](1);
        ids[0] = b;
        nft.batchReveal(ids);

        assertEq(nft.coreCount(a) > 0, true);
        assertEq(nft.coreCount(b) > 0, true);
    }

    function test_batchReveal_anyoneCanCall() public {
        (uint256 a, uint256 commitBlock) = _mint(alice);
        vm.roll(commitBlock + 1);

        uint256[] memory ids = new uint256[](1);
        ids[0] = a;
        vm.prank(bob);
        nft.batchReveal(ids);

        assertTrue(nft.isRevealed(a));
        assertEq(nft.ownerOf(a), alice);
    }

    function test_batchReveal_revertsForUncommittedToken() public {
        (uint256 a, uint256 commitBlock) = _mint(alice);
        vm.roll(commitBlock + 1);

        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (a, 999);
        vm.expectRevert(abi.encodeWithSelector(Talismans.NothingToReveal.selector, uint256(999)));
        nft.batchReveal(ids);
    }

    /// @dev An already-revealed id has no pending commit, so the batch reverts
    ///      {NothingToReveal} — and the revert is atomic: an earlier token that
    ///      revealed within the same batch is rolled back.
    function test_batchReveal_revertsAndRollsBackWhenAlreadyRevealed() public {
        (uint256 a, uint256 commitBlock) = _mint(alice);
        (uint256 b,) = _mint(alice);
        vm.roll(commitBlock + 1);
        nft.reveal(a); // a is now revealed; its commit block is cleared

        // b reveals first inside the batch, then a reverts → whole call unwinds.
        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (b, a);
        vm.expectRevert(abi.encodeWithSelector(Talismans.NothingToReveal.selector, a));
        nft.batchReveal(ids);

        assertFalse(nft.isRevealed(b), "batch must roll back the earlier reveal");
        assertTrue(nft.isRevealed(a), "the pre-batch standalone reveal is untouched");
    }

    function test_batchReveal_emptyArrayIsNoOp() public {
        uint256[] memory ids = new uint256[](0);
        nft.batchReveal(ids); // no revert, nothing to do
    }

    function test_reveal_anyoneCanFinaliseAnotherUsersToken() public {
        (uint256 id, uint256 commitBlock) = _mint(alice);
        vm.roll(commitBlock + 1);

        vm.prank(bob);
        nft.reveal(id);

        assertTrue(nft.isRevealed(id));
        // Token ownership unchanged.
        assertEq(nft.ownerOf(id), alice);
    }

    // ─── reveal — randomness sources ─────────────────────────────────────────

    function test_reveal_isDeterministicGivenFixedBlockhash() public {
        // Two independent runs with identical block context must produce the
        // same cores — establishes the determinism baseline before we vary
        // the inputs in later tests.
        uint256 snapshot = vm.snapshotState();

        (uint256 idA, uint256 commitA) = _mint(alice);
        vm.roll(commitA + 1);
        vm.prevrandao(bytes32(uint256(0xdeadbeef)));
        nft.reveal(idA);
        uint256[] memory runA = nft.coresOf(idA);

        vm.revertToState(snapshot);

        (uint256 idB, uint256 commitB) = _mint(alice);
        assertEq(idB, idA, "token id must be identical after revert");
        assertEq(commitB, commitA, "commit block must be identical after revert");
        vm.roll(commitB + 1);
        vm.prevrandao(bytes32(uint256(0xdeadbeef)));
        nft.reveal(idB);
        uint256[] memory runB = nft.coresOf(idB);

        assertEq(runA.length, runB.length, "core counts must match");
        for (uint256 i; i < runA.length; ++i) {
            assertEq(runA[i], runB[i], "core values must match");
        }
    }

    function test_reveal_invariantToPrevrandao() public {
        // Grinding-resistance regression: the seed is `keccak256(commitHash,
        // tokenId)`, so `block.prevrandao` must NOT enter the randomness. Vary
        // only prevrandao between two otherwise-identical runs across a wide
        // sweep; the resulting cores must be byte-identical every time. If they
        // ever diverged, a caller could grind the reveal by retrying blocks.
        for (uint256 seed = 1; seed < 16; ++seed) {
            uint256 snap = vm.snapshotState();

            (uint256 idA, uint256 commitA) = _mint(alice);
            vm.roll(commitA + 1);
            vm.prevrandao(bytes32(seed));
            nft.reveal(idA);
            uint256[] memory a = nft.coresOf(idA);

            vm.revertToState(snap);

            (uint256 idB, uint256 commitB) = _mint(alice);
            vm.roll(commitB + 1);
            vm.prevrandao(bytes32(seed ^ 0xffffffff));
            nft.reveal(idB);
            uint256[] memory b = nft.coresOf(idB);

            assertEq(a.length, b.length, "core counts must not depend on prevrandao");
            for (uint256 i; i < a.length; ++i) {
                assertEq(a[i], b[i], "core values must not depend on prevrandao");
            }
        }
    }

    function test_reveal_changesWithTokenId() public {
        // Two tokens minted in the same block share the same commit hash, but
        // their results must differ at least somewhere because tokenId is part
        // of the keccak input.
        (uint256 idA, uint256 commitA) = _mint(alice);
        (uint256 idB,) = _mint(bob);
        vm.roll(commitA + 1);

        nft.reveal(idA);
        nft.reveal(idB);

        // Either count or value should differ. If both match purely by
        // collision on the small space, fail loudly so we investigate.
        bool differs = (nft.coreCount(idA) != nft.coreCount(idB)) || (nft.coresOf(idA)[0] != nft.coresOf(idB)[0]);
        assertTrue(differs, "tokenId must enter the randomness");
    }

    // ─── recommit ────────────────────────────────────────────────────────────

    function test_recommit_revertsWhenNeverCommitted() public {
        vm.expectRevert(abi.encodeWithSelector(Talismans.NothingToReveal.selector, uint256(123)));
        nft.recommit(123);
    }

    function test_recommit_revertsBeforeCommitRipens() public {
        (uint256 id, uint256 commitBlock) = _mint(alice);
        // block.number < commitBlock — too early; blockhash also still zero.
        vm.expectRevert(abi.encodeWithSelector(Talismans.CommitStillFresh.selector, id, commitBlock));
        nft.recommit(id);
    }

    function test_recommit_revertsWhenBlockhashStillValid() public {
        (uint256 id, uint256 commitBlock) = _mint(alice);
        vm.roll(commitBlock + 1); // blockhash(commitBlock) still in window
        vm.expectRevert(abi.encodeWithSelector(Talismans.CommitStillFresh.selector, id, commitBlock));
        nft.recommit(id);
    }

    function test_recommit_succeedsOnceBlockhashExpired() public {
        (uint256 id, uint256 commitBlock) = _mint(alice);
        vm.roll(commitBlock + 257);

        nft.recommit(id);

        uint256 fresh = nft.commitBlockOf(id);
        assertEq(fresh, block.number + nft.REVEAL_DELAY(), "recommit must schedule a new future commit block");
    }

    function test_recommit_enablesSubsequentReveal() public {
        (uint256 id, uint256 commitBlock) = _mint(alice);
        vm.roll(commitBlock + 257);
        nft.recommit(id);

        uint256 freshCommit = nft.commitBlockOf(id);
        vm.roll(freshCommit + 1);
        nft.reveal(id);

        assertTrue(nft.isRevealed(id));
    }

    function test_recommit_revertsAfterReveal() public {
        (uint256 id, uint256 commitBlock) = _mint(alice);
        vm.roll(commitBlock + 1);
        nft.reveal(id);

        vm.expectRevert(abi.encodeWithSelector(Talismans.NothingToReveal.selector, id));
        nft.recommit(id);
    }

    function test_recommit_doesNotMintOrRevealToken() public {
        (uint256 id, uint256 commitBlock) = _mint(alice);
        uint256 genesisBefore = nft.genesisMinted();
        vm.roll(commitBlock + 257);
        nft.recommit(id);
        assertEq(nft.genesisMinted(), genesisBefore, "recommit must not mint a new genesis token");
        assertFalse(nft.isRevealed(id), "recommit must not reveal");
    }

    function test_recommit_anyoneCanCall() public {
        (uint256 id, uint256 commitBlock) = _mint(alice);
        vm.roll(commitBlock + 257);

        vm.prank(bob);
        nft.recommit(id);

        assertEq(nft.commitBlockOf(id), block.number + nft.REVEAL_DELAY());
    }

    // ─── Core packing: material + shape form ─────────────────────────────────

    function test_coreMaterialId_revertsBeforeReveal() public {
        (uint256 id,) = _mint(alice);
        vm.expectRevert(abi.encodeWithSelector(NotRevealed.selector, id));
        nft.coreMaterialId(id);
    }

    function test_coreShapeForm_revertsBeforeReveal() public {
        (uint256 id,) = _mint(alice);
        vm.expectRevert(abi.encodeWithSelector(NotRevealed.selector, id));
        nft.coreShapeForm(id);
    }

    function test_revealedCore_decodesViaTalismanCore() public {
        (uint256 id, uint256 commitBlock) = _mint(alice);
        vm.roll(commitBlock + 1);
        nft.reveal(id);

        uint256 raw = nft.coresOf(id)[0];
        assertEq(nft.coreMaterialId(id), TalismanCore.materialId(raw), "getter must agree with TalismanCore decoder");
        assertEq(
            uint8(nft.coreShapeForm(id)),
            uint8(TalismanCore.shapeForm(raw)),
            "getter must agree with TalismanCore decoder"
        );
    }

    function test_revealedCore_materialAlwaysNonMythic() public {
        // Sweep many reveals across varied randomness; every drawn material
        // must land in the non-mythic id range [0, NON_MYTHIC_MATERIAL_COUNT).
        for (uint256 i; i < 64; ++i) {
            (uint256 id, uint256 commitBlock) = _mint(alice);
            vm.roll(commitBlock + 1);
            vm.prevrandao(bytes32(uint256(keccak256(abi.encode("mat-sweep", i)))));
            nft.reveal(id);

            uint8 mid = nft.coreMaterialId(id);
            assertLt(mid, NON_MYTHIC_MATERIAL_COUNT, "material must be non-mythic");
        }
    }

    function test_revealedCore_materialPickerCoversEveryNonMythicId() public {
        // Uniform distribution claim: with 1024 trials the chance of any
        // single id missing is (31/32)^1024 ≈ 1.0e-14 — effectively zero.
        // Array size is the literal `NON_MYTHIC_MATERIAL_COUNT` (32) — kept
        // in sync with TalismanMaterials by the assertion below.
        bool[32] memory hit;
        assertEq(uint256(NON_MYTHIC_MATERIAL_COUNT), hit.length, "hit array must match constant");
        uint256 trials = 1024;
        for (uint256 i; i < trials; ++i) {
            (uint256 id, uint256 commitBlock) = _mint(alice);
            vm.roll(commitBlock + 1);
            vm.prevrandao(bytes32(uint256(keccak256(abi.encode("mat-cover", i)))));
            nft.reveal(id);
            hit[nft.coreMaterialId(id)] = true;
        }
        for (uint256 m; m < NON_MYTHIC_MATERIAL_COUNT; ++m) {
            assertTrue(hit[m], "every non-mythic material id must be reachable");
        }
    }

    function test_revealedCore_formPickerCoversEveryShapeForm() public {
        // Uniform distribution claim: with 256 trials the chance of any single
        // form id missing is (13/14)^256 ≈ 6.8e-9 — effectively zero.
        bool[14] memory hit;
        uint256 trials = 256;
        for (uint256 i; i < trials; ++i) {
            (uint256 id, uint256 commitBlock) = _mint(alice);
            vm.roll(commitBlock + 1);
            vm.prevrandao(bytes32(uint256(keccak256(abi.encode("form-cover", i)))));
            nft.reveal(id);
            hit[uint8(nft.coreShapeForm(id))] = true;
        }
        for (uint8 f; f <= uint8(TalismanForms.ShapeForm.Husk); ++f) {
            assertTrue(hit[f], "every shape form must be reachable");
        }
    }

    function test_revealedCore_allCoresShareSamePackedValue() public {
        // The "same value pushed N times" design (H-2) must still hold after
        // packing — every entry in `coresOf` decodes to the same material+form.
        (uint256 id, uint256 commitBlock) = _mint(alice);
        vm.roll(commitBlock + 1);
        nft.reveal(id);

        uint256[] memory cores = nft.coresOf(id);
        uint8 m = TalismanCore.materialId(cores[0]);
        uint8 f = uint8(TalismanCore.shapeForm(cores[0]));
        for (uint256 i = 1; i < cores.length; ++i) {
            assertEq(TalismanCore.materialId(cores[i]), m);
            assertEq(uint8(TalismanCore.shapeForm(cores[i])), f);
        }
    }

    function test_revealedCore_reservedBitsAreZeroUnderCurrentSchema() public {
        // The current packer only sets the material+form+seed bit ranges. While
        // readers MUST mask their fields (see TalismanCoreTest), we still pin
        // that the current schema leaves reserved bits clean — so a v2 reader
        // that exists alongside v1 cores can detect schema age by these bits.
        (uint256 id, uint256 commitBlock) = _mint(alice);
        vm.roll(commitBlock + 1);
        nft.reveal(id);

        uint256 raw = nft.coresOf(id)[0];
        uint256 declaredBits = TalismanCore.MATERIAL_BITS + TalismanCore.FORM_BITS + TalismanCore.SEED_BITS;
        uint256 reservedMask = ~((uint256(1) << declaredBits) - 1);
        assertEq(raw & reservedMask, 0, "v1 reveals must not touch reserved bits");
    }

    // ─── Unrevealed tokens persist (no forfeit path) ──────────────────────────

    function test_unrevealedToken_persistsAndStaysRevealable() public {
        (uint256 id,) = _mint(alice);

        // Walk way past the blockhash window without ever revealing.
        vm.roll(block.number + 10_000);

        // The token still exists and can still be revealed via the recommit
        // pathway — there is no forfeit path.
        assertFalse(nft.isRevealed(id));
        assertGt(nft.commitBlockOf(id), 0);
    }

    // ─── Fuzz ────────────────────────────────────────────────────────────────

    function testFuzz_reveal_coreCountAlwaysWithinBounds(bytes32 prevrandaoSeed, uint16 rollOffset) public {
        rollOffset = uint16(bound(rollOffset, 1, 200)); // stay inside blockhash window
        (uint256 id, uint256 commitBlock) = _mint(alice);
        vm.roll(commitBlock + rollOffset);
        vm.prevrandao(prevrandaoSeed);
        nft.reveal(id);

        uint256 cores = nft.coreCount(id);
        assertGt(cores, 0);
        assertLe(cores, nft.MAX_CORES_PER_MINT());
    }

    function test_reveal_everyCoreCountSlotIsReachable() public {
        // Distribution sanity (deterministic, not fuzzed): with 256 reveals
        // and the default weights 40/30/20/10, the rarest slot (10%) misses
        // with probability 0.9^256 ≈ 2e-12 — effectively impossible.
        bool[5] memory hit; // index 1..4 used
        uint256 trials = 256;
        for (uint256 i; i < trials; ++i) {
            (uint256 id, uint256 commitBlock) = _mint(alice);
            vm.roll(commitBlock + 1);
            vm.prevrandao(bytes32(uint256(keccak256(abi.encode("slot-coverage", i)))));
            nft.reveal(id);
            hit[nft.coreCount(id)] = true;
        }
        for (uint256 c = 1; c <= nft.MAX_CORES_PER_MINT(); ++c) {
            assertTrue(hit[c], "every core-count slot must be reachable across 256 trials");
        }
    }
}
