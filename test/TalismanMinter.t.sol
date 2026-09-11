// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TalismanMinter} from "../src/TalismanMinter.sol";
import {Talismans} from "../src/Talismans.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Plain ERC20 used as a stand-in for any compliant token.
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev USDT-style token that returns no data from `transfer`.
contract NoReturnERC20 is ERC20 {
    constructor() ERC20("NoReturn", "NRT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        super.transfer(to, amount);
        assembly {
            return(0, 0)
        }
    }
}

/// @dev Broken ERC20 that always returns `false`. SafeERC20 must revert.
contract ReturnsFalseERC20 is ERC20 {
    constructor() ERC20("ReturnsFalse", "RFL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address, uint256) public pure override returns (bool) {
        return false;
    }
}

/// @dev Rejects all incoming ETH so we can exercise the sendValue failure path.
contract EthRejector {
    /// @notice Forwards a `withdraw` call to its minter as `msg.sender`.
    function callWithdraw(TalismanMinter minter) external {
        minter.withdraw();
    }

    /// @notice Forwards a `withdrawErc20` call to its minter as `msg.sender`.
    function callWithdrawErc20(TalismanMinter minter, IERC20 token) external {
        minter.withdrawErc20(token);
    }

    /// @notice Required to receive ownership of an Ownable2Step contract.
    function acceptOwnership(address ownable) external {
        Ownable2StepLike(ownable).acceptOwnership();
    }

    receive() external payable {
        revert("nope");
    }
}

interface Ownable2StepLike {
    function acceptOwnership() external;
}

/// @dev Attempts to reenter `withdraw` from inside `receive`.
contract ReentrantOwner {
    TalismanMinter public minter;
    bool public attempted;
    bytes public lastInnerError;

    function setMinter(TalismanMinter m) external {
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
            // Swallow inner revert so the outer sendValue still succeeds; we
            // assert on `lastInnerError` from the test to confirm the guard
            // blocked the reentry.
            try minter.withdraw() {}
            catch (bytes memory err) {
                lastInnerError = err;
            }
        }
    }
}

