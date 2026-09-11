// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Talismans} from "../src/Talismans.sol";
import {TalismanSwapV1} from "../src/TalismanSwapV1.sol";
import {TalismanCore} from "../src/TalismanCore.sol";
import {TalismanMaterials} from "../src/TalismanMaterials.sol";
import {TalismanTransformationLib} from "../src/TalismanTransformationLib.sol";
import {NotRevealed} from "../src/TalismanErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract MockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockERC1155 {
    mapping(address => mapping(uint256 => uint256)) public balanceOf;

    function mint(address to, uint256 id, uint256 amount) external {
        balanceOf[to][id] += amount;
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata) external {
        require(from == msg.sender, "auth");
        balanceOf[from][id] -= amount;
        balanceOf[to][id] += amount;
    }
}

/// @title TalismanSwapV1 behaviour spec
/// @notice The three barter routes against a designated reserve wallet:
///
///         - Every price is a per-class table entry, indexed by
///           {classIndexOf}: 0..3 are Lithic/Lumic of 1..4 cores, 4..7 are
///           Mythic of 2..8.
///         - Exchange weight ({pointsOf}): Lithic/Lumic 2^(c-1); Mythic
///           unbound halves 2^(c/2).
///         - swap: 1 token for 1 reserve token of the same (pole, cores)
///           class; ETH fee from the swap fee table.
///         - swapUp: tokenIn (same pole, exactly one tier below) plus
///           feeTokens weighing exactly pointsOf(out) plus the class margin,
///           every fee token weighing at least the class fee floor; ETH fee
///           from the swap up fee table.
///         - swapDown: hand in one token, take several strictly lighter
///           reserve tokens summing to the class payout - clamped to the
///           input's core count while the premium is switched off; ETH fee
///           from the swap down fee table.
///         - Each route is opened per class by its own bitmask.
///         - Every id in a call must be distinct.
///         - Route outputs must be listed and past the shelf cooldown, which
///           is computed live (listing time + current cooldown).
///         - The contract custodies nothing; every route runs with the forge's
///           cut/merge pair DISABLED, so no route depends on a forge toggle.
///           Bond and cleave preserve weight exactly, merge does not, which is
///           what the swap-down payout cap is measured against.
///         - eject() is a one-way kill: everything reverts afterward except
///           owner() (zero) and the permissionless withdrawEth().
contract TalismanSwapV1Test is Test {
    Talismans internal nft;
    TalismanMaterials internal mats;
    TalismanSwapV1 internal swap;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal reserveWallet = address(0x2E5E27E);

    /// @dev The market floor of one core, the figure the launch schedule was
    ///      drawn against.
    uint256 internal constant FLOOR_UNIT = 0.007 ether;

    /// @dev The launch schedule's swap fee for ONE core - 5% of {FLOOR_UNIT},
    ///      set to sit alongside the collection's marketplace royalty. Every
    ///      class is priced at this times its core count.
    uint256 internal constant FEE_UNIT = 0.00035 ether;

    /// @dev Route masks. Bit i is the class {classIndexOf} numbers i: 0..3 are
    ///      Lithic/Lumic of 1..4 cores, 4..7 are Mythic of 2..8.
    uint8 internal constant ALL_CLASSES = 0xFF;
    uint8 internal constant NO_CLASSES = 0x00;
    uint8 internal constant PURE1 = 1 << 0;
    uint8 internal constant PURE2 = 1 << 1;
    uint8 internal constant PURE3 = 1 << 2;
    uint8 internal constant PURE4 = 1 << 3;
    uint8 internal constant MYTHIC2 = 1 << 4;
    uint8 internal constant MYTHIC4 = 1 << 5;
    uint8 internal constant MYTHIC6 = 1 << 6;
    uint8 internal constant MYTHIC8 = 1 << 7;

    event Swapped(address indexed user, uint256 indexed tokenIn, uint256 indexed tokenOut);
    event SwappedUp(address indexed user, uint256 indexed tokenIn, uint256[] feeTokens, uint256 indexed tokenOut);
    event SwappedDown(address indexed user, uint256 indexed tokenIn, uint256[] tokensOut);

    receive() external payable {}

    function setUp() public {
        nft = new Talismans();
        nft.setMinter(address(this));
        mats = new TalismanMaterials();
        nft.setMaterials(mats);
        // Bond/Cleave on (to craft Mythics), Cut/Merge OFF - the routes must
        // work without the forge pair, so no route depends on a forge toggle.
        nft.setTransformationSettings(true, false);

        swap = new TalismanSwapV1(nft);
        swap.setReserve(reserveWallet);
        swap.setRoutes(ALL_CLASSES, ALL_CLASSES, ALL_CLASSES);
        // The constructor ships the premium ON. These tests take the
        // conservative schedule as their baseline - payout is the core count, so
        // no route can ever outrun the forge - and the premium section below
        // switches it back on where that is what is under test.
        swap.setSwapDownPremiumEnabled(false);

        vm.prank(reserveWallet);
        nft.setApprovalForAll(address(swap), true);
        vm.prank(alice);
        nft.setApprovalForAll(address(swap), true);
        vm.prank(bob);
        nft.setApprovalForAll(address(swap), true);

        vm.roll(100);
        vm.warp(1_000_000);
        vm.prevrandao(bytes32(uint256(0xc0ffee)));
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    // --- crafting helpers (mint+reveal retries, as in the forge test suites) ---

    /// @dev Strays from the retry loop stay parked here so owner-enumeration
    ///      assertions (inventoryOfClass, balances) see only crafted tokens.
    address internal scratch = address(0x5C2A7C4);

    function _reveal(address to, bool wantLithic, uint256 want) internal returns (uint256 id) {
        for (uint256 attempt; attempt < 4096; ++attempt) {
            uint256 commitBlock;
            (id, commitBlock) = nft.mintWithCommitment(scratch);
            vm.roll(commitBlock + 1);
            vm.prevrandao(bytes32(uint256(keccak256(abi.encode("swap-test", to, wantLithic, want, attempt)))));
            nft.reveal(id);
            if (nft.coreCount(id) != want) {
                continue;
            }
            (TalismanMaterials.Essence essence,) = mats.elementOf(TalismanCore.materialId(nft.coresOf(id)[0]));
            if ((essence == TalismanMaterials.Essence.Lithic) == wantLithic) {
                vm.prank(scratch);
                nft.transferFrom(scratch, to, id);
                return id;
            }
        }
        revert("could not produce desired (pole, core count)");
    }

    /// @dev Bond a k-core Lithic and a k-core Lumic owned by `to` into a
    ///      2k-core Mythic.
    function _mythic(address to, uint256 halfCores) internal returns (uint256 id) {
        uint256 lithic = _reveal(to, true, halfCores);
        uint256 lumic = _reveal(to, false, halfCores);
        vm.prank(to);
        id = nft.bond(lithic, lumic);
    }

    /// @dev List `id` (already reserve-held) and warp past its cooldown.
    function _listAndCool(uint256 id) internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        swap.list(ids);
        vm.warp(block.timestamp + 1 hours);
    }

    /// @dev List every reserve-held id in one call, then warp past the cooldown.
    function _listAllAndCool(uint256[] memory ids) internal {
        swap.list(ids);
        vm.warp(block.timestamp + 1 hours);
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        out[0] = a;
        out[1] = b;
    }

    function _one(uint256 a) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = a;
    }

    function _fees(uint256 a) internal pure returns (uint256[] memory out) {
        return _one(a);
    }

    function _fees(uint256 a, uint256 b) internal pure returns (uint256[] memory out) {
        return _ids(a, b);
    }

    function _fees(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory out) {
        out = new uint256[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
    }

    /// @dev The swap fee the constructor's launch schedule ships for a class,
    ///      rebuilt from the shape that schedule was drawn to: one unit per
    ///      core, a Mythic holding two halves' worth. `halfCores` is the whole
    ///      core count for a Pure and half of it for a Mythic. The contract
    ///      itself reads a table, so this is what the table is asserted
    ///      AGAINST, not how it is looked up - see
    ///      test_SetSwapFeesRepricesPerClass for a schedule off this shape.
    function _swapEth(uint256 halfCores, bool mythic) internal pure returns (uint256) {
        return (mythic ? 2 * halfCores : halfCores) * FEE_UNIT;
    }

    /// @dev What a swap up off `tokenIn` charges, from {swapUpTermsOf}. Keyed by
    ///      the talisman handed in, like every other price in the contract.
    function _upPrice(uint256 tokenIn) internal view returns (uint256 price) {
        (price,,) = swap.swapUpTermsOf(tokenIn);
    }

    function _upFloor(uint256 tokenIn) internal view returns (uint256 floor) {
        (, floor,) = swap.swapUpTermsOf(tokenIn);
    }

    /// @dev The full default table the constructor writes, so a test that only
    ///      wants to move one entry can send the rest back unchanged.
    function _defaultSwapFees() internal pure returns (uint64[8] memory) {
        return [
            uint64(0.00035 ether),
            0.0007 ether,
            0.00105 ether,
            0.0014 ether,
            0.0007 ether,
            0.0014 ether,
            0.0021 ether,
            0.0028 ether
        ];
    }

    function _defaultPayouts() internal pure returns (uint8[8] memory) {
        return [1, 2, 4, 5, 2, 4, 8, 10];
    }

    function _defaultSwapDownFees() internal pure returns (uint64[8] memory) {
        return
            [
                0,
                uint64(0.0007 ether),
                0.00105 ether,
                0.0014 ether,
                0.0007 ether,
                0.0014 ether,
                0.0021 ether,
                0.0028 ether
            ];
    }

    function _defaultMargins() internal pure returns (uint8[8] memory) {
        return [1, 2, 4, 0, 2, 4, 8, 0];
    }

    function _defaultFloors() internal pure returns (uint8[8] memory) {
        return [0, 1, 2, 0, 0, 1, 2, 0];
    }

    function _zeroEthFees() internal pure returns (uint64[8] memory out) {
        return out;
    }

    // --- swap ---

    function test_SwapHappyPath() public {
        uint256 tokenIn = _reveal(alice, true, 1);
        uint256 tokenOut = _reveal(reserveWallet, true, 1);
        _listAndCool(tokenOut);

        assertEq(swap.quoteSwap(tokenIn, tokenOut), FEE_UNIT);

        vm.expectEmit(true, true, true, true, address(swap));
        emit Swapped(alice, tokenIn, tokenOut);
        vm.prank(alice);
        swap.swap{value: FEE_UNIT}(tokenIn, tokenOut);

        assertEq(nft.ownerOf(tokenIn), reserveWallet);
        assertEq(nft.ownerOf(tokenOut), alice);
        assertEq(address(swap).balance, FEE_UNIT);
        // the contract never holds talismans
        assertEq(nft.balanceOf(address(swap)), 0);
        // the swapped-in token starts a fresh cooldown; the outgoing stamp is cleared
        assertEq(swap.selectableAt(tokenIn), block.timestamp + 1 hours);
        assertEq(swap.selectableAt(tokenOut), 0);
    }

    function test_SwapFeeScalesWithCoreCount() public {
        // A 3-core is charged three units, not the one a 1-core pays. The fee
        // tracks cores, which is what the market prices a talisman by - not
        // weight, which grows twice as fast up the tier ladder.
        uint256 tokenIn = _reveal(alice, true, 3);
        uint256 tokenOut = _reveal(reserveWallet, true, 3);
        _listAndCool(tokenOut);

        assertEq(swap.quoteSwap(tokenIn, tokenOut), 3 * FEE_UNIT);
        vm.expectRevert(abi.encodeWithSelector(TalismanSwapV1.WrongFee.selector, 3 * FEE_UNIT, FEE_UNIT));
        vm.prank(alice);
        swap.swap{value: FEE_UNIT}(tokenIn, tokenOut);

        vm.prank(alice);
        swap.swap{value: 3 * FEE_UNIT}(tokenIn, tokenOut);
        assertEq(nft.ownerOf(tokenOut), alice);
        assertEq(address(swap).balance, 3 * FEE_UNIT);
    }

    function test_SwapWorksWhileCutMergeDisabled() public {
        assertFalse(nft.cutAndMergeEnabled());
        test_SwapHappyPath();
    }

    function test_SwapUpWorksWhileCutMergeDisabled() public {
        assertFalse(nft.cutAndMergeEnabled());
        test_SwapUpHappyPath();
    }

    function test_SwapRevertsOnCoreCountMismatch() public {
        uint256 tokenIn = _reveal(alice, true, 1);
        uint256 tokenOut = _reveal(reserveWallet, true, 2);
        _listAndCool(tokenOut);

        vm.expectRevert(abi.encodeWithSelector(TalismanSwapV1.ClassMismatch.selector, tokenIn, tokenOut));
        vm.prank(alice);
        swap.swap{value: FEE_UNIT}(tokenIn, tokenOut);
    }

    function test_SwapRevertsOnPoleMismatch() public {
        uint256 tokenIn = _reveal(alice, true, 1);
        uint256 tokenOut = _reveal(reserveWallet, false, 1);
        _listAndCool(tokenOut);

        vm.expectRevert(abi.encodeWithSelector(TalismanSwapV1.ClassMismatch.selector, tokenIn, tokenOut));
        vm.prank(alice);
        swap.swap{value: FEE_UNIT}(tokenIn, tokenOut);
    }

    function test_SwapRevertsOnWrongFee() public {
        uint256 tokenIn = _reveal(alice, true, 1);
        uint256 tokenOut = _reveal(reserveWallet, true, 1);
        _listAndCool(tokenOut);

        vm.expectRevert(abi.encodeWithSelector(TalismanSwapV1.WrongFee.selector, FEE_UNIT, FEE_UNIT - 1));
        vm.prank(alice);
        swap.swap{value: FEE_UNIT - 1}(tokenIn, tokenOut);
    }

    function test_SwapRevertsWhenDisabled() public {
        uint256 tokenIn = _reveal(alice, true, 1);
        uint256 tokenOut = _reveal(reserveWallet, true, 1);
        _listAndCool(tokenOut);
        swap.setRoutes(NO_CLASSES, ALL_CLASSES, ALL_CLASSES);

        vm.expectRevert(TalismanSwapV1.RouteDisabled.selector);
        vm.prank(alice);
        swap.swap{value: FEE_UNIT}(tokenIn, tokenOut);
    }

    function test_SwapUpStillWorksWhenSwapDisabled() public {
        // routes are independent: closing swap leaves swapUp open
        swap.setRoutes(NO_CLASSES, ALL_CLASSES, ALL_CLASSES);
        test_SwapUpHappyPath();
    }

    function test_SwapStillWorksWhenSwapUpDisabled() public {
        swap.setRoutes(ALL_CLASSES, NO_CLASSES, ALL_CLASSES);
        test_SwapHappyPath();
    }

    function test_SwapMythicForMythic() public {
        // 2-core Mythic = two 1-core halves -> fee 2 * unit (one per core)
        uint256 tokenIn = _mythic(alice, 1);
        uint256 tokenOut = _mythic(reserveWallet, 1);
        _listAndCool(tokenOut);

        assertEq(swap.quoteSwap(tokenIn, tokenOut), 2 * FEE_UNIT);
        vm.prank(alice);
        swap.swap{value: 2 * FEE_UNIT}(tokenIn, tokenOut);
        assertEq(nft.ownerOf(tokenOut), alice);
    }

    function test_SwapMythicFeeIsUnboundHalves() public {
        // pointsOf = unbound halves: 4-core -> 4; 8-core -> 16
        uint256 in4 = _mythic(alice, 2);
        uint256 out4 = _mythic(reserveWallet, 2);
        _listAndCool(out4);
        assertEq(swap.pointsOf(in4), 4);
        assertEq(swap.quoteSwap(in4, out4), _swapEth(2, true));
        vm.prank(alice);
        swap.swap{value: _swapEth(2, true)}(in4, out4);
        assertEq(nft.ownerOf(out4), alice);

        uint256 in8 = _mythic(alice, 4);
        uint256 out8 = _mythic(reserveWallet, 4);
        _listAndCool(out8);
        assertEq(swap.pointsOf(in8), 16);
        assertEq(swap.quoteSwap(in8, out8), _swapEth(4, true));
        vm.prank(alice);
        swap.swap{value: _swapEth(4, true)}(in8, out8);
        assertEq(nft.ownerOf(out8), alice);
    }

    function test_SwapFeeIsOneUnitPerCore() public {
        // The fee is a flat share of what a talisman is worth, so it tracks
        // cores rather than weight. A Prime pays four units, not the eight its
        // weight would suggest, and a Mythic pays for both of its halves.
        uint256 inPure = _reveal(alice, true, 4);
        uint256 outPure = _reveal(reserveWallet, true, 4);
        _listAndCool(outPure);
        assertEq(swap.quoteSwap(inPure, outPure), 4 * FEE_UNIT);
        assertEq(swap.pointsOf(inPure), 8, "weight is still 8; the fee just does not follow it");
        vm.prank(alice);
        swap.swap{value: _swapEth(4, false)}(inPure, outPure);

        uint256 in6 = _mythic(alice, 3);
        uint256 out6 = _mythic(reserveWallet, 3);
        _listAndCool(out6);
        assertEq(swap.quoteSwap(in6, out6), 6 * FEE_UNIT); // two 3-core halves
        vm.prank(alice);
        swap.swap{value: _swapEth(3, true)}(in6, out6);

        uint256 in8 = _mythic(alice, 4);
        uint256 out8 = _mythic(reserveWallet, 4);
        _listAndCool(out8);
        assertEq(swap.quoteSwap(in8, out8), 8 * FEE_UNIT); // two 4-core halves
        vm.prank(alice);
        swap.swap{value: _swapEth(4, true)}(in8, out8);
    }

    function test_MythicCostsExactlyTwoPureHalvesOnEveryRoute() public {
        // The governing identity: a Mythic is a Lithic half and a Lumic half
        // bonded, so every price it carries is the half's price taken twice.
        uint256[4] memory pureIds;
        uint256[4] memory mythIds;
        for (uint256 r = 1; r <= 4; ++r) {
            pureIds[r - 1] = _reveal(reserveWallet, true, r);
            mythIds[r - 1] = _mythic(reserveWallet, r);
        }

        for (uint256 r = 1; r <= 4; ++r) {
            uint256 p = pureIds[r - 1];
            uint256 m = mythIds[r - 1];

            // pointsOf
            assertEq(swap.pointsOf(m), 2 * swap.pointsOf(p), "pointsOf");
            // swap ETH leg
            assertEq(_swapEth(r, true), 2 * _swapEth(r, false), "swap fee");
            // swapDown payout, in points
            assertEq(swap.swapDownPayout(m), 2 * swap.swapDownPayout(p), "swapDown payout");
            // swapUp terms are keyed by the talisman handed in, so they exist on
            // every tier below the top one
            if (r <= 3) {
                assertEq(_upPrice(m), 2 * _upPrice(p), "swapUp price");
                // the floor is a per-token rule, so it MATCHES rather than doubles
                assertEq(_upFloor(m), _upFloor(p), "fee floor");
            }
        }
    }

    function test_SwapRevertsUnlisted() public {
        uint256 tokenIn = _reveal(alice, true, 1);
        uint256 tokenOut = _reveal(reserveWallet, true, 1);

        vm.expectRevert(abi.encodeWithSelector(TalismanSwapV1.NotListed.selector, tokenOut));
        vm.prank(alice);
        swap.swap{value: FEE_UNIT}(tokenIn, tokenOut);
    }

    function test_SwapRevertsDuringCooldownAndPassesAtBoundary() public {
        uint256 tokenIn = _reveal(alice, true, 1);
        uint256 tokenOut = _reveal(reserveWallet, true, 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenOut;
        swap.list(ids);
        uint256 from = swap.selectableAt(tokenOut);

        vm.warp(from - 1);
        vm.expectRevert(abi.encodeWithSelector(TalismanSwapV1.CooldownActive.selector, tokenOut, from));
        vm.prank(alice);
        swap.swap{value: FEE_UNIT}(tokenIn, tokenOut);

        vm.warp(from);
        vm.prank(alice);
        swap.swap{value: FEE_UNIT}(tokenIn, tokenOut);
        assertEq(nft.ownerOf(tokenOut), alice);
    }

    function test_SwapRevertsWhenTokenLeftReserve() public {
        uint256 tokenIn = _reveal(alice, true, 1);
        uint256 tokenOut = _reveal(reserveWallet, true, 1);
        _listAndCool(tokenOut);
        vm.prank(reserveWallet);
        nft.transferFrom(reserveWallet, bob, tokenOut);

        vm.expectRevert(abi.encodeWithSelector(TalismanSwapV1.NotInReserve.selector, tokenOut));
        vm.prank(alice);
        swap.swap{value: FEE_UNIT}(tokenIn, tokenOut);
    }

    function test_SwapRevertsWhenReserveUnset() public {
        uint256 tokenIn = _reveal(alice, true, 1);
        uint256 tokenOut = _reveal(reserveWallet, true, 1);
        _listAndCool(tokenOut);
        swap.setReserve(address(0));

        vm.expectRevert(TalismanSwapV1.ReserveNotSet.selector);
        vm.prank(alice);
        swap.swap{value: FEE_UNIT}(tokenIn, tokenOut);
    }

    function test_SwapFailsClosedWhenReserveRevokesApproval() public {
        uint256 tokenIn = _reveal(alice, true, 1);
        uint256 tokenOut = _reveal(reserveWallet, true, 1);
        _listAndCool(tokenOut);
        vm.prank(reserveWallet);
        nft.setApprovalForAll(address(swap), false);

        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, address(swap), tokenOut)
        );
        vm.prank(alice);
        swap.swap{value: FEE_UNIT}(tokenIn, tokenOut);
    }

    function test_QuoteSwapRevertsLikeExecution() public {
        uint256 tokenIn = _reveal(alice, true, 1);
        uint256 tokenOut = _reveal(reserveWallet, false, 1);
        _listAndCool(tokenOut);

        bytes memory expected = abi.encodeWithSelector(TalismanSwapV1.ClassMismatch.selector, tokenIn, tokenOut);
        vm.expectRevert(expected);
        swap.quoteSwap(tokenIn, tokenOut);
        vm.expectRevert(expected);
        vm.prank(alice);
        swap.swap{value: FEE_UNIT}(tokenIn, tokenOut);
    }

    // --- swapUp ---
    // tokenIn = same pole, one tier below (pure -1 core, Mythic -2).
    // feeTokens = any pole, each weighing at least the class fee floor;
    // tokenIn + fees == pointsOf(out) + the class margin.
    //
    // The margin and floor are owner-set tables. At the launch schedule these
    // cases exercise, the margin is half the output weight and the floor a
    // quarter of it on BOTH lines, which is what makes a Mythic ladder cost
    // exactly twice its Pure counterpart - a Mythic is two Pures bonded, and
    // bond is free. See test_SwapUpLadderCostsTwiceOnMythic.

    function test_SwapUpHappyPath() public {
        // Lithic 1-core up to Lithic 2-core: fee needs 2 points (two 1-core; one may be Lumic)
        uint256 tokenIn = _reveal(alice, true, 1);
        uint256 feeA = _reveal(alice, true, 1);
        uint256 feeB = _reveal(alice, false, 1);
        uint256 tokenOut = _reveal(reserveWallet, true, 2);
        _listAndCool(tokenOut);

        uint256[] memory fees = _fees(feeA, feeB);
        swap.quoteSwapUp(tokenIn, fees, tokenOut);

        vm.expectEmit(true, true, true, true, address(swap));
        emit SwappedUp(alice, tokenIn, fees, tokenOut);
        vm.prank(alice);
        swap.swapUp(tokenIn, fees, tokenOut);

        assertEq(nft.ownerOf(tokenIn), reserveWallet);
        assertEq(nft.ownerOf(feeA), reserveWallet);
        assertEq(nft.ownerOf(feeB), reserveWallet);
        assertEq(nft.ownerOf(tokenOut), alice);
        assertEq(nft.balanceOf(address(swap)), 0);
        assertEq(address(swap).balance, 0);
        assertEq(swap.selectableAt(tokenIn), block.timestamp + 1 hours);
        assertEq(swap.selectableAt(tokenOut), 0);
    }

    function test_SwapUpToThreeCores() public {
        // Lithic 2-core -> 3-core; margin 2 -> required 6; fee needs 4 points
        uint256 tokenIn = _reveal(alice, true, 2);
        uint256 feeA = _reveal(alice, true, 2);
        uint256 feeB = _reveal(alice, true, 1);
        uint256 feeC = _reveal(alice, false, 1);
        uint256 tokenOut = _reveal(reserveWallet, true, 3);
        _listAndCool(tokenOut);

        uint256[] memory fees = new uint256[](3);
        fees[0] = feeA;
        fees[1] = feeB;
        fees[2] = feeC;
        vm.prank(alice);
        swap.swapUp(tokenIn, fees, tokenOut);
        assertEq(nft.ownerOf(tokenOut), alice);
    }

    function test_SwapUpToFourCores() public {
        // Lumic 3-core -> 4-core; margin 4 -> required 12; fee needs 8 points
        uint256 tokenIn = _reveal(alice, false, 3);
        uint256 feeA = _reveal(alice, false, 4);
        uint256 tokenOut = _reveal(reserveWallet, false, 4);
        _listAndCool(tokenOut);

        vm.prank(alice);
        swap.swapUp(tokenIn, _fees(feeA), tokenOut);
        assertEq(nft.ownerOf(tokenOut), alice);
    }

    function test_SwapUpRevertsOnWrongPriorTier() public {
        // 1-core cannot upgrade to 3-core (needs 2-core prior)
        uint256 tokenIn = _reveal(alice, true, 1);
        uint256 feeA = _reveal(alice, true, 4);
        uint256 tokenOut = _reveal(reserveWallet, true, 3);
        _listAndCool(tokenOut);

        vm.expectRevert(abi.encodeWithSelector(TalismanSwapV1.MissingPriorTier.selector, 2));
        vm.prank(alice);
        swap.swapUp(tokenIn, _fees(feeA), tokenOut);
    }

    function test_SwapUpRevertsOnSameTier() public {
        // same-tier core-paid path is removed: 4-core + 1-core -> 4-core needs prior 3-core
        uint256 tokenIn = _reveal(alice, true, 4);
        uint256 feeA = _reveal(alice, true, 1);
        uint256 tokenOut = _reveal(reserveWallet, true, 4);
        _listAndCool(tokenOut);

        vm.expectRevert(abi.encodeWithSelector(TalismanSwapV1.MissingPriorTier.selector, 3));
        vm.prank(alice);
        swap.swapUp(tokenIn, _fees(feeA), tokenOut);
    }

    function test_SwapUpRevertsOnTradeDown() public {
        uint256 tokenIn = _reveal(alice, true, 2);
        uint256 feeA = _reveal(alice, true, 1);
        uint256 tokenOut = _reveal(reserveWallet, true, 1);
        _listAndCool(tokenOut);

        vm.expectRevert(abi.encodeWithSelector(TalismanSwapV1.MissingPriorTier.selector, 0));
        vm.prank(alice);
        swap.swapUp(tokenIn, _fees(feeA), tokenOut);
    }

    function test_SwapUpRevertsOnEmptyFeeTokens() public {
        uint256 tokenIn = _reveal(alice, true, 1);
        uint256 tokenOut = _reveal(reserveWallet, true, 2);
        _listAndCool(tokenOut);

        uint256[] memory fees = new uint256[](0);
        vm.expectRevert(TalismanSwapV1.TooFewFeeTokens.selector);
        vm.prank(alice);
        swap.swapUp(tokenIn, fees, tokenOut);
    }

    function test_SwapUpRevertsWhenDisabled() public {
        uint256 tokenIn = _reveal(alice, true, 1);
        uint256 feeA = _reveal(alice, true, 1);
        uint256 feeB = _reveal(alice, true, 1);
        uint256 tokenOut = _reveal(reserveWallet, true, 2);
        _listAndCool(tokenOut);
        swap.setRoutes(ALL_CLASSES, NO_CLASSES, ALL_CLASSES);

        vm.expectRevert(TalismanSwapV1.RouteDisabled.selector);
        vm.prank(alice);
        swap.swapUp(tokenIn, _fees(feeA, feeB), tokenOut);
    }

    function test_SwapUpRevertsWithoutEnoughFeePoints() public {
        // prior 1-core (1) + one fee 1-core (1) = 2, need 3 for 2-core out
        uint256 tokenIn = _reveal(alice, true, 1);
        uint256 feeA = _reveal(alice, true, 1);
        uint256 tokenOut = _reveal(reserveWallet, true, 2);
        _listAndCool(tokenOut);

        vm.expectRevert(abi.encodeWithSelector(TalismanSwapV1.WrongPoints.selector, 3, 2));
        vm.prank(alice);
        swap.swapUp(tokenIn, _fees(feeA), tokenOut);
    }

    function test_SwapUpRevertsOnEssenceMismatch() public {
        uint256 tokenIn = _reveal(alice, true, 1);
        uint256 feeA = _reveal(alice, true, 1);
        uint256 feeB = _reveal(alice, true, 1);
        uint256 tokenOut = _reveal(reserveWallet, false, 2);
        _listAndCool(tokenOut);

        vm.expectRevert(abi.encodeWithSelector(TalismanSwapV1.ClassMismatch.selector, tokenIn, tokenOut));
        vm.prank(alice);
        swap.swapUp(tokenIn, _fees(feeA, feeB), tokenOut);
    }

    function test_SwapUpRevertsEarlyOnPointsOvershoot() public {
        // Mythic 6-core prior (8) into Mythic 8-core (16): price 24, so the fee
        // bag owes 16. Eight Mythic 8-core fees weigh 128; the running total
        // passes 24 on the second one, and weights only ever go up, so the loop
        // gives up there instead of pricing the other six.
        uint256 tokenIn = _mythic(alice, 3);
        uint256 tokenOut = _mythic(reserveWallet, 4);
        _listAndCool(tokenOut);

        uint256[] memory fees = new uint256[](8);
        for (uint256 i; i < 8; ++i) {
            fees[i] = _mythic(alice, 4);
        }
        // 8 (prior) + 16 + 16 = 40, reported the moment it exceeds 24.
        vm.expectRevert(abi.encodeWithSelector(TalismanSwapV1.WrongPoints.selector, 24, 40));
        vm.prank(alice);
        swap.swapUp(tokenIn, fees, tokenOut);
    }

    function test_SwapUpRevertsOnFeeTokenBelowFloor() public {
        // Lumic 3-core (4) into Lumic 4-core (8): price 12, fee bag owes 8, and
        // no fee token may weigh under 8/4 = 2. Eight 1-cores would have paid
        // this before the floor; now they cannot.
        uint256 tokenIn = _reveal(alice, false, 3);
        uint256 dust = _reveal(alice, true, 1);
        uint256 tokenOut = _reveal(reserveWallet, false, 4);
        _listAndCool(tokenOut);

        assertEq(_upFloor(tokenIn), 2);
        assertEq(_upPrice(tokenIn), 12);

        uint256[] memory fees = new uint256[](8);
        fees[0] = dust;
        for (uint256 i = 1; i < 8; ++i) {
            fees[i] = _reveal(alice, true, 1);
        }
        vm.expectRevert(abi.encodeWithSelector(TalismanSwapV1.FeeTokenBelowFloor.selector, dust, 2));
        vm.prank(alice);
        swap.swapUp(tokenIn, fees, tokenOut);

        // Four 2-cores clear the floor and pay the same 8 points.
        uint256[] memory ok = new uint256[](4);
        for (uint256 i; i < 4; ++i) {
            ok[i] = _reveal(alice, true, 2);
        }
        vm.prank(alice);
        swap.swapUp(tokenIn, ok, tokenOut);
        assertEq(nft.ownerOf(tokenOut), alice);
    }

    function test_SwapUpFloorIsZeroOnTheBottomTier() public {
        // pointsOf(Pure 2-core)/4 == 0, so the entry tier still takes 1-cores.
        uint256 tokenIn = _reveal(alice, true, 1);
        uint256 feeA = _reveal(alice, true, 1);
        uint256 feeB = _reveal(alice, false, 1);
        uint256 tokenOut = _reveal(reserveWallet, true, 2);
        _listAndCool(tokenOut);

        assertEq(_upFloor(tokenIn), 0);
        vm.prank(alice);
        swap.swapUp(tokenIn, _fees(feeA, feeB), tokenOut);
        assertEq(nft.ownerOf(tokenOut), alice);
    }

    function test_SwapUpLadderCostsTwiceOnMythic() public {
        // The margin identity: with m = w/2 on both lines, climbing to a Mythic
        // tier costs exactly twice the matching Pure tier, because a Mythic is
        // two Pures bonded and bond is free. Prices: Pure 2/3/4-core = 3/6/12,
        // Mythic 4/6/8-core = 6/12/24.
        uint256 pure1 = _reveal(reserveWallet, true, 1);
        uint256 pure2 = _reveal(reserveWallet, true, 2);
        uint256 pure3 = _reveal(reserveWallet, true, 3);
        uint256 myth2 = _mythic(reserveWallet, 1);
        uint256 myth4 = _mythic(reserveWallet, 2);
        uint256 myth6 = _mythic(reserveWallet, 3);

        assertEq(_upPrice(pure1), 3);
        assertEq(_upPrice(pure2), 6);
        assertEq(_upPrice(pure3), 12);
        assertEq(_upPrice(myth2), 2 * _upPrice(pure1));
        assertEq(_upPrice(myth4), 2 * _upPrice(pure2));
        assertEq(_upPrice(myth6), 2 * _upPrice(pure3));
    }

    function test_SwapUpRevertsOnUnrevealedFee() public {
        uint256 tokenIn = _reveal(alice, true, 1);
        (uint256 unrevealed,) = nft.mintWithCommitment(alice);
        uint256 tokenOut = _reveal(reserveWallet, true, 2);
        _listAndCool(tokenOut);

        vm.expectRevert(abi.encodeWithSelector(NotRevealed.selector, unrevealed));
        vm.prank(alice);
        swap.swapUp(tokenIn, _fees(unrevealed), tokenOut);
    }

    function test_SwapUpRevertsOnDuplicateFee() public {
        uint256 tokenIn = _reveal(alice, true, 1);
        uint256 feeA = _reveal(alice, true, 1);
        uint256 tokenOut = _reveal(reserveWallet, true, 2);
        _listAndCool(tokenOut);

        // One id sent twice weighs twice in the points sum but can only be
        // transferred once, so it is rejected up front rather than reverting
        // mid-settlement - the quote and the swap must agree.
        bytes memory expected = abi.encodeWithSelector(TalismanSwapV1.DuplicateToken.selector, feeA);
        vm.expectRevert(expected);
        swap.quoteSwapUp(tokenIn, _fees(feeA, feeA), tokenOut);
        vm.expectRevert(expected);
        vm.prank(alice);
        swap.swapUp(tokenIn, _fees(feeA, feeA), tokenOut);
    }

    function test_SwapUpRevertsWhenTokenInRepeatsInFees() public {
        uint256 tokenIn = _reveal(alice, true, 1);
        uint256 feeA = _reveal(alice, true, 1);
        uint256 tokenOut = _reveal(reserveWallet, true, 2);
        _listAndCool(tokenOut);

        bytes memory expected = abi.encodeWithSelector(TalismanSwapV1.DuplicateToken.selector, tokenIn);
        vm.expectRevert(expected);
        swap.quoteSwapUp(tokenIn, _fees(tokenIn, feeA), tokenOut);
        vm.expectRevert(expected);
        vm.prank(alice);
        swap.swapUp(tokenIn, _fees(tokenIn, feeA), tokenOut);
    }

    function test_QuoteSwapUpRevertsLikeExecution() public {
        uint256 tokenIn = _reveal(alice, true, 1);
        uint256 feeA = _reveal(alice, true, 1);
        uint256 tokenOut = _reveal(reserveWallet, true, 2);
        _listAndCool(tokenOut);

        bytes memory expected = abi.encodeWithSelector(TalismanSwapV1.WrongPoints.selector, 3, 2);
        vm.expectRevert(expected);
        swap.quoteSwapUp(tokenIn, _fees(feeA), tokenOut);
        vm.expectRevert(expected);
        vm.prank(alice);
        swap.swapUp(tokenIn, _fees(feeA), tokenOut);

        expected = abi.encodeWithSelector(TalismanSwapV1.MissingPriorTier.selector, 2);
        uint256 wrongPrior = _reveal(alice, true, 1);
        uint256 fineOut = _reveal(reserveWallet, true, 3);
        _listAndCool(fineOut);
        uint256[] memory fees = new uint256[](3);
        fees[0] = _reveal(alice, true, 1);
        fees[1] = _reveal(alice, true, 1);
        fees[2] = _reveal(alice, true, 1);
        vm.expectRevert(expected);
        swap.quoteSwapUp(wrongPrior, fees, fineOut);
        vm.expectRevert(expected);
        vm.prank(alice);
        swap.swapUp(wrongPrior, fees, fineOut);
    }

    function test_SwapUpMythicHappyPath() public {
        // Mythic 2-core -> 4-core; unbound weights 2 -> 4; price 6, so the fee
        // bag owes 4 points (e.g. two 2-cores). Floor is 4/4 = 1.
        uint256 tokenIn = _mythic(alice, 1);
        uint256 feeA = _reveal(alice, false, 2);
        uint256 feeB = _reveal(alice, true, 2);
        uint256 tokenOut = _mythic(reserveWallet, 2);
        _listAndCool(tokenOut);

        uint256[] memory fees = _fees(feeA, feeB);
        swap.quoteSwapUp(tokenIn, fees, tokenOut);

        vm.expectEmit(true, true, true, true, address(swap));
        emit SwappedUp(alice, tokenIn, fees, tokenOut);
        vm.prank(alice);
        swap.swapUp(tokenIn, fees, tokenOut);
        assertEq(nft.ownerOf(tokenOut), alice);
        assertEq(nft.ownerOf(tokenIn), reserveWallet);
    }

    function test_SwapUpMythicWrongPriorTier() public {
        // Mythic 4-core cannot be the prior for Mythic 4-core out (needs Mythic 2-core)
        uint256 tokenIn = _mythic(alice, 2);
        uint256 feeA = _reveal(alice, true, 1);
        uint256 tokenOut = _mythic(reserveWallet, 2);
        _listAndCool(tokenOut);

        vm.expectRevert(abi.encodeWithSelector(TalismanSwapV1.MissingPriorTier.selector, 2));
        vm.prank(alice);
        swap.swapUp(tokenIn, _fees(feeA), tokenOut);
    }

    function test_SwapUpMythicToSixCore() public {
        // Mythic 4-core -> 6-core; margin 4 -> price 12; fee bag owes 8 points
        // with nothing under 8/4 = 2.
        uint256 tokenIn = _mythic(alice, 2);
        uint256 tokenOut = _mythic(reserveWallet, 3);
        _listAndCool(tokenOut);

        uint256[] memory fees = new uint256[](2);
        fees[0] = _reveal(alice, true, 3);
        fees[1] = _reveal(alice, false, 3);
        vm.prank(alice);
        swap.swapUp(tokenIn, fees, tokenOut);
        assertEq(nft.ownerOf(tokenOut), alice);
    }

    function test_SwapUpMythicToEightCore() public {
        // Mythic 6-core -> 8-core; margin 8 -> price 24; fee bag owes 16 points
        // with nothing under 16/4 = 4. Two Pure 4-cores pay it exactly - the
        // apex now costs apex tribute rather than a pile of dust.
        uint256 tokenIn = _mythic(alice, 3);
        uint256 tokenOut = _mythic(reserveWallet, 4);
        _listAndCool(tokenOut);

        uint256[] memory fees = new uint256[](2);
        fees[0] = _reveal(alice, true, 4);
        fees[1] = _reveal(alice, false, 4);
        vm.prank(alice);
        swap.swapUp(tokenIn, fees, tokenOut);
        assertEq(nft.ownerOf(tokenOut), alice);
    }

    function test_SwapUpMythicFeeTokenUsesUnboundWeight() public {
        // Mythic 2-core -> 4-core: price 6, so a Mythic 4-core fee settles it
        // exactly, because it weighs 4 unbound rather than 8.
        uint256 tokenIn = _mythic(alice, 1);
        uint256 feeUnbound = _mythic(alice, 2);
        uint256 tokenOut = _mythic(reserveWallet, 2);
        _listAndCool(tokenOut);

        // A Mythic 6-core weighs 8 unbound, overshooting the same bag.
        uint256 feeHeavy = _mythic(alice, 3);
        vm.expectRevert(abi.encodeWithSelector(TalismanSwapV1.WrongPoints.selector, 6, 10));
        vm.prank(alice);
        swap.swapUp(tokenIn, _fees(feeHeavy), tokenOut);

        vm.prank(alice);
        swap.swapUp(tokenIn, _fees(feeUnbound), tokenOut);
        assertEq(nft.ownerOf(tokenOut), alice);
    }

    function test_SwapUpMythicCannotTargetTwoCore() public {
        // no Mythic tier below 2-core
        uint256 tokenIn = _mythic(alice, 2);
        uint256 feeA = _reveal(alice, true, 1);
        uint256 tokenOut = _mythic(reserveWallet, 1);
        _listAndCool(tokenOut);

        vm.expectRevert(abi.encodeWithSelector(TalismanSwapV1.MissingPriorTier.selector, 0));
        vm.prank(alice);
        swap.swapUp(tokenIn, _fees(feeA), tokenOut);
    }

    // --- swapDown ---
    // One token in, several strictly lighter reserve tokens out, weights summing
    // to one point per core of the input. This is the only route that moves tier
    // INTO the reserve.
    //
    // Cores are what the forge conserves - bond, cleave, cut and merge only
    // rearrange them. Weight is a convex price laid over that, running one to two
    // points per core, so a payout of p points buys at most p cores. Paying back
    // the core count is therefore the most that can be returned without a trip
    // through the forge coming out ahead, whichever transformations are enabled.

    function test_SwapDownHappyPath() public {
        // Pure 4-core: 4 cores, weight 8 -> 4 points back, e.g. two Pure 2-cores.
        uint256 tokenIn = _reveal(alice, true, 4);
        uint256 outA = _reveal(reserveWallet, true, 2);
        uint256 outB = _reveal(reserveWallet, false, 2);
        _listAllAndCool(_ids(outA, outB));

        assertEq(swap.swapDownPayout(tokenIn), 4);
        uint256[] memory outs = _ids(outA, outB);
        uint256 fee = swap.quoteSwapDown(tokenIn, outs);
        assertEq(fee, 4 * FEE_UNIT);

        vm.expectEmit(true, true, true, true, address(swap));
        emit SwappedDown(alice, tokenIn, outs);
        vm.prank(alice);
        swap.swapDown{value: fee}(tokenIn, outs);

        // The apex piece lands in the reserve; the caller takes the mass.
        assertEq(nft.ownerOf(tokenIn), reserveWallet);
        assertEq(nft.ownerOf(outA), alice);
        assertEq(nft.ownerOf(outB), alice);
        assertEq(nft.balanceOf(address(swap)), 0);
        assertEq(address(swap).balance, fee);
        // Taken-in stock starts its own shelf clock; handed-out stock is cleared.
        assertEq(swap.selectableAt(tokenIn), block.timestamp + 1 hours);
        assertEq(swap.selectableAt(outA), 0);
        assertEq(swap.selectableAt(outB), 0);
    }

    function test_SwapDownPaysOnePointPerCore() public {
        assertEq(swap.swapDownPayout(_reveal(alice, true, 2)), 2);
        assertEq(swap.swapDownPayout(_reveal(alice, true, 3)), 3);
        assertEq(swap.swapDownPayout(_reveal(alice, true, 4)), 4);
        assertEq(swap.swapDownPayout(_mythic(alice, 1)), 2);
        assertEq(swap.swapDownPayout(_mythic(alice, 2)), 4);
        assertEq(swap.swapDownPayout(_mythic(alice, 3)), 6);
        assertEq(swap.swapDownPayout(_mythic(alice, 4)), 8);
    }

    function test_SwapDownPayoutNeverOutrunsTheForge() public {
        // The soundness bound: a payout of p points buys at most p cores (taken
        // as 1-cores, the least dense denomination), so the payout must not
        // exceed the cores handed in. It is tight at every class by construction.
        uint256[7] memory ids = [
            _reveal(alice, true, 2),
            _reveal(alice, true, 3),
            _reveal(alice, true, 4),
            _mythic(alice, 1),
            _mythic(alice, 2),
            _mythic(alice, 3),
            _mythic(alice, 4)
        ];
        for (uint256 i; i < ids.length; ++i) {
            (, uint256 cores) = swap.classOf(ids[i]);
            assertEq(swap.swapDownPayout(ids[i]), cores, "payout is the core count");
            assertLe(swap.swapDownPayout(ids[i]), swap.pointsOf(ids[i]), "payout never exceeds weight");
        }
    }

    function test_EveryRouteChargesTheSameUnitPerCore() public {
        // The launch schedule has one rule: a talisman is charged its core
        // count in units, whichever route it takes. A swap and a swap down off
        // the same Prime therefore cost the same, and neither is priced off
        // weight - which would have charged this 4-core for eight.
        uint256 tokenIn = _reveal(alice, true, 4);
        uint256 swapPeer = _reveal(reserveWallet, true, 4);
        uint256 outA = _reveal(reserveWallet, true, 2);
        uint256 outB = _reveal(reserveWallet, false, 2);
        _listAllAndCool(_fees(swapPeer, outA, outB));

        assertEq(swap.quoteSwap(tokenIn, swapPeer), 4 * FEE_UNIT);
        assertEq(swap.quoteSwapDown(tokenIn, _ids(outA, outB)), 4 * FEE_UNIT);
        assertEq(swap.pointsOf(tokenIn), 8, "weight is 8; the fee follows cores, not weight");
    }

    /// @dev The launch fee is 5% of what a core sells for, matching the
    ///      collection's marketplace royalty, so trading through the reserve
    ///      costs about what trading around it does.
    function test_SwapFeeIsFivePercentOfFloor() public {
        for (uint8 i; i < 8; ++i) {
            assertEq(swap.config().swapFees[i] * 20, swap.classCores(i) * FLOOR_UNIT, "5% of the class's floor value");
        }
    }

    function test_SwapDownCannotRerollAMythic() public {
        // A Mythic is two Pure halves, so swapping one down and bonding the
        // halves back would be a reroll - and it would skip the swap surcharge.
        // Paying one point per core closes it: a Mythic 6-core returns 6 points
        // while its two 3-core halves weigh 8, so the halves cannot be bought
        // back out of the proceeds.
        uint256 tokenIn = _mythic(alice, 3);
        assertEq(swap.pointsOf(tokenIn), 8);
        assertEq(swap.swapDownPayout(tokenIn), 6);

        uint256 outA = _reveal(reserveWallet, true, 3); // Lithic 3-core, 4
        uint256 outB = _reveal(reserveWallet, false, 3); // Lumic 3-core, 4
        _listAllAndCool(_ids(outA, outB));

        // The two halves needed for a bond weigh 8 against a 6-point budget.
        vm.expectRevert(abi.encodeWithSelector(TalismanSwapV1.WrongPoints.selector, 6, 8));
        vm.prank(alice);
        swap.swapDown{value: 6 * FEE_UNIT}(tokenIn, _ids(outA, outB));
    }

    function test_SwapDownOutputsMayBeAnyEssence() public {
        // Mythic 6-core: 6 cores -> 6 points, as a Lithic 3-core (4) and a
        // Mythic 2-core (2).
        uint256 tokenIn = _mythic(alice, 3);
        uint256 outA = _reveal(reserveWallet, true, 3);
        uint256 outB = _mythic(reserveWallet, 1);
        _listAllAndCool(_ids(outA, outB));

        vm.prank(alice);
        swap.swapDown{value: 6 * FEE_UNIT}(tokenIn, _ids(outA, outB));
        assertEq(nft.ownerOf(tokenIn), reserveWallet);
        assertEq(nft.ownerOf(outA), alice);
        assertEq(nft.ownerOf(outB), alice);
    }

    function test_SwapDownRevertsOnBottomTier() public {
        // Nothing sits below a 1-core.
        uint256 tokenIn = _reveal(alice, true, 1);
        uint256 outA = _reveal(reserveWallet, true, 1);
        _listAndCool(outA);

        vm.expectRevert(abi.encodeWithSelector(TalismanSwapV1.NoLighterClass.selector, tokenIn));
        vm.prank(alice);
        swap.swapDown{value: FEE_UNIT}(tokenIn, _fees(outA));
    }

    function test_SwapDownRevertsOnOutputNotLighter() public {
        // Same-weight exchange is a swap, not a swap down.
        uint256 tokenIn = _reveal(alice, true, 2);
        uint256 outA = _reveal(reserveWallet, true, 2);
        _listAndCool(outA);

        vm.expectRevert(abi.encodeWithSelector(TalismanSwapV1.OutputNotLighter.selector, outA));
        vm.prank(alice);
        swap.swapDown{value: 2 * FEE_UNIT}(tokenIn, _fees(outA));
    }

    function test_SwapDownRevertsOnWrongPoints() public {
        // Pure 4-core owes 4 points back; one Pure 2-core is 2.
        uint256 tokenIn = _reveal(alice, true, 4);
        uint256 outA = _reveal(reserveWallet, true, 2);
        _listAndCool(outA);

        vm.expectRevert(abi.encodeWithSelector(TalismanSwapV1.WrongPoints.selector, 4, 2));
        vm.prank(alice);
        swap.swapDown{value: 4 * FEE_UNIT}(tokenIn, _fees(outA));
    }

    function test_SwapDownRevertsOnDuplicateOutput() public {
        uint256 tokenIn = _reveal(alice, true, 4);
        uint256 outA = _reveal(reserveWallet, true, 2);
        _listAndCool(outA);

        bytes memory expected = abi.encodeWithSelector(TalismanSwapV1.DuplicateToken.selector, outA);
        vm.expectRevert(expected);
        swap.quoteSwapDown(tokenIn, _ids(outA, outA));
        vm.expectRevert(expected);
        vm.prank(alice);
        swap.swapDown{value: 4 * FEE_UNIT}(tokenIn, _ids(outA, outA));
    }

    function test_SwapDownRevertsOnEmptyOutputs() public {
        uint256 tokenIn = _reveal(alice, true, 4);
        uint256[] memory outs = new uint256[](0);
        vm.expectRevert(TalismanSwapV1.TooFewOutputTokens.selector);
        vm.prank(alice);
        swap.swapDown{value: 4 * FEE_UNIT}(tokenIn, outs);
    }

    function test_SwapDownRevertsOnUnlistedOutput() public {
        uint256 tokenIn = _reveal(alice, true, 4);
        uint256 outA = _reveal(reserveWallet, true, 2);
        uint256 outB = _reveal(reserveWallet, false, 2);
        _listAndCool(outA); // outB never listed

        vm.expectRevert(abi.encodeWithSelector(TalismanSwapV1.NotListed.selector, outB));
        vm.prank(alice);
        swap.swapDown{value: 4 * FEE_UNIT}(tokenIn, _ids(outA, outB));
    }

    function test_SwapDownRevertsOnWrongFee() public {
        uint256 tokenIn = _reveal(alice, true, 4);
        uint256 outA = _reveal(reserveWallet, true, 2);
        uint256 outB = _reveal(reserveWallet, false, 2);
        _listAllAndCool(_ids(outA, outB));

        vm.expectRevert(abi.encodeWithSelector(TalismanSwapV1.WrongFee.selector, 4 * FEE_UNIT, FEE_UNIT));
        vm.prank(alice);
        swap.swapDown{value: FEE_UNIT}(tokenIn, _ids(outA, outB));
    }

    function test_SwapDownIsIndependentlyToggleable() public {
        uint256 tokenIn = _reveal(alice, true, 4);
        uint256 outA = _reveal(reserveWallet, true, 2);
        uint256 outB = _reveal(reserveWallet, false, 2);
        _listAllAndCool(_ids(outA, outB));

        swap.setRoutes(ALL_CLASSES, ALL_CLASSES, NO_CLASSES);
        vm.expectRevert(TalismanSwapV1.RouteDisabled.selector);
        vm.prank(alice);
        swap.swapDown{value: 4 * FEE_UNIT}(tokenIn, _ids(outA, outB));

        // closing swapDown leaves the other two open
        swap.setRoutes(ALL_CLASSES, ALL_CLASSES, ALL_CLASSES);
        vm.prank(alice);
        swap.swapDown{value: 4 * FEE_UNIT}(tokenIn, _ids(outA, outB));
        assertEq(nft.ownerOf(tokenIn), reserveWallet);
    }

    // --- shelf: list + cooldown ---

    function test_ListIsPermissionlessAndNeverResets() public {
        uint256 id = _reveal(reserveWallet, true, 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        vm.prank(bob);
        swap.list(ids);
        uint256 from = swap.selectableAt(id);

        vm.warp(block.timestamp + 10 minutes);
        vm.prank(alice);
        swap.list(ids); // already listed: skipped, clock not reset
        assertEq(swap.selectableAt(id), from);
    }

    function test_RelistRestartsTheClockAfterPlainReentry() public {
        // A talisman that leaves the reserve by plain transfer keeps its stamp,
        // and list() skips it, so it would come back already past its cooldown.
        uint256 id = _reveal(reserveWallet, true, 1);
        _listAndCool(id);
        uint256 originally = swap.selectableAt(id);

        vm.warp(block.timestamp + 30 days);
        vm.prank(reserveWallet);
        nft.transferFrom(reserveWallet, bob, id);
        vm.prank(bob);
        nft.transferFrom(bob, reserveWallet, id);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        swap.list(ids);
        assertEq(swap.selectableAt(id), originally, "list() cannot refresh a stamp");

        swap.relist(ids);
        assertEq(swap.selectableAt(id), block.timestamp + 1 hours);
    }

    function test_RelistRestartsTheClockAfterBondCleaveRoundTrip() public {
        // Bond burns both halves but their stamps survive, and because ids
        // resolve from cores, cleave re-mints those exact ids - pre-listed.
        uint256 lith = _reveal(reserveWallet, true, 1);
        uint256 lum = _reveal(reserveWallet, false, 1);
        uint256[] memory ids = _ids(lith, lum);
        swap.list(ids);
        uint256 stamped = swap.selectableAt(lith);

        vm.warp(block.timestamp + 30 days);
        vm.prank(reserveWallet);
        uint256 mythic = nft.bond(lith, lum);
        vm.prank(reserveWallet);
        nft.cleave(mythic);

        assertEq(swap.selectableAt(lith), stamped, "stale stamp survives burn and re-mint");
        swap.relist(ids);
        assertEq(swap.selectableAt(lith), block.timestamp + 1 hours);
        assertEq(swap.selectableAt(lum), block.timestamp + 1 hours);
    }

    function test_RelistIsOwnerOnlyAndRequiresReserveHeld() public {
        uint256 id = _reveal(reserveWallet, true, 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        vm.prank(alice);
        vm.expectRevert(TalismanSwapV1.NotOwner.selector);
        swap.relist(ids);

        uint256 mine = _reveal(alice, true, 1);
        ids[0] = mine;
        vm.expectRevert(abi.encodeWithSelector(TalismanSwapV1.NotInReserve.selector, mine));
        swap.relist(ids);
    }

    function test_ListRevertsWhenNotInReserve() public {
        uint256 id = _reveal(alice, true, 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.expectRevert(abi.encodeWithSelector(TalismanSwapV1.NotInReserve.selector, id));
        swap.list(ids);
    }

    function test_CooldownIsComputedLive() public {
        uint256 tokenIn = _reveal(alice, true, 1);
        uint256 tokenOut = _reveal(reserveWallet, true, 1);
        _listAndCool(tokenOut);

        // raising the cooldown re-locks already-listed stock
        swap.setShelfCooldown(2 hours);
        uint256 from = swap.selectableAt(tokenOut);
        vm.expectRevert(abi.encodeWithSelector(TalismanSwapV1.CooldownActive.selector, tokenOut, from));
        vm.prank(alice);
        swap.swap{value: FEE_UNIT}(tokenIn, tokenOut);

        vm.warp(from);
        vm.prank(alice);
        swap.swap{value: FEE_UNIT}(tokenIn, tokenOut);
        assertEq(nft.ownerOf(tokenOut), alice);
    }

    function test_SetShelfCooldownEnforcesBounds() public {
        vm.expectRevert(abi.encodeWithSelector(TalismanSwapV1.CooldownOutOfBounds.selector, uint64(30 seconds)));
        swap.setShelfCooldown(30 seconds);
        vm.expectRevert(abi.encodeWithSelector(TalismanSwapV1.CooldownOutOfBounds.selector, uint64(366 days)));
        swap.setShelfCooldown(366 days);
        swap.setShelfCooldown(1 minutes);
        swap.setShelfCooldown(365 days);
    }

    function test_DefaultCooldownIsOneHour() public view {
        assertEq(swap.config().shelfCooldown, 1 hours);
    }

    // --- views ---

    function test_InventoryOfClassFiltersByClass() public {
        uint256 lithic1 = _reveal(reserveWallet, true, 1);
        uint256 lithic1b = _reveal(reserveWallet, true, 1);
        _reveal(reserveWallet, false, 1);
        _reveal(reserveWallet, true, 2);

        uint256[] memory got = swap.inventoryOfClass(TalismanTransformationLib.Pole.Lithic, 1);
        assertEq(got.length, 2);
        assertEq(got[0], lithic1);
        assertEq(got[1], lithic1b);
        assertEq(swap.inventoryOfClass(TalismanTransformationLib.Pole.Lumic, 1).length, 1);
        assertEq(swap.inventoryOfClass(TalismanTransformationLib.Pole.Lithic, 2).length, 1);
        assertEq(swap.inventoryOfClass(TalismanTransformationLib.Pole.Mythic, 2).length, 0);
    }

    function test_ClassOf() public {
        uint256 lithic = _reveal(alice, true, 2);
        (TalismanTransformationLib.Pole essence, uint256 cores) = swap.classOf(lithic);
        assertEq(uint8(essence), uint8(TalismanTransformationLib.Pole.Lithic));
        assertEq(cores, 2);

        uint256 mythic = _mythic(alice, 1);
        (essence, cores) = swap.classOf(mythic);
        assertEq(uint8(essence), uint8(TalismanTransformationLib.Pole.Mythic));
        assertEq(cores, 2);

        (uint256 unrevealed,) = nft.mintWithCommitment(alice);
        vm.expectRevert(abi.encodeWithSelector(NotRevealed.selector, unrevealed));
        swap.classOf(unrevealed);
    }

    function test_PointsOf() public {
        // Pure: 2^(c-1). Mythic: unbound 2^(c/2).
        assertEq(swap.pointsOf(_reveal(alice, true, 1)), 1);
        assertEq(swap.pointsOf(_reveal(alice, true, 2)), 2);
        assertEq(swap.pointsOf(_reveal(alice, true, 3)), 4);
        assertEq(swap.pointsOf(_reveal(alice, true, 4)), 8);
        assertEq(swap.pointsOf(_mythic(alice, 1)), 2);
        assertEq(swap.pointsOf(_mythic(alice, 2)), 4);
        assertEq(swap.pointsOf(_mythic(alice, 3)), 8);
        assertEq(swap.pointsOf(_mythic(alice, 4)), 16);

        (uint256 unrevealed,) = nft.mintWithCommitment(alice);
        vm.expectRevert(abi.encodeWithSelector(NotRevealed.selector, unrevealed));
        swap.pointsOf(unrevealed);
    }

    function test_Config() public view {
        TalismanSwapV1.Config memory c = swap.config();
        assertEq(c.reserve, reserveWallet);
        assertEq(c.shelfCooldown, 1 hours);
        assertEq(c.swapMask, ALL_CLASSES);
        assertEq(c.swapUpMask, ALL_CLASSES);
        assertEq(c.swapDownMask, ALL_CLASSES);
        assertFalse(c.swapDownPremiumEnabled, "setUp takes the conservative schedule");
        for (uint8 i; i < 8; ++i) {
            assertEq(c.swapFees[i], _defaultSwapFees()[i], "swap fee");
            assertEq(c.swapUpMargins[i], _defaultMargins()[i], "margin");
            assertEq(c.swapUpFeeFloors[i], _defaultFloors()[i], "floor");
            assertEq(c.swapUpFees[i], 0, "swapUp eth defaults to zero");
            assertEq(c.swapDownPayouts[i], _defaultPayouts()[i], "payout");
            assertEq(c.swapDownFees[i], _defaultSwapDownFees()[i], "swapDown fee");
        }
    }

    function test_SetSwapFeesRepricesPerClass() public {
        uint256 inPure = _reveal(alice, true, 4);
        uint256 outPure = _reveal(reserveWallet, true, 4);
        _listAndCool(outPure);
        assertEq(swap.quoteSwap(inPure, outPure), _swapEth(4, false));

        // Drop the top-tier surcharge by rewriting just that entry: the table
        // states the fee directly, so there is no formula to bend.
        uint64[8] memory fees = _defaultSwapFees();
        fees[3] = uint64(8 * FEE_UNIT);
        swap.setSwapFees(fees);
        assertEq(swap.quoteSwap(inPure, outPure), 8 * FEE_UNIT);

        // Every other class is untouched.
        uint256 inPure3 = _reveal(alice, true, 3);
        uint256 outPure3 = _reveal(reserveWallet, true, 3);
        _listAndCool(outPure3);
        assertEq(swap.quoteSwap(inPure3, outPure3), _swapEth(3, false));
    }

    // --- classes and per-class route gating ---

    function test_ClassIndexOfNumbersPureThenMythic() public {
        assertEq(swap.classIndexOf(_reveal(alice, true, 1)), 0);
        assertEq(swap.classIndexOf(_reveal(alice, true, 2)), 1);
        assertEq(swap.classIndexOf(_reveal(alice, false, 3)), 2);
        assertEq(swap.classIndexOf(_reveal(alice, true, 4)), 3);
        assertEq(swap.classIndexOf(_mythic(alice, 1)), 4);
        assertEq(swap.classIndexOf(_mythic(alice, 2)), 5);
        assertEq(swap.classIndexOf(_mythic(alice, 3)), 6);
        assertEq(swap.classIndexOf(_mythic(alice, 4)), 7);
    }

    function test_ClassCoresAndWeightCoverEveryClass() public view {
        uint256[8] memory cores = [uint256(1), 2, 3, 4, 2, 4, 6, 8];
        uint256[8] memory weights = [uint256(1), 2, 4, 8, 2, 4, 8, 16];
        for (uint8 i; i < 8; ++i) {
            assertEq(swap.classCores(i), cores[i], "cores");
            assertEq(swap.classWeight(i), weights[i], "weight");
            // Weight is never below the core count, which is what makes a payout
            // of p points buy at most p cores.
            assertGe(swap.classWeight(i), swap.classCores(i));
        }
    }

    function test_RouteMaskGatesEachClassIndependently() public {
        // Open swap for 2-core Pures only. A 2-core trades; a 1-core does not.
        swap.setRoutes(PURE2, NO_CLASSES, NO_CLASSES);

        uint256 in1 = _reveal(alice, true, 1);
        uint256 out1 = _reveal(reserveWallet, true, 1);
        uint256 in2 = _reveal(alice, true, 2);
        uint256 out2 = _reveal(reserveWallet, true, 2);
        _listAndCool(out1);
        _listAndCool(out2);

        vm.prank(alice);
        vm.expectRevert(TalismanSwapV1.RouteDisabled.selector);
        swap.swap{value: FEE_UNIT}(in1, out1);

        vm.prank(alice);
        swap.swap{value: 2 * FEE_UNIT}(in2, out2);
        assertEq(nft.ownerOf(out2), alice);
    }

    function test_RoutesForReportsThePerClassBits() public {
        // The worked launch example: swap on every class, swapUp only off the
        // bottom tier, swapDown only from the top two tiers - one transaction.
        swap.setRoutes(ALL_CLASSES, PURE1 | MYTHIC2, PURE3 | PURE4 | MYTHIC6 | MYTHIC8);

        uint256 pure1 = _reveal(alice, true, 1);
        uint256 pure2 = _reveal(alice, true, 2);
        uint256 pure3 = _reveal(alice, true, 3);
        uint256 pure4 = _reveal(alice, true, 4);

        (bool s1, bool u1, bool d1) = swap.routesFor(pure1);
        assertTrue(s1);
        assertTrue(u1, "1-core may climb");
        assertFalse(d1, "nothing below a 1-core");

        (bool s2, bool u2, bool d2) = swap.routesFor(pure2);
        assertTrue(s2);
        assertFalse(u2, "2-core may not climb");
        assertFalse(d2);

        (bool s3, bool u3, bool d3) = swap.routesFor(pure3);
        assertTrue(s3);
        assertFalse(u3);
        assertTrue(d3, "3-core may descend");

        (bool s4, bool u4, bool d4) = swap.routesFor(pure4);
        assertTrue(s4);
        assertFalse(u4);
        assertTrue(d4);
    }

    function test_WorkedRouteExampleIsOneTransaction() public {
        swap.setRoutes(0xFF, 0x11, 0xCC);
        TalismanSwapV1.Config memory c = swap.config();
        assertEq(c.swapMask, 0xFF);
        assertEq(c.swapUpMask, PURE1 | MYTHIC2);
        assertEq(c.swapDownMask, PURE3 | PURE4 | MYTHIC6 | MYTHIC8);
    }

    // --- swapDown payout cap and the premium switch ---

    function test_SwapDownPayoutCapIsWeightAndOneExtraCorePerHalf() public view {
        uint256[8] memory expected = [uint256(1), 2, 4, 5, 2, 4, 8, 10];
        for (uint8 i; i < 8; ++i) {
            assertEq(swap.swapDownPayoutCap(i), expected[i], "cap");
            // The cap is never above the weight (no chain of swap downs can beat
            // a direct one) and never more than one extra core per half.
            assertLe(swap.swapDownPayoutCap(i), swap.classWeight(i), "cap within weight");
            assertLe(
                swap.swapDownPayoutCap(i),
                swap.classCores(i) + (i < 4 ? 1 : 2) * swap.MAX_CORE_PREMIUM_PER_HALF(),
                "cap within core premium"
            );
        }
    }

    function test_SetSwapDownTermsRejectsPayoutAboveCap() public {
        uint8[8] memory payouts = _defaultPayouts();
        // Pure4 caps at 5 even though it weighs 8: one extra core, no more.
        payouts[3] = 6;
        vm.expectRevert(abi.encodeWithSelector(TalismanSwapV1.PayoutAboveCap.selector, uint8(3), uint8(6), uint256(5)));
        swap.setSwapDownTerms(payouts, _defaultSwapDownFees());

        // Mythic8 caps at 10 even though it weighs 16.
        payouts = _defaultPayouts();
        payouts[7] = 12;
        vm.expectRevert(
            abi.encodeWithSelector(TalismanSwapV1.PayoutAboveCap.selector, uint8(7), uint8(12), uint256(10))
        );
        swap.setSwapDownTerms(payouts, _defaultSwapDownFees());

        // At the cap it is accepted.
        swap.setSwapDownTerms(_defaultPayouts(), _defaultSwapDownFees());
    }

    function test_SetSwapDownTermsChecksCapEvenWhileThePremiumIsOff() public {
        // The premium is off in setUp. A table that would only bite once it is
        // switched back on is still rejected now, so flipping the switch can
        // never turn a stored table into a draining one.
        assertFalse(swap.config().swapDownPremiumEnabled);
        uint8[8] memory payouts = _defaultPayouts();
        payouts[3] = 8;
        vm.expectRevert(abi.encodeWithSelector(TalismanSwapV1.PayoutAboveCap.selector, uint8(3), uint8(8), uint256(5)));
        swap.setSwapDownTerms(payouts, _defaultSwapDownFees());
    }

    function test_PremiumDefaultsOnAndTheSwitchClampsToCoreCount() public {
        TalismanSwapV1 fresh = new TalismanSwapV1(nft);
        assertFalse(fresh.config().swapDownPremiumEnabled, "ships with the premium off");

        uint256 pure3 = _reveal(alice, true, 3);
        uint256 pure4 = _reveal(alice, true, 4);
        uint256 myth8 = _mythic(alice, 4);

        // setUp switched it off: every class pays back its core count.
        assertEq(swap.swapDownPayout(pure3), 3);
        assertEq(swap.swapDownPayout(pure4), 4);
        assertEq(swap.swapDownPayout(myth8), 8);

        // One call, and the stored table comes back untouched.
        swap.setSwapDownPremiumEnabled(true);
        assertEq(swap.swapDownPayout(pure3), 4);
        assertEq(swap.swapDownPayout(pure4), 5);
        assertEq(swap.swapDownPayout(myth8), 10);

        swap.setSwapDownPremiumEnabled(false);
        assertEq(swap.swapDownPayout(pure4), 4, "and off again without re-sending the table");
    }

    function test_PremiumPaysMoreCoresThanACutWould() public {
        swap.setSwapDownPremiumEnabled(true);

        uint256 tokenIn = _reveal(alice, true, 4);
        uint256[] memory outs = new uint256[](5);
        for (uint256 i; i < 5; ++i) {
            outs[i] = _reveal(reserveWallet, true, 1);
        }
        _listAllAndCool(outs);

        // A cut would split the 4-core into tokens holding four cores in total.
        // The premium pays five 1-cores: one core more than went in.
        assertEq(swap.swapDownPayout(tokenIn), 5);
        vm.prank(alice);
        swap.swapDown{value: 4 * FEE_UNIT}(tokenIn, outs);

        uint256 coresOut;
        for (uint256 i; i < 5; ++i) {
            assertEq(nft.ownerOf(outs[i]), alice);
            coresOut += nft.coreCount(outs[i]);
        }
        assertEq(coresOut, 5, "five cores back for four in");
        assertEq(nft.ownerOf(tokenIn), reserveWallet);

        // The launch fee table prices the payout the premium switch SHIPS with
        // - the core count - so with the premium on it does not cover the extra
        // core, which is worth far more than the whole fee. Switching the
        // premium on means re-pricing this class first.
        assertLt(4 * FEE_UNIT, FLOOR_UNIT, "the shipped fee does not pay for a free core");
    }

    function test_PremiumIsCoveredOnceTheClassIsRepriced() public {
        // What the fee has to become: the per-core charge plus the market value
        // of every extra core the table hands back.
        swap.setSwapDownPremiumEnabled(true);
        uint64[8] memory fees;
        for (uint8 i; i < 8; ++i) {
            uint256 premiumCores = _defaultPayouts()[i] - swap.classCores(i);
            fees[i] = uint64(swap.classCores(i) * FEE_UNIT + premiumCores * FLOOR_UNIT);
        }
        swap.setSwapDownTerms(_defaultPayouts(), fees);

        uint256 tokenIn = _reveal(alice, true, 4);
        uint256[] memory outs = new uint256[](5);
        for (uint256 i; i < 5; ++i) {
            outs[i] = _reveal(reserveWallet, true, 1);
        }
        _listAllAndCool(outs);

        uint256 fee = swap.quoteSwapDown(tokenIn, outs);
        assertEq(fee, 4 * FEE_UNIT + FLOOR_UNIT, "one core's worth on top of the per-core fee");
        vm.prank(alice);
        swap.swapDown{value: fee}(tokenIn, outs);
        assertEq(nft.ownerOf(tokenIn), reserveWallet);
    }

    function test_PremiumNeverPaysMoreThanTheClassWeighs() public view {
        // Law 1, machine-checked across every class at the maximum table the
        // setter will accept: a payout can never exceed what the input weighs,
        // so no chain of swap downs can ever beat one direct swap down.
        for (uint8 i; i < 8; ++i) {
            assertLe(swap.swapDownPayoutCap(i), swap.classWeight(i));
        }
    }

    function test_ChainedSwapDownNeverBeatsADirectOne() public {
        swap.setSwapDownPremiumEnabled(true);

        // Direct: a 4-core pays 5 points. Chained: take a 3-core (4) plus a
        // 1-core (1), then swap the 3-core down for its 4 points. The chain ends
        // on the same 5 points and the same 5 cores, having paid a second fee.
        uint256 direct = swap.swapDownPayoutCap(3);
        uint256 viaThree = swap.swapDownPayoutCap(3) - swap.classWeight(2) + swap.swapDownPayoutCap(2);
        assertEq(direct, 5);
        assertEq(viaThree, 5, "the chain cannot get ahead");

        // And the same holds for every class against every lighter class.
        for (uint8 i; i < 8; ++i) {
            for (uint8 j; j < 8; ++j) {
                if (swap.classWeight(j) >= swap.classWeight(i)) {
                    continue;
                }
                if (swap.swapDownPayoutCap(i) < swap.classWeight(j)) {
                    continue;
                }
                uint256 chained = swap.swapDownPayoutCap(i) - swap.classWeight(j) + swap.swapDownPayoutCap(j);
                assertLe(chained, swap.swapDownPayoutCap(i), "chain gains nothing");
            }
        }
    }

    function test_PremiumGainIsBoundedAtOneCorePerHalf() public {
        swap.setSwapDownPremiumEnabled(true);
        TalismanSwapV1.Config memory c = swap.config();
        for (uint8 i; i < 8; ++i) {
            uint256 gain = c.swapDownPayouts[i] > swap.classCores(i) ? c.swapDownPayouts[i] - swap.classCores(i) : 0;
            assertLe(gain, (i < 4 ? 1 : 2) * swap.MAX_CORE_PREMIUM_PER_HALF(), "premium is bounded per half");
        }
    }

    function test_CutMergeRoundTripConservesCoresAndRebuildsTheWeight() public {
        // Why the payout is capped in cores and not just in points. Genesis
        // tokens are homogeneous, so a 4-core cuts into four same-kind 1-cores
        // (8 points become 4) and merges straight back (4 points become 8). The
        // forge moves points freely in both directions but never creates a core,
        // which is why a payout above the core count is the one thing this
        // contract could hand it that it cannot make for itself.
        nft.setTransformationSettings(true, true);
        uint256 pure4 = _reveal(alice, true, 4);
        assertEq(swap.pointsOf(pure4), 8);

        vm.startPrank(alice);
        (uint256 a, uint256 rest3) = nft.cut(pure4, 1);
        (uint256 b, uint256 rest2) = nft.cut(rest3, 1);
        (uint256 cc, uint256 d) = nft.cut(rest2, 1);
        vm.stopPrank();

        uint256 pointsAsDust = swap.pointsOf(a) + swap.pointsOf(b) + swap.pointsOf(cc) + swap.pointsOf(d);
        uint256 coresAsDust = nft.coreCount(a) + nft.coreCount(b) + nft.coreCount(cc) + nft.coreCount(d);
        assertEq(coresAsDust, 4, "cores are conserved");
        assertEq(pointsAsDust, 4, "points are not - cutting halves them twice over");

        vm.startPrank(alice);
        uint256 two = nft.merge(a, b);
        uint256 three = nft.merge(two, cc);
        uint256 four = nft.merge(three, d);
        vm.stopPrank();

        assertEq(nft.coreCount(four), 4, "still four cores");
        assertEq(swap.pointsOf(four), 8, "and the weight is back");
    }

    // --- swapUp terms ---

    function test_SetSwapUpTermsRejectsAFloorAboveTheBudget() public {
        uint8[8] memory floors = _defaultFloors();
        // Pure1 climbing to Pure2 charges 2 + margin 1 = 3, of which the 1-core
        // handed in covers 1, leaving a 2-point budget. A floor of 3 could never
        // be met.
        floors[0] = 3;
        vm.expectRevert(
            abi.encodeWithSelector(TalismanSwapV1.FeeFloorAboveBudget.selector, uint8(0), uint8(3), uint256(2))
        );
        swap.setSwapUpTerms(_defaultMargins(), floors, _zeroEthFees());

        floors[0] = 2;
        swap.setSwapUpTerms(_defaultMargins(), floors, _zeroEthFees());
    }

    function test_SwapUpChargesItsEthLegExactly() public {
        uint64[8] memory ethFees = _zeroEthFees();
        ethFees[0] = 0.001 ether;
        swap.setSwapUpTerms(_defaultMargins(), _defaultFloors(), ethFees);

        uint256 tokenIn = _reveal(alice, true, 1);
        uint256 feeA = _reveal(alice, true, 1);
        uint256 feeB = _reveal(alice, false, 1);
        uint256 tokenOut = _reveal(reserveWallet, true, 2);
        _listAndCool(tokenOut);

        (uint256 price, uint256 floor, uint256 ethFee) = swap.swapUpTermsOf(tokenIn);
        assertEq(price, 3);
        assertEq(floor, 0);
        assertEq(ethFee, 0.001 ether);

        (uint256 quotedPoints, uint256 quotedEth) = swap.quoteSwapUp(tokenIn, _fees(feeA, feeB), tokenOut);
        assertEq(quotedPoints, 3);
        assertEq(quotedEth, 0.001 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TalismanSwapV1.WrongFee.selector, 0.001 ether, 0));
        swap.swapUp(tokenIn, _fees(feeA, feeB), tokenOut);

        vm.prank(alice);
        swap.swapUp{value: 0.001 ether}(tokenIn, _fees(feeA, feeB), tokenOut);
        assertEq(nft.ownerOf(tokenOut), alice);
        assertEq(address(swap).balance, 0.001 ether);
    }

    function test_SwapUpLadderCostsMoreThanASingleHopWould() public view {
        // Climbing tier by tier burns each tier's margin, so carrying a 1-core to
        // a 4-core burns 1 + 2 + 4 = 7 points against the 4 a direct hop would.
        TalismanSwapV1.Config memory c = swap.config();
        uint256 ladder = uint256(c.swapUpMargins[0]) + c.swapUpMargins[1] + c.swapUpMargins[2];
        assertEq(ladder, 7);
        assertGt(ladder, c.swapUpMargins[2], "the ladder is the costlier path, by design");
    }

    function test_SwapUpTermsRevertAtTheTopTier() public {
        uint256 pure4 = _reveal(alice, true, 4);
        vm.expectRevert(abi.encodeWithSelector(TalismanSwapV1.MissingPriorTier.selector, uint256(0)));
        swap.swapUpTermsOf(pure4);
    }

    // --- ownership mirror ---

    function test_OwnerMirrorsTalismansOwner() public {
        assertEq(swap.owner(), address(this));

        nft.transferOwnership(bob);
        vm.prank(bob);
        nft.acceptOwnership();

        assertEq(swap.owner(), bob);
        vm.expectRevert(TalismanSwapV1.NotOwner.selector);
        swap.setSwapFees(_defaultSwapFees());
        vm.prank(bob);
        swap.setSwapFees(_defaultSwapFees());
    }

    // --- eject ---

    function test_EjectKillsEverythingExceptOwnerAndWithdrawEth() public {
        uint256 tokenIn = _reveal(alice, true, 1);
        uint256 tokenOut = _reveal(reserveWallet, true, 1);
        _listAndCool(tokenOut);
        vm.prank(alice);
        swap.swap{value: FEE_UNIT}(tokenIn, tokenOut);

        swap.eject();
        assertEq(swap.owner(), address(0));

        bytes memory notAlive = abi.encodeWithSelector(TalismanSwapV1.NotAlive.selector);
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenOut;

        vm.expectRevert(notAlive);
        swap.swap{value: 0}(1, 2);
        vm.expectRevert(notAlive);
        swap.swapUp(1, ids, 2);
        vm.expectRevert(notAlive);
        swap.swapDown{value: 0}(1, ids);
        vm.expectRevert(notAlive);
        swap.list(ids);
        vm.expectRevert(notAlive);
        swap.relist(ids);
        vm.expectRevert(notAlive);
        swap.quoteSwap(1, 2);
        vm.expectRevert(notAlive);
        swap.quoteSwapUp(1, ids, 2);
        vm.expectRevert(notAlive);
        swap.quoteSwapDown(1, ids);
        vm.expectRevert(notAlive);
        swap.pointsOf(1);
        vm.expectRevert(notAlive);
        _upPrice(1);
        vm.expectRevert(notAlive);
        _upFloor(1);
        vm.expectRevert(notAlive);
        swap.swapDownPayout(1);
        vm.expectRevert(notAlive);
        swap.selectableAt(1);
        vm.expectRevert(notAlive);
        swap.classOf(1);
        vm.expectRevert(notAlive);
        swap.classIndexOf(1);
        vm.expectRevert(notAlive);
        swap.routesFor(1);
        vm.expectRevert(notAlive);
        swap.inventoryOfClass(TalismanTransformationLib.Pole.Lithic, 1);
        vm.expectRevert(notAlive);
        swap.config();
        vm.expectRevert(notAlive);
        swap.setReserve(address(1));
        vm.expectRevert(notAlive);
        swap.setRoutes(ALL_CLASSES, ALL_CLASSES, ALL_CLASSES);
        vm.expectRevert(notAlive);
        swap.setSwapFees(_defaultSwapFees());
        vm.expectRevert(notAlive);
        swap.setSwapUpTerms(_defaultMargins(), _defaultFloors(), _zeroEthFees());
        vm.expectRevert(notAlive);
        swap.setSwapDownTerms(_defaultPayouts(), _defaultSwapDownFees());
        vm.expectRevert(notAlive);
        swap.setSwapDownPremiumEnabled(true);
        vm.expectRevert(notAlive);
        swap.setShelfCooldown(1 hours);
        vm.expectRevert(notAlive);
        swap.eject();
        vm.expectRevert(notAlive);
        swap.rescueERC20(IERC20(address(0)));
        vm.expectRevert(notAlive);
        swap.rescueERC721(IERC721(address(0)), 1);
        vm.expectRevert(notAlive);
        swap.rescueERC1155(IERC1155(address(0)), 1, 1);

        // withdrawEth survives: anyone can push the balance to the collection owner
        uint256 before = address(this).balance;
        vm.prank(bob);
        swap.withdrawEth();
        assertEq(address(this).balance, before + FEE_UNIT);
        assertEq(address(swap).balance, 0);
    }

    // --- withdrawEth ---

    function test_WithdrawEthIsPermissionlessAndPaysCollectionOwner() public {
        uint256 tokenIn = _reveal(alice, true, 1);
        uint256 tokenOut = _reveal(reserveWallet, true, 1);
        _listAndCool(tokenOut);
        vm.prank(alice);
        swap.swap{value: FEE_UNIT}(tokenIn, tokenOut);

        uint256 before = address(this).balance;
        vm.prank(bob);
        swap.withdrawEth();
        assertEq(address(this).balance, before + FEE_UNIT);
    }

    function test_WithdrawEthRevertsOnZeroBalance() public {
        vm.expectRevert(TalismanSwapV1.NothingToWithdraw.selector);
        swap.withdrawEth();
    }

    function test_WithdrawEthRevertsWhenOwnershipRenounced() public {
        vm.deal(address(swap), 1 ether);
        nft.renounceOwnership();
        vm.expectRevert(TalismanSwapV1.OwnerIsZero.selector);
        swap.withdrawEth();
    }

    // --- rescues ---

    function test_RescueERC20() public {
        MockERC20 token = new MockERC20();
        token.mint(address(swap), 123);
        swap.rescueERC20(IERC20(address(token)));
        assertEq(token.balanceOf(address(this)), 123);
        assertEq(token.balanceOf(address(swap)), 0);
    }

    function test_RescueERC721() public {
        uint256 stray = _reveal(alice, true, 1);
        vm.prank(alice);
        nft.transferFrom(alice, address(swap), stray);

        swap.rescueERC721(IERC721(address(nft)), stray);
        assertEq(nft.ownerOf(stray), address(this));
    }

    function test_RescueERC1155() public {
        MockERC1155 token = new MockERC1155();
        token.mint(address(swap), 7, 5);
        swap.rescueERC1155(IERC1155(address(token)), 7, 5);
        assertEq(token.balanceOf(address(this), 7), 5);
    }

    function test_RescuesAreOwnerOnly() public {
        vm.prank(alice);
        vm.expectRevert(TalismanSwapV1.NotOwner.selector);
        swap.rescueERC20(IERC20(address(0)));
    }

    // --- construction ---

    function test_ConstructorRejectsZeroAddress() public {
        vm.expectRevert(TalismanSwapV1.ZeroAddress.selector);
        new TalismanSwapV1(Talismans(address(0)));
    }

    function test_AdminRevertsNotAliveForEveryoneAfterEject() public {
        swap.eject();
        // after eject even a non-owner gets NotAlive, not NotOwner (I-07)
        vm.prank(alice);
        vm.expectRevert(TalismanSwapV1.NotAlive.selector);
        swap.setSwapFees(_defaultSwapFees());
    }
}