contract TalismanMinterWithdrawTest is Test {
    Talismans internal nft;
    TalismanMinter internal minter;

    address internal owner = address(this);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        nft = new Talismans();
        minter = new TalismanMinter(nft);
        nft.setMinter(address(minter));
    }

    // ─── withdraw (ETH) ──────────────────────────────────────────────────────

    function test_withdraw_ownerSweepsFullBalance() public {
        vm.deal(address(minter), 5 ether);
        uint256 balanceBefore = owner.balance;

        minter.withdraw();

        assertEq(address(minter).balance, 0, "minter not drained");
        assertEq(owner.balance, balanceBefore + 5 ether, "owner did not receive funds");
    }

    function test_withdraw_revertsForNonOwner() public {
        vm.deal(address(minter), 1 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        minter.withdraw();

        assertEq(address(minter).balance, 1 ether, "balance leaked");
    }

    function test_withdraw_revertsWhenBalanceZero() public {
        vm.expectRevert(TalismanMinter.NothingToWithdraw.selector);
        minter.withdraw();
    }

    function test_withdraw_pendingOwnerCannotWithdrawUntilAccepted() public {
        vm.deal(address(minter), 1 ether);
        minter.transferOwnership(alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        minter.withdraw();

        vm.prank(alice);
        minter.acceptOwnership();

        vm.prank(alice);
        minter.withdraw();
        assertEq(alice.balance, 1 ether);
    }

    function test_withdraw_revertsWhenReceiverRejectsEth() public {
        EthRejector rejector = new EthRejector();
        minter.transferOwnership(address(rejector));
        rejector.acceptOwnership(address(minter));

        vm.deal(address(minter), 1 ether);

        // Address.sendValue bubbles the receiver's revert reason verbatim.
        vm.expectRevert(bytes("nope"));
        rejector.callWithdraw(minter);

        assertEq(address(minter).balance, 1 ether, "balance leaked after failed sendValue");
    }

    function test_withdraw_reentryBlocked() public {
        ReentrantOwner attacker = new ReentrantOwner();
        attacker.setMinter(minter);
        minter.transferOwnership(address(attacker));
        attacker.acceptOwnership(address(minter));

        vm.deal(address(minter), 2 ether);
        attacker.callWithdraw();

        // First withdrawal succeeded (ETH is transferred before receive runs);
        // the nested attempt during receive must have hit ReentrancyGuard.
        assertTrue(attacker.attempted(), "reentry attempt path not taken");
        assertEq(address(attacker).balance, 2 ether, "outer withdrawal must succeed");
        assertEq(address(minter).balance, 0);
        assertEq(
            bytes32(attacker.lastInnerError()),
            bytes32(ReentrancyGuard.ReentrancyGuardReentrantCall.selector),
            "inner call should be blocked by ReentrancyGuard"
        );
    }

    function test_withdraw_includesProceedsFromPublicMint() public {
        // Configure a tiny open mint and pay overage to leave dust behind.
        uint256 price = 0.01 ether;
        minter.setMintConfig(block.timestamp, 60, price, 0, 0, 0);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        minter.publicMint{value: price + 7 wei}();

        assertEq(address(minter).balance, price + 7 wei);

        uint256 before = owner.balance;
        minter.withdraw();
        assertEq(owner.balance, before + price + 7 wei);
        assertEq(address(minter).balance, 0);
    }

    // ─── artistProofMint ─────────────────────────────────────────────────────

    function test_artistProofMint_mintsToProvidedWallet() public {
        minter.artistProofMint(3, alice);

        assertEq(nft.genesisMinted(), 3);
        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.ownerOf(2), alice);
        assertEq(nft.ownerOf(3), alice);
        assertTrue(nft.isGenesis(3), "proofs sit in the genesis range");
    }

    function test_artistProofMint_defaultsToCaller() public {
        // Hand the minter to an EOA so safeMint-to-self lands on a plain address.
        minter.transferOwnership(alice);
        vm.prank(alice);
        minter.acceptOwnership();

        vm.prank(alice);
        minter.artistProofMint(2);

        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.ownerOf(2), alice);
    }

    /// @dev Proofs are independent of the sale window: no mint config is set, so
    ///      {publicMint} would revert {MintNotConfigured} here.
    function test_artistProofMint_ignoresSaleWindow() public {
        minter.artistProofMint(1, alice);
        assertEq(nft.genesisMinted(), 1);
    }

    function test_artistProofMint_revertsForNonOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        minter.artistProofMint(1, bob);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        minter.artistProofMint(1);
    }

    function test_artistProofMint_revertsAtZeroQuantity() public {
        vm.expectRevert(TalismanMinter.InvalidQuantity.selector);
        minter.artistProofMint(0, alice);
    }

    function test_artistProofMint_fillsCapThenReverts() public {
        uint256 cap = nft.MAX_ARTIST_PROOFS();
        minter.artistProofMint(cap, alice);
        assertEq(nft.genesisMinted(), cap);
        assertEq(nft.ownerOf(cap), alice);

        vm.expectRevert(TalismanMinter.ArtistProofsExhausted.selector);
        minter.artistProofMint(1, alice);
    }

    function test_artistProofMint_revertsWhenQuantityOverflowsCap() public {
        uint256 over = nft.MAX_ARTIST_PROOFS() + 1;
        vm.expectRevert(TalismanMinter.ArtistProofsExhausted.selector);
        minter.artistProofMint(over, alice);
    }

    /// @dev Proofs may only occupy the first MAX_ARTIST_PROOFS genesis ids — once
    ///      public minting advances genesis past that, the remaining proof budget
    ///      shrinks and then disappears.
    function test_artistProofMint_onlyAgainstFirstTokens() public {
        minter.setMintConfig(block.timestamp, 60, 0, 0, 0, 0); // free, open mint
        // One mint per wallet, so advance genesis to four short of the proof cap
        // with that many distinct buyers.
        uint256 cap = nft.MAX_ARTIST_PROOFS();
        uint256 advance = cap - 4;
        for (uint256 i; i < advance; ++i) {
            vm.prank(address(uint160(0x1000 + i)));
            minter.publicMint();
        }
        assertEq(nft.genesisMinted(), advance);

        // advance + 5 > cap → no room.
        vm.expectRevert(TalismanMinter.ArtistProofsExhausted.selector);
        minter.artistProofMint(5, alice);

        // advance + 4 == cap → exactly fills the proof range.
        minter.artistProofMint(4, alice);
        assertEq(nft.genesisMinted(), cap);
    }

    // ─── publicMint ──────────────────────────────────────────────────────────

    /// @dev A public mint yields exactly one token — the fixed per-call allotment.
    function test_publicMint_mintsOne() public {
        uint256 price = 0.01 ether;
        minter.setMintConfig(block.timestamp, 60, price, 0, 0, 0);

        vm.deal(alice, price);
        vm.prank(alice);
        minter.publicMint{value: price}();

        assertEq(nft.balanceOf(alice), 1);
        assertEq(minter.MAX_MINTS_PER_CALL(), 1);
    }

    // ─── publicMint per-wallet cap ───────────────────────────────────────────

    /// @dev One mint per wallet: a second publicMint from the same address reverts.
    function test_publicMint_revertsOnSecondMintFromSameWallet() public {
        uint256 price = 0.01 ether;
        minter.setMintConfig(block.timestamp, 60, price, 0, 0, 0);

        vm.deal(alice, 2 * price);
        vm.startPrank(alice);
        minter.publicMint{value: price}();
        vm.expectRevert(TalismanMinter.AlreadyPublicMinted.selector);
        minter.publicMint{value: price}();
        vm.stopPrank();

        assertEq(nft.balanceOf(alice), 1);
    }

    /// @dev The cap is per-wallet: distinct addresses each get their one mint.
    function test_publicMint_succeedsAcrossDistinctWallets() public {
        uint256 price = 0.01 ether;
        minter.setMintConfig(block.timestamp, 60, price, 0, 0, 0);

        vm.deal(alice, price);
        vm.prank(alice);
        minter.publicMint{value: price}();

        vm.deal(bob, price);
        vm.prank(bob);
        minter.publicMint{value: price}();

        assertEq(nft.balanceOf(alice), 1);
        assertEq(nft.balanceOf(bob), 1);
        assertTrue(minter.publicMinted(alice));
        assertTrue(minter.publicMinted(bob));
    }

    // ─── withdrawErc20 ───────────────────────────────────────────────────────

    function test_withdrawErc20_ownerSweepsFullBalance() public {
        MockERC20 token = new MockERC20();
        token.mint(address(minter), 1_000 ether);

        minter.withdrawErc20(token);

        assertEq(token.balanceOf(address(minter)), 0);
        assertEq(token.balanceOf(owner), 1_000 ether);
    }

    function test_withdrawErc20_revertsForNonOwner() public {
        MockERC20 token = new MockERC20();
        token.mint(address(minter), 100 ether);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        minter.withdrawErc20(token);

        assertEq(token.balanceOf(address(minter)), 100 ether);
    }

    function test_withdrawErc20_revertsWhenBalanceZero() public {
        MockERC20 token = new MockERC20();
        vm.expectRevert(TalismanMinter.NothingToWithdraw.selector);
        minter.withdrawErc20(token);
    }

    function test_withdrawErc20_handlesNoReturnToken() public {
        NoReturnERC20 token = new NoReturnERC20();
        token.mint(address(minter), 42);

        minter.withdrawErc20(token);

        assertEq(token.balanceOf(address(minter)), 0);
        assertEq(token.balanceOf(owner), 42);
    }

    function test_withdrawErc20_revertsOnReturnsFalseToken() public {
        ReturnsFalseERC20 token = new ReturnsFalseERC20();
        token.mint(address(minter), 5);

        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        minter.withdrawErc20(token);
    }

    function test_withdrawErc20_isolatesPerToken() public {
        MockERC20 a = new MockERC20();
        MockERC20 b = new MockERC20();
        a.mint(address(minter), 10 ether);
        b.mint(address(minter), 25 ether);

        minter.withdrawErc20(a);
        assertEq(a.balanceOf(owner), 10 ether);
        assertEq(b.balanceOf(address(minter)), 25 ether, "second token must be untouched");

        minter.withdrawErc20(b);
        assertEq(b.balanceOf(owner), 25 ether);
    }

    function test_withdrawErc20_revertsIfReceiverRejectsEthButNotErc20() public {
        // EthRejector has no payable receive matching ERC20s — but receiving
        // ERC20 is a pure ledger op so it must succeed even for a contract that
        // can't take ETH. Confirms withdrawErc20 doesn't accidentally send ETH.
        EthRejector rejector = new EthRejector();
        minter.transferOwnership(address(rejector));
        rejector.acceptOwnership(address(minter));

        MockERC20 token = new MockERC20();
        token.mint(address(minter), 9 ether);

        rejector.callWithdrawErc20(minter, token);

        assertEq(token.balanceOf(address(rejector)), 9 ether);
        assertEq(token.balanceOf(address(minter)), 0);
    }

    receive() external payable {}
}

/// @dev Exercises the allowlist (Merkle-proof) mint stage. Builds a 4-leaf tree
///      over {alice, bob, carol, dave} using the same leaf encoding as the
///      OpenZeppelin `StandardMerkleTree` single-`address` form
///      (`keccak256(bytes.concat(keccak256(abi.encode(account))))`) and the same
///      commutative pair hashing that {MerkleProof.verify} uses, so the proofs
///      built here verify on-chain exactly as a real talisman-al tree would.
contract TalismanMinterAllowlistTest is Test {
    Talismans internal nft;
    TalismanMinter internal minter;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);
    address internal dave = address(0xDA5E);
    address internal eve = address(0xE5E); // not on the allowlist

    uint256 internal constant AL_START = 1_000;
    uint256 internal constant PUBLIC_START = 2_000;
    uint256 internal constant AL_PRICE = 0.01 ether;
    uint256 internal constant PUBLIC_PRICE = 0.02 ether;
    uint256 internal constant AL_MAX = 2;

    bytes32 internal root;
    bytes32 internal n01;
    bytes32 internal n23;

    function setUp() public {
        nft = new Talismans();
        minter = new TalismanMinter(nft);
        nft.setMinter(address(minter));

        // 4-leaf tree: [alice, bob, carol, dave].
        n01 = _hashPair(_leaf(alice), _leaf(bob));
        n23 = _hashPair(_leaf(carol), _leaf(dave));
        root = _hashPair(n01, n23);

        vm.warp(AL_START);
        minter.setMintConfig(PUBLIC_START, 60, PUBLIC_PRICE, AL_START, AL_PRICE, AL_MAX);
        minter.setMerkleRoot(root);
    }

    function _leaf(address account) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account))));
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _proofAlice() internal view returns (bytes32[] memory p) {
        p = new bytes32[](2);
        p[0] = _leaf(bob);
        p[1] = n23;
    }

    function _proofBob() internal view returns (bytes32[] memory p) {
        p = new bytes32[](2);
        p[0] = _leaf(alice);
        p[1] = n23;
    }

    // ─── happy paths ──────────────────────────────────────────────────────────

    function test_allowlistMint_eligibleClaimsMax() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        minter.allowlistMint{value: AL_MAX * AL_PRICE}(_proofAlice(), AL_MAX);

        assertEq(nft.balanceOf(alice), AL_MAX);
        assertEq(nft.genesisMinted(), AL_MAX);
        assertTrue(minter.allowlistMinted(alice), "spot not marked used");
    }

    function test_allowlistMint_claimingFewerForfeitsRest() public {
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        minter.allowlistMint{value: AL_PRICE}(_proofBob(), 1);

        assertEq(nft.balanceOf(bob), 1);
        assertTrue(minter.allowlistMinted(bob));

        // The spot is single-use: the unminted second token is forfeited.
        vm.prank(bob);
        vm.expectRevert(TalismanMinter.AlreadyAllowlistMinted.selector);
        minter.allowlistMint{value: AL_PRICE}(_proofBob(), 1);
    }

    function test_allowlistMint_usesAllowlistPriceNotPublicPrice() public {
        // Pays the (cheaper) allowlist price; the public price would be more.
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        minter.allowlistMint{value: AL_MAX * AL_PRICE}(_proofAlice(), AL_MAX);
        assertEq(address(minter).balance, AL_MAX * AL_PRICE);
    }

    /// @dev The public per-wallet cap is independent of the allowlist: an
    ///      address that claimed its allowlist spot may still mint once in the
    ///      public phase.
    function test_publicMint_independentOfAllowlist() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        minter.allowlistMint{value: AL_MAX * AL_PRICE}(_proofAlice(), AL_MAX);

        vm.warp(PUBLIC_START);
        vm.prank(alice);
        minter.publicMint{value: PUBLIC_PRICE}();

        assertEq(nft.balanceOf(alice), AL_MAX + 1);
        assertTrue(minter.publicMinted(alice));
    }

    // ─── membership / proof failures ───────────────────────────────────────────

    function test_allowlistMint_revertsForNonMember() public {
        vm.deal(eve, 1 ether);
        vm.prank(eve);
        vm.expectRevert(TalismanMinter.NotAllowlisted.selector);
        minter.allowlistMint{value: AL_PRICE}(_proofAlice(), 1);
    }

    function test_allowlistMint_revertsWithWrongProof() public {
        // alice presenting bob's proof must not verify.
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(TalismanMinter.NotAllowlisted.selector);
        minter.allowlistMint{value: AL_PRICE}(_proofBob(), 1);
    }

    // ─── quantity bounds vs allowlistMaxMints ──────────────────────────────────

    function test_allowlistMint_revertsAtZeroQuantity() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(TalismanMinter.InvalidQuantity.selector);
        minter.allowlistMint(_proofAlice(), 0);
    }

    function test_allowlistMint_revertsAboveMaxMints() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(TalismanMinter.InvalidQuantity.selector);
        minter.allowlistMint{value: 3 * AL_PRICE}(_proofAlice(), AL_MAX + 1);
    }

    // ─── window edges ──────────────────────────────────────────────────────────

    function test_allowlistMint_revertsBeforeStart() public {
        minter.setMintConfig(PUBLIC_START, 60, PUBLIC_PRICE, AL_START + 500, AL_PRICE, AL_MAX);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(TalismanMinter.AllowlistNotStarted.selector);
        minter.allowlistMint{value: AL_PRICE}(_proofAlice(), 1);
    }

    function test_allowlistMint_revertsOncePublicStarts() public {
        vm.warp(PUBLIC_START);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(TalismanMinter.AllowlistEnded.selector);
        minter.allowlistMint{value: AL_PRICE}(_proofAlice(), 1);
    }

    function test_allowlistMint_revertsWhenStageOff() public {
        // allowlistStartTime == 0 disables the stage.
        minter.setMintConfig(PUBLIC_START, 60, PUBLIC_PRICE, 0, AL_PRICE, AL_MAX);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(TalismanMinter.AllowlistNotConfigured.selector);
        minter.allowlistMint{value: AL_PRICE}(_proofAlice(), 1);
    }

    function test_allowlistMint_revertsWhenRootUnset() public {
        minter.setMerkleRoot(bytes32(0));
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(TalismanMinter.AllowlistNotConfigured.selector);
        minter.allowlistMint{value: AL_PRICE}(_proofAlice(), 1);
    }

    function test_allowlistMint_runsOpenEndedWhenNoPublicSale() public {
        // No public sale configured (startTime 0): allowlist stays open.
        minter.setMintConfig(0, 0, 0, AL_START, AL_PRICE, AL_MAX);
        vm.warp(PUBLIC_START + 10_000);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        minter.allowlistMint{value: AL_PRICE}(_proofAlice(), 1);
        assertEq(nft.balanceOf(alice), 1);
    }

    // ─── payment ────────────────────────────────────────────────────────────────

    function test_allowlistMint_revertsOnInsufficientPayment() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(TalismanMinter.InsufficientPayment.selector, AL_PRICE, AL_MAX * AL_PRICE)
        );
        minter.allowlistMint{value: AL_PRICE}(_proofAlice(), AL_MAX);
    }

    // ─── admin setters ───────────────────────────────────────────────────────────

    function test_setMerkleRoot_onlyOwner() public {
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        minter.setMerkleRoot(bytes32(uint256(1)));
    }

    function test_setMerkleRoot_emitsEvent() public {
        vm.expectEmit(false, false, false, true, address(minter));
        emit TalismanMinter.MerkleRootUpdated(bytes32(uint256(0xABC)));
        minter.setMerkleRoot(bytes32(uint256(0xABC)));
        assertEq(minter.merkleRoot(), bytes32(uint256(0xABC)));
    }

    function test_setMintConfig_storesAndEmitsAllowlistFields() public {
        vm.expectEmit(false, false, false, true, address(minter));
        emit TalismanMinter.MintConfigUpdated(PUBLIC_START, 60, PUBLIC_PRICE, AL_START, AL_PRICE, AL_MAX);
        minter.setMintConfig(PUBLIC_START, 60, PUBLIC_PRICE, AL_START, AL_PRICE, AL_MAX);

        (uint256 startTime, uint256 lengthMins, uint256 price, uint256 alStart, uint256 alPrice, uint256 alMax) =
            minter.mintConfig();
        assertEq(startTime, PUBLIC_START);
        assertEq(lengthMins, 60);
        assertEq(price, PUBLIC_PRICE);
        assertEq(alStart, AL_START);
        assertEq(alPrice, AL_PRICE);
        assertEq(alMax, AL_MAX);
    }

    receive() external payable {}
}

/// @dev Exercises {TalismanMinter.concludeMint} — the owner sweep that mints the
///      genesis sale's unsold remainder to the {Talismans} owner once the public
///      window has closed.
contract TalismanMinterConcludeTest is Test {
    Talismans internal nft;
    TalismanMinter internal minter;

    address internal alice = address(0xA11CE);
    // Conclude mints to the *Talismans* owner. Hand that to an EOA so the
    // batched safeMint loop lands on a plain address (a non-receiver contract
    // would revert), while the minter itself stays owned by this test contract.
    address internal treasury = address(0x7EA5);

    uint256 internal constant START = 1_000;
    uint256 internal constant LEN = 60; // minutes
    uint256 internal end;

    function setUp() public {
        nft = new Talismans();
        minter = new TalismanMinter(nft);
        nft.setMinter(address(minter));
        nft.transferOwnership(treasury);
        vm.prank(treasury);
        nft.acceptOwnership();
        end = START + LEN * 60;
    }

    /// @dev Configure a public window and warp to its close so concludeMint is
    ///      eligible (configured + ended).
    function _configureClosedSale() internal {
        minter.setMintConfig(START, LEN, 0, 0, 0, 0);
        vm.warp(end);
    }

    function test_concludeMint_revertsWhenNotConfigured() public {
        vm.warp(end);
        vm.expectRevert(TalismanMinter.MintNotConfigured.selector);
        minter.concludeMint(10);
    }

    function test_concludeMint_revertsWhileWindowOpen() public {
        minter.setMintConfig(START, LEN, 0, 0, 0, 0);
        vm.warp(end - 1); // one second before close
        vm.expectRevert(TalismanMinter.MintNotEnded.selector);
        minter.concludeMint(10);
    }

    function test_concludeMint_revertsForNonOwner() public {
        _configureClosedSale();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        minter.concludeMint(10);
    }

    function test_concludeMint_revertsAtZeroQuantity() public {
        _configureClosedSale();
        vm.expectRevert(TalismanMinter.InvalidQuantity.selector);
        minter.concludeMint(0);
    }

    /// @dev A capped batch mints `maxQuantity` to the Talismans owner, and the
    ///      sweep can be continued across calls.
    function test_concludeMint_mintsCappedBatchToTalismansOwner() public {
        _configureClosedSale();

        minter.concludeMint(10);
        assertEq(nft.genesisMinted(), 10);
        assertEq(nft.balanceOf(treasury), 10, "remainder must go to the Talismans owner");

        minter.concludeMint(5);
        assertEq(nft.genesisMinted(), 15);
        assertEq(nft.balanceOf(treasury), 15);
    }

    /// @dev An oversized `maxQuantity` clamps to the true remainder, completes
    ///      the supply, and any further conclude reverts {SoldOut}.
    function test_concludeMint_clampsToRemainingThenSoldOut() public {
        minter.setMintConfig(START, LEN, 0, 0, 0, 0);
        vm.warp(START);
        // One mint per wallet: eight distinct buyers sell out eight on the window.
        for (uint256 i; i < 8; ++i) {
            vm.prank(address(uint160(0x2000 + i)));
            minter.publicMint();
        }

        vm.warp(end);
        uint256 max = nft.MAX_GENESIS_SUPPLY();
        minter.concludeMint(max * 2); // far exceeds remaining → clamps

        assertEq(nft.genesisMinted(), max);
        assertEq(nft.balanceOf(treasury), max - 8, "sweep covers exactly the unsold remainder");
        assertEq(nft.balanceOf(address(uint160(0x2000))), 1, "buyer's token untouched");

        vm.expectRevert(TalismanMinter.SoldOut.selector);
        minter.concludeMint(1);
    }

    receive() external payable {}
}
