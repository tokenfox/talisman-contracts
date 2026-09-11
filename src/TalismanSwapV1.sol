// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Talismans} from "./Talismans.sol";
import {TalismanMaterials} from "./TalismanMaterials.sol";
import {TalismanTransformationLib} from "./TalismanTransformationLib.sol";
import {NotRevealed} from "./TalismanErrors.sol";

/// @title TalismanSwapV1
/// @notice Swap talismans against a dedicated reserve wallet.
contract TalismanSwapV1 is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    error NotAlive();
    error NotOwner();
    error ZeroAddress();
    error RouteDisabled();
    error ReserveNotSet();
    error WrongFee(uint256 expected, uint256 provided);
    error NotInReserve(uint256 tokenId);
    error NotListed(uint256 tokenId);
    error CooldownActive(uint256 tokenId, uint256 selectableFrom);
    error ClassMismatch(uint256 tokenIn, uint256 tokenOut);
    error WrongPoints(uint256 required, uint256 provided);
    error MissingPriorTier(uint256 requiredCores);
    error TooFewFeeTokens();
    error TooFewOutputTokens();
    error DuplicateToken(uint256 tokenId);
    error FeeTokenBelowFloor(uint256 tokenId, uint256 floor);
    error NoLighterClass(uint256 tokenId);
    error OutputNotLighter(uint256 tokenId);
    error CooldownOutOfBounds(uint64 secs);
    error UnsupportedClass(uint256 coreCount);
    error PayoutAboveCap(uint8 classIndex, uint8 payout, uint256 cap);
    error FeeFloorAboveBudget(uint8 classIndex, uint8 feeFloor, uint256 budget);
    error OwnerIsZero();
    error NothingToWithdraw();
    error EthTransferFailed();

    event Swapped(address indexed user, uint256 indexed tokenIn, uint256 indexed tokenOut);
    event SwappedUp(address indexed user, uint256 indexed tokenIn, uint256[] feeTokens, uint256 indexed tokenOut);
    event SwappedDown(address indexed user, uint256 indexed tokenIn, uint256[] tokensOut);
    event ReserveSet(address reserve);
    event RoutesSet(uint8 swapMask, uint8 swapUpMask, uint8 swapDownMask);
    event SwapFeesSet(uint64[8] ethFees);
    event SwapUpTermsSet(uint8[8] margins, uint8[8] feeFloors, uint64[8] ethFees);
    event SwapDownTermsSet(uint8[8] payouts, uint64[8] ethFees);
    event SwapDownPremiumSet(bool enabled);
    event CooldownSet(uint64 secs);
    event EthWithdrawn(address indexed to, uint256 amount);
    event Ejected();

    /// @notice The number of swap classes: four Pure tiers then four Mythic
    ///         tiers, indexed 0 to 7 by {classIndexOf}.
    uint8 public constant CLASS_COUNT = 8;

    /// @dev The Prime tier's ordinal, matching {TalismanGenerator.FacetTier}:
    ///      Raw 0, Cut 1, Fine 2, Prime 3.
    uint256 private constant TOP_TIER = 3;

    /// @notice The most extra cores a single {swapDown} may hand back per half:
    ///         one for a Lithic or Lumic, two for a Mythic. Fixed at deployment
    ///         and not settable, so no configuration can widen it.
    /// @dev The reason {swapDownPayoutCap} is not simply the class weight. Cores
    ///      are what bond, cleave, cut and merge conserve, so a payout above the
    ///      input's core count is the one thing this contract can hand the forge
    ///      that the forge cannot make for itself. Bounding it per half keeps
    ///      that leak at a known, small, per-trade figure.
    uint256 public constant MAX_CORE_PREMIUM_PER_HALF = 1;

    uint64 public constant DEFAULT_SHELF_COOLDOWN = 1 hours;
    uint64 public constant MIN_SHELF_COOLDOWN = 1 minutes;
    uint64 public constant MAX_SHELF_COOLDOWN = 365 days;

    /// @notice The current configuration, as returned by {config}.
    /// @param reserve The wallet holding the reserve inventory.
    /// @param shelfCooldown Seconds between listing and selectability.
    /// @param swapDownPremiumEnabled Whether {swapDown} pays its full table
    ///        rather than the input's core count.
    /// @param swapMask One bit per class: whether {swap} takes it.
    /// @param swapUpMask One bit per class: whether {swapUp} climbs off it.
    /// @param swapDownMask One bit per class: whether {swapDown} takes it.
    /// @param swapFees Per class, the ETH {swap} charges.
    /// @param swapUpMargins Per class, the points {swapUp} charges on top of
    ///        what the talisman received weighs.
    /// @param swapUpFeeFloors Per class, the lightest talisman {swapUp} accepts
    ///        as a fee token.
    /// @param swapUpFees Per class, the ETH {swapUp} charges.
    /// @param swapDownPayouts Per class, the points {swapDown} pays back before
    ///        the premium switch is applied.
    /// @param swapDownFees Per class, the ETH {swapDown} charges.
    struct Config {
        address reserve;
        uint64 shelfCooldown;
        bool swapDownPremiumEnabled;
        uint8 swapMask;
        uint8 swapUpMask;
        uint8 swapDownMask;
        uint64[8] swapFees;
        uint8[8] swapUpMargins;
        uint8[8] swapUpFeeFloors;
        uint64[8] swapUpFees;
        uint8[8] swapDownPayouts;
        uint64[8] swapDownFees;
    }

    Talismans public immutable talismans;

    // Slot 0 holds the reserve, the cooldown and all three route masks together,
    // so opening or closing every route on every class is a single write.
    address private _reserve;
    uint64 private _shelfCooldown;
    uint8 private _swapMask;
    uint8 private _swapUpMask;
    uint8 private _swapDownMask;
    bool private _ejected;

    bool private _swapDownPremiumEnabled;
    uint8[CLASS_COUNT] private _swapUpMargins;
    uint8[CLASS_COUNT] private _swapUpFeeFloors;
    uint8[CLASS_COUNT] private _swapDownPayouts;
    uint64[CLASS_COUNT] private _swapFees;
    uint64[CLASS_COUNT] private _swapUpFees;
    uint64[CLASS_COUNT] private _swapDownFees;

    mapping(uint256 tokenId => uint64) private _listedAt;

    modifier whenAlive() {
        if (_ejected) {
            revert NotAlive();
        }
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != talismans.owner()) {
            revert NotOwner();
        }
        _;
    }

    constructor(Talismans talismans_) {
        if (address(talismans_) == address(0)) {
            revert ZeroAddress();
        }
        talismans = talismans_;

        // Every route starts closed; the owner opens classes once the reserve is
        // set and stocked. The tables below start at the launch schedule so the
        // contract is priced coherently from the first block it is opened.
        // One unit per core, so every class is charged the same share of what it
        // is worth. Cores, not weight, is what the market prices a talisman by.
        _swapFees = [
            uint64(0.00035 ether),
            0.0007 ether,
            0.00105 ether,
            0.0014 ether,
            0.0007 ether,
            0.0014 ether,
            0.0021 ether,
            0.0028 ether
        ];
        _swapUpMargins = [1, 2, 4, 0, 2, 4, 8, 0];
        _swapUpFeeFloors = [0, 1, 2, 0, 0, 1, 2, 0];
        _swapDownPayouts = [1, 2, 4, 5, 2, 4, 8, 10];
        // The same unit per core: every route charges the same share of what
        // the talisman handed in is worth. Index 0 is inert - a 1-core has
        // nothing below it. This schedule prices the payout the premium switch
        // ships with (the core count); paying a premium on top is extra value
        // leaving the reserve, and wants these raised to cover it.
        _swapDownFees = [
            0, uint64(0.0007 ether), 0.00105 ether, 0.0014 ether, 0.0007 ether, 0.0014 ether, 0.0021 ether, 0.0028 ether
        ];
        // Off, so every payout clamps to the input's core count and the fees
        // above are the whole cost of a swap down. Switching it on hands back
        // more cores than it takes in, which the fee table has to be raised to
        // cover first.
        _swapDownPremiumEnabled = false;
    }

    /// @notice The owner of the Talismans collection, or the zero address
    ///         once {eject} has been called.
    function owner() public view returns (address) {
        return _ejected ? address(0) : talismans.owner();
    }

    /// @notice Swap your talisman for a reserve talisman of the same pole and
    ///         core count, for an ETH fee. Call {quoteSwap} first for the
    ///         exact fee to send.
    /// @dev The fee is this class's entry in the swap fee table; `msg.value`
    ///      must match exactly. Requires ERC-721 approval for this contract on
    ///      `tokenIn`; `tokenOut` must be past its shelf cooldown
    ///      ({selectableAt}).
    /// @param tokenIn The caller's talisman, transferred to the reserve.
    /// @param tokenOut The reserve talisman transferred to the caller.
    function swap(uint256 tokenIn, uint256 tokenOut) external payable nonReentrant whenAlive {
        uint256 fee = _checkSwap(tokenIn, tokenOut);
        if (msg.value != fee) {
            revert WrongFee(fee, msg.value);
        }
        _takeIn(tokenIn);
        _giveOut(tokenOut);
        emit Swapped(msg.sender, tokenIn, tokenOut);
    }

    /// @notice Swap up one talisman into a reserve talisman one tier higher,
    ///         paying the remainder in fee tokens. Call {quoteSwapUp} first for
    ///         the total weight required and the exact ETH fee to send.
    /// @dev `tokenIn` must share the output's pole and be exactly one tier
    ///      below it (Lithic/Lumic: one fewer core; Mythic: two fewer cores).
    ///      `tokenIn` plus `feeTokens` must weigh exactly what the output weighs
    ///      ({pointsOf}) plus this class's margin. Each fee token must weigh at
    ///      least this class's fee floor. Every id must be distinct. Fee tokens
    ///      may be any pole. Requires ERC-721 approval for this contract on
    ///      every input; `tokenOut` must be past its shelf cooldown
    ///      ({selectableAt}).
    /// @param tokenIn The caller's talisman being upgraded, transferred to the
    ///        reserve.
    /// @param feeTokens Additional talismans that pay the point fee,
    ///        transferred to the reserve.
    /// @param tokenOut The reserve talisman transferred to the caller.
    function swapUp(uint256 tokenIn, uint256[] calldata feeTokens, uint256 tokenOut)
        external
        payable
        nonReentrant
        whenAlive
    {
        (, uint256 fee) = _checkSwapUp(tokenIn, feeTokens, tokenOut);
        if (msg.value != fee) {
            revert WrongFee(fee, msg.value);
        }
        _takeIn(tokenIn);
        uint256 n = feeTokens.length;
        for (uint256 i; i < n; ++i) {
            _takeIn(feeTokens[i]);
        }
        _giveOut(tokenOut);
        emit SwappedUp(msg.sender, tokenIn, feeTokens, tokenOut);
    }

    /// @notice Swap one talisman down into several smaller reserve talismans of
    ///         your choosing, for an ETH fee. Call {quoteSwapDown} first for the
    ///         exact fee to send.
    /// @dev Every id in `tokensOut` must be distinct, weigh strictly less than
    ///      `tokenIn`, and be past its shelf cooldown ({selectableAt}); they may
    ///      be any pole. Their weights must sum to {swapDownPayout}. The ETH
    ///      fee is this class's entry in the swap down fee table, and
    ///      `msg.value` must match exactly. A Pure 1-core has nothing below it.
    ///      Requires ERC-721 approval for this contract on `tokenIn`.
    /// @param tokenIn The caller's talisman, transferred to the reserve.
    /// @param tokensOut The reserve talismans transferred to the caller.
    function swapDown(uint256 tokenIn, uint256[] calldata tokensOut) external payable nonReentrant whenAlive {
        uint256 fee = _checkSwapDown(tokenIn, tokensOut);
        if (msg.value != fee) {
            revert WrongFee(fee, msg.value);
        }
        _takeIn(tokenIn);
        uint256 n = tokensOut.length;
        for (uint256 i; i < n; ++i) {
            _giveOut(tokensOut[i]);
        }
        emit SwappedDown(msg.sender, tokenIn, tokensOut);
    }

    /// @notice List reserve-held talismans, starting their shelf cooldown.
    ///         Callable by anyone; ids already listed are skipped.
    /// @dev A reserve talisman can be selected as an output only once listing
    ///      time plus cooldown has passed ({selectableAt}). Skipping listed ids
    ///      means the clock can never be reset here. An id keeps its stamp when
    ///      it leaves the reserve by plain transfer, and a burned id keeps it
    ///      through a transformation that later re-mints the same id, so a
    ///      talisman can re-enter the reserve already past its cooldown; use
    ///      {relist} to restart the clock in those cases.
    /// @param tokenIds The reserve-held talismans to list.
    function list(uint256[] calldata tokenIds) external whenAlive {
        address res = _reserve;
        if (res == address(0)) {
            revert ReserveNotSet();
        }
        uint256 n = tokenIds.length;
        for (uint256 i; i < n; ++i) {
            uint256 id = tokenIds[i];
            if (talismans.ownerOf(id) != res) {
                revert NotInReserve(id);
            }
            if (_listedAt[id] == 0) {
                _listedAt[id] = uint64(block.timestamp);
            }
        }
    }

    /// @notice Restart the shelf cooldown on reserve-held talismans, whether or
    ///         not they are already listed. Owner only.
    /// @dev Stamps with the current time, which can only push {selectableAt}
    ///      later. This is the counterpart to {list} for a talisman that
    ///      re-entered the reserve carrying an old stamp.
    /// @param tokenIds The reserve-held talismans to re-stamp.
    function relist(uint256[] calldata tokenIds) external whenAlive onlyOwner {
        address res = _reserve;
        if (res == address(0)) {
            revert ReserveNotSet();
        }
        uint256 n = tokenIds.length;
        for (uint256 i; i < n; ++i) {
            uint256 id = tokenIds[i];
            if (talismans.ownerOf(id) != res) {
                revert NotInReserve(id);
            }
            _listedAt[id] = uint64(block.timestamp);
        }
    }

    /// @notice Quote a {swap}: returns the exact ETH fee to send as
    ///         `msg.value`, or reverts with the same error the swap would.
    function quoteSwap(uint256 tokenIn, uint256 tokenOut) external view whenAlive returns (uint256 ethFee) {
        return _checkSwap(tokenIn, tokenOut);
    }

    /// @notice Quote a {swapUp}: returns the total weight the selection has to
    ///         add up to and the exact ETH fee to send as `msg.value`, or
    ///         reverts with the same error the swap up would.
    function quoteSwapUp(uint256 tokenIn, uint256[] calldata feeTokens, uint256 tokenOut)
        external
        view
        whenAlive
        returns (uint256 requiredPoints, uint256 ethFee)
    {
        return _checkSwapUp(tokenIn, feeTokens, tokenOut);
    }

    /// @notice Quote a {swapDown}: returns the exact ETH fee to send as
    ///         `msg.value`, or reverts with the same error the swap down would.
    function quoteSwapDown(uint256 tokenIn, uint256[] calldata tokensOut)
        external
        view
        whenAlive
        returns (uint256 ethFee)
    {
        return _checkSwapDown(tokenIn, tokensOut);
    }

    /// @notice The exchange weight of talisman `tokenId`. Every route prices a
    ///         trade by weight, and a Mythic weighs what its two Pure halves do.
    /// @dev Lithic/Lumic: `2^(coreCount - 1)`. Mythic: unbound halves,
    ///      `2^(coreCount / 2)`.
    function pointsOf(uint256 tokenId) external view whenAlive returns (uint256) {
        return _classWeight(classIndexOf(tokenId));
    }

    /// @notice The swap class of a talisman: 0 to 3 for a Lithic or Lumic of one
    ///         to four cores, 4 to 7 for a Mythic of two to eight. Every price
    ///         this contract charges is looked up by this index.
    /// @dev A Mythic is priced as its two Pure halves throughout, so it shares a
    ///      tier with the Pure talisman of half its cores.
    function classIndexOf(uint256 tokenId) public view whenAlive returns (uint8) {
        uint256[] memory cores = talismans.coresOf(tokenId);
        if (cores.length == 0) {
            revert NotRevealed(tokenId);
        }
        return _classIndex(cores.length, TalismanTransformationLib.poleOf(talismans.materials(), cores));
    }

    /// @notice The number of cores a talisman of class `classIndex` holds.
    function classCores(uint8 classIndex) public pure returns (uint256) {
        return _classMult(classIndex) * (_classTier(classIndex) + 1);
    }

    /// @notice The exchange weight of a talisman of class `classIndex`.
    function classWeight(uint8 classIndex) public pure returns (uint256) {
        return _classWeight(classIndex);
    }

    /// @notice The most points {swapDown} may ever be configured to pay back for
    ///         class `classIndex`: never more than the class weighs, and never
    ///         more than one extra core per half above what it holds.
    /// @dev Enforced by {setSwapDownTerms} whether or not the premium is
    ///      switched on, so turning the premium on can never make a stored table
    ///      unsafe. The weight arm keeps a chain of swap downs from ever beating
    ///      a single direct one; the core arm keeps a round trip through the
    ///      forge from printing cores.
    function swapDownPayoutCap(uint8 classIndex) public pure returns (uint256) {
        uint256 byWeight = _classWeight(classIndex);
        uint256 byCores = classCores(classIndex) + _classMult(classIndex) * MAX_CORE_PREMIUM_PER_HALF;
        return byWeight < byCores ? byWeight : byCores;
    }

    /// @notice Whether {swap}, {swapUp} and {swapDown} are open to talisman
    ///         `tokenId`. A swap up reads as open when this talisman may climb
    ///         to the tier above it.
    function routesFor(uint256 tokenId)
        external
        view
        whenAlive
        returns (bool swapOpen, bool swapUpOpen, bool swapDownOpen)
    {
        uint8 i = classIndexOf(tokenId);
        return (_isOpen(_swapMask, i), _isOpen(_swapUpMask, i), _isOpen(_swapDownMask, i));
    }

    /// @notice What {swapUp} charges to climb off talisman `tokenIn`.
    /// @return price The total weight `tokenIn` and its fee tokens must add up
    ///         to.
    /// @return feeTokenFloor The lightest talisman accepted as a fee token.
    /// @return ethFee The ETH to send as `msg.value`.
    /// @dev Reverts {MissingPriorTier} on a talisman that is already at the top
    ///      tier, which has nothing to climb to.
    function swapUpTermsOf(uint256 tokenIn)
        external
        view
        whenAlive
        returns (uint256 price, uint256 feeTokenFloor, uint256 ethFee)
    {
        uint8 i = classIndexOf(tokenIn);
        if (_classTier(i) == TOP_TIER) {
            revert MissingPriorTier(0);
        }
        return (_classWeight(i + 1) + _swapUpMargins[i], _swapUpFeeFloors[i], _swapUpFees[i]);
    }

    /// @notice The weight {swapDown} returns for `tokenIn`. With the premium
    ///         switched off this is the talisman's core count, so a swap down
    ///         never hands back more cores than it takes in.
    /// @dev A payout of p points buys at most p cores, since a 1-core is the
    ///      lightest talisman there is and weighs one point.
    function swapDownPayout(uint256 tokenIn) external view whenAlive returns (uint256) {
        return _payoutOf(classIndexOf(tokenIn));
    }

    /// @notice The timestamp from which reserve talisman `tokenId` can be
    ///         selected as an output; 0 if it is not listed.
    function selectableAt(uint256 tokenId) external view whenAlive returns (uint256) {
        uint64 t = _listedAt[tokenId];
        return t == 0 ? 0 : uint256(t) + _cooldown();
    }

    /// @notice The pole and core count of talisman `tokenId` - the pair that
    ///         places it in a swap class.
    /// @param tokenId The talisman to read.
    /// @return pole Whether the talisman is Lithic, Lumic or Mythic.
    /// @return coreCount How many cores it holds.
    function classOf(uint256 tokenId)
        external
        view
        whenAlive
        returns (TalismanTransformationLib.Pole pole, uint256 coreCount)
    {
        uint256[] memory cores = talismans.coresOf(tokenId);
        if (cores.length == 0) {
            revert NotRevealed(tokenId);
        }
        return (TalismanTransformationLib.poleOf(talismans.materials(), cores), cores.length);
    }

    /// @notice The reserve talismans of a given pole and core count. Empty
    ///         while no reserve is set.
    /// @dev Lists the whole reserve holding of that class, including talismans
    ///      still inside their shelf cooldown; check {selectableAt} before
    ///      offering one as a route output.
    /// @param pole Whether to match Lithic, Lumic or Mythic talismans.
    /// @param coreCount How many cores a talisman must hold to match.
    /// @return tokenIds The matching reserve-held talismans.
    function inventoryOfClass(TalismanTransformationLib.Pole pole, uint256 coreCount)
        external
        view
        whenAlive
        returns (uint256[] memory tokenIds)
    {
        address res = _reserve;
        if (res == address(0)) {
            return new uint256[](0);
        }
        uint256[] memory owned = talismans.tokensOfOwner(res);
        TalismanMaterials mats = talismans.materials();
        uint256 n = owned.length;
        uint256 count;
        for (uint256 i; i < n; ++i) {
            if (_isOfClass(mats, owned[i], pole, coreCount)) {
                ++count;
            }
        }
        tokenIds = new uint256[](count);
        uint256 j;
        for (uint256 i; i < n; ++i) {
            if (_isOfClass(mats, owned[i], pole, coreCount)) {
                tokenIds[j++] = owned[i];
            }
        }
    }

    /// @notice The current configuration: the reserve, the shelf cooldown, the
    ///         open routes and every price table, in one read.
    function config() external view whenAlive returns (Config memory) {
        return Config({
            reserve: _reserve,
            shelfCooldown: _cooldown(),
            swapDownPremiumEnabled: _swapDownPremiumEnabled,
            swapMask: _swapMask,
            swapUpMask: _swapUpMask,
            swapDownMask: _swapDownMask,
            swapFees: _swapFees,
            swapUpMargins: _swapUpMargins,
            swapUpFeeFloors: _swapUpFeeFloors,
            swapUpFees: _swapUpFees,
            swapDownPayouts: _swapDownPayouts,
            swapDownFees: _swapDownFees
        });
    }

    /// @notice Set the reserve wallet. The zero address closes every route.
    /// @dev The reserve must grant this contract ERC-721 approval for all on
    ///      the Talismans collection before outputs can be served.
    function setReserve(address wallet) external whenAlive onlyOwner {
        _reserve = wallet;
        emit ReserveSet(wallet);
    }

    /// @notice Open or close each route for each class, in one call. Bit `i` of
    ///         a mask is the class {classIndexOf} numbers `i`: bits 0 to 3 are
    ///         Lithic and Lumic of one to four cores, bits 4 to 7 are Mythic of
    ///         two to eight. Owner only.
    /// @dev Every mask is keyed by the class of the talisman the caller hands
    ///      in, so a swap up bit opens the climb off that class to the tier
    ///      above it. Bits with nothing to reach - a swap up off the top tier,
    ///      a swap down off a 1-core - are inert.
    /// @param swapMask Classes {swap} accepts.
    /// @param swapUpMask Classes {swapUp} accepts as the talisman being
    ///        upgraded.
    /// @param swapDownMask Classes {swapDown} accepts.
    function setRoutes(uint8 swapMask, uint8 swapUpMask, uint8 swapDownMask) external whenAlive onlyOwner {
        _swapMask = swapMask;
        _swapUpMask = swapUpMask;
        _swapDownMask = swapDownMask;
        emit RoutesSet(swapMask, swapUpMask, swapDownMask);
    }

    /// @notice Set the ETH {swap} charges for each class. Owner only.
    /// @param ethFees One fee per class, in wei, indexed by {classIndexOf}.
    function setSwapFees(uint64[8] calldata ethFees) external whenAlive onlyOwner {
        _swapFees = ethFees;
        emit SwapFeesSet(ethFees);
    }

    /// @notice Set what {swapUp} charges to climb off each class. Owner only.
    /// @dev A margin is the points burned on the climb, so the total charged is
    ///      always at least what the talisman received weighs. A fee floor above
    ///      what the trade charges beyond the talisman being upgraded would make
    ///      the class unfillable and is rejected.
    /// @param margins Per class, the points charged on top of the weight of the
    ///        talisman received.
    /// @param feeFloors Per class, the lightest talisman accepted as a fee
    ///        token.
    /// @param ethFees Per class, the ETH charged, in wei.
    function setSwapUpTerms(uint8[8] calldata margins, uint8[8] calldata feeFloors, uint64[8] calldata ethFees)
        external
        whenAlive
        onlyOwner
    {
        for (uint8 i; i < CLASS_COUNT; ++i) {
            // The fee tokens cover the price less what the talisman being
            // upgraded already weighs; a floor above that budget can never be
            // met by any single token.
            uint256 budget = _classWeight(i) + margins[i];
            if (feeFloors[i] > budget) {
                revert FeeFloorAboveBudget(i, feeFloors[i], budget);
            }
        }
        _swapUpMargins = margins;
        _swapUpFeeFloors = feeFloors;
        _swapUpFees = ethFees;
        emit SwapUpTermsSet(margins, feeFloors, ethFees);
    }

    /// @notice Set what {swapDown} pays back and charges for each class. Owner
    ///         only. A payout above {swapDownPayoutCap} is rejected.
    /// @dev Payouts are checked against the cap whatever the premium switch is
    ///      currently set to, so {setSwapDownPremiumEnabled} can never turn a
    ///      stored table into a draining one.
    /// @param payouts Per class, the points paid back before the premium switch
    ///        is applied.
    /// @param ethFees Per class, the ETH charged, in wei.
    function setSwapDownTerms(uint8[8] calldata payouts, uint64[8] calldata ethFees) external whenAlive onlyOwner {
        for (uint8 i; i < CLASS_COUNT; ++i) {
            uint256 cap = swapDownPayoutCap(i);
            if (payouts[i] > cap) {
                revert PayoutAboveCap(i, payouts[i], cap);
            }
        }
        _swapDownPayouts = payouts;
        _swapDownFees = ethFees;
        emit SwapDownTermsSet(payouts, ethFees);
    }

    /// @notice Switch the {swapDown} premium on or off. Owner only. Switched
    ///         off, every class pays back its core count instead of its table
    ///         figure, so a swap down never returns more cores than it takes in.
    /// @dev The table is untouched either way, so the premium can be switched
    ///      off and back on without re-sending it.
    function setSwapDownPremiumEnabled(bool enabled) external whenAlive onlyOwner {
        _swapDownPremiumEnabled = enabled;
        emit SwapDownPremiumSet(enabled);
    }

    /// @notice Set the shelf cooldown, between {MIN_SHELF_COOLDOWN} and
    ///         {MAX_SHELF_COOLDOWN}.
    /// @dev Applies to already-listed talismans too: selectability is always
    ///      listing time plus the current value.
    function setShelfCooldown(uint64 secs) external whenAlive onlyOwner {
        if (secs < MIN_SHELF_COOLDOWN || secs > MAX_SHELF_COOLDOWN) {
            revert CooldownOutOfBounds(secs);
        }
        _shelfCooldown = secs;
        emit CooldownSet(secs);
    }

    /// @notice Permanently disable this contract. One-way; afterward only
    ///         {withdrawEth} stays open so no ETH is stranded.
    function eject() external whenAlive onlyOwner {
        _ejected = true;
        emit Ejected();
    }

    /// @notice Send the accumulated swap fees to the current owner of the
    ///         Talismans collection. Callable by anyone, even after {eject}.
    function withdrawEth() external nonReentrant {
        address to = talismans.owner();
        if (to == address(0)) {
            revert OwnerIsZero();
        }
        uint256 amount = address(this).balance;
        if (amount == 0) {
            revert NothingToWithdraw();
        }
        (bool ok,) = to.call{value: amount}("");
        if (!ok) {
            revert EthTransferFailed();
        }
        emit EthWithdrawn(to, amount);
    }

    /// @notice Recover the full balance of an ERC-20 token mistakenly sent to
    ///         this contract. Owner only; unavailable after {eject}.
    function rescueERC20(IERC20 token) external whenAlive onlyOwner {
        token.safeTransfer(msg.sender, token.balanceOf(address(this)));
    }

    /// @notice Recover an ERC-721 token mistakenly sent to this contract.
    ///         Owner only; unavailable after {eject}.
    function rescueERC721(IERC721 token, uint256 tokenId) external whenAlive onlyOwner {
        token.transferFrom(address(this), msg.sender, tokenId);
    }

    /// @notice Recover ERC-1155 tokens mistakenly sent to this contract.
    ///         Owner only; unavailable after {eject}.
    function rescueERC1155(IERC1155 token, uint256 id, uint256 amount) external whenAlive onlyOwner {
        token.safeTransferFrom(address(this), msg.sender, id, amount, "");
    }

    function _checkSwap(uint256 tokenIn, uint256 tokenOut) private view returns (uint256 ethFee) {
        _requireSelectable(tokenOut);

        // A swap preserves class: both tokens must be revealed and share
        // pole and core count.
        uint256[] memory coresIn = talismans.coresOf(tokenIn);
        if (coresIn.length == 0) {
            revert NotRevealed(tokenIn);
        }
        uint256[] memory coresOut = talismans.coresOf(tokenOut);
        if (coresOut.length == 0) {
            revert NotRevealed(tokenOut);
        }
        TalismanMaterials mats = talismans.materials();
        TalismanTransformationLib.Pole pole = TalismanTransformationLib.poleOf(mats, coresIn);
        if (coresIn.length != coresOut.length || pole != TalismanTransformationLib.poleOf(mats, coresOut)) {
            revert ClassMismatch(tokenIn, tokenOut);
        }

        uint8 i = _classIndex(coresIn.length, pole);
        if (!_isOpen(_swapMask, i)) {
            revert RouteDisabled();
        }
        return _swapFees[i];
    }

    function _checkSwapUp(uint256 tokenIn, uint256[] calldata feeTokens, uint256 tokenOut)
        private
        view
        returns (uint256 requiredPoints, uint256 ethFee)
    {
        uint256 nFee = feeTokens.length;
        if (nFee == 0) {
            revert TooFewFeeTokens();
        }
        _requireSelectable(tokenOut);
        TalismanMaterials mats = talismans.materials();

        uint256[] memory coresOut = talismans.coresOf(tokenOut);
        if (coresOut.length == 0) {
            revert NotRevealed(tokenOut);
        }
        uint256[] memory coresIn = talismans.coresOf(tokenIn);
        if (coresIn.length == 0) {
            revert NotRevealed(tokenIn);
        }
        TalismanTransformationLib.Pole outPole = TalismanTransformationLib.poleOf(mats, coresOut);
        TalismanTransformationLib.Pole inPole = TalismanTransformationLib.poleOf(mats, coresIn);
        if (inPole != outPole) {
            revert ClassMismatch(tokenIn, tokenOut);
        }

        // Exactly one tier below: pure steps by one core, Mythic by two.
        uint256 step = outPole == TalismanTransformationLib.Pole.Mythic ? 2 : 1;
        if (coresOut.length <= step) {
            revert MissingPriorTier(0);
        }
        uint256 requiredPrior = coresOut.length - step;
        if (coresIn.length != requiredPrior) {
            revert MissingPriorTier(requiredPrior);
        }

        uint8 i = _classIndex(coresIn.length, inPole);
        if (!_isOpen(_swapUpMask, i)) {
            revert RouteDisabled();
        }

        // tokenIn plus fee tokens weigh exactly the output plus this class's
        // margin, and no fee token weighs less than this class's floor.
        requiredPoints = _classWeight(_classIndex(coresOut.length, outPole)) + _swapUpMargins[i];
        ethFee = _swapUpFees[i];
        uint256 floor = _swapUpFeeFloors[i];
        uint256 points = _classWeight(i);
        for (uint256 j; j < nFee; ++j) {
            uint256 id = feeTokens[j];
            _requireDistinct(feeTokens, j, tokenIn);
            uint256[] memory cores = talismans.coresOf(id);
            if (cores.length == 0) {
                revert NotRevealed(id);
            }
            uint256 w = _classWeight(_classIndex(cores.length, TalismanTransformationLib.poleOf(mats, cores)));
            if (w < floor) {
                revert FeeTokenBelowFloor(id, floor);
            }
            points += w;
            // Weights are positive, so an overshoot can never come back down.
            if (points > requiredPoints) {
                revert WrongPoints(requiredPoints, points);
            }
        }
        if (points != requiredPoints) {
            revert WrongPoints(requiredPoints, points);
        }
    }

    function _checkSwapDown(uint256 tokenIn, uint256[] calldata tokensOut) private view returns (uint256 ethFee) {
        uint256 nOut = tokensOut.length;
        if (nOut == 0) {
            revert TooFewOutputTokens();
        }
        TalismanMaterials mats = talismans.materials();

        uint256[] memory coresIn = talismans.coresOf(tokenIn);
        if (coresIn.length == 0) {
            revert NotRevealed(tokenIn);
        }
        uint8 i = _classIndex(coresIn.length, TalismanTransformationLib.poleOf(mats, coresIn));
        if (!_isOpen(_swapDownMask, i)) {
            revert RouteDisabled();
        }

        uint256 inWeight = _classWeight(i);
        // The lightest talisman there is weighs one, so nothing sits below it.
        if (inWeight == 1) {
            revert NoLighterClass(tokenIn);
        }

        uint256 required = _payoutOf(i);
        uint256 points;
        for (uint256 j; j < nOut; ++j) {
            uint256 id = tokensOut[j];
            _requireDistinct(tokensOut, j, tokenIn);
            _requireSelectable(id);
            uint256[] memory cores = talismans.coresOf(id);
            if (cores.length == 0) {
                revert NotRevealed(id);
            }
            uint256 w = _classWeight(_classIndex(cores.length, TalismanTransformationLib.poleOf(mats, cores)));
            if (w >= inWeight) {
                revert OutputNotLighter(id);
            }
            points += w;
            if (points > required) {
                revert WrongPoints(required, points);
            }
        }
        if (points != required) {
            revert WrongPoints(required, points);
        }

        return _swapDownFees[i];
    }

    /// @dev The payout actually served: the table figure, clamped to the class's
    ///      core count while the premium is switched off. Clamping here rather
    ///      than in the setter is what lets one call restore the conservative
    ///      schedule without touching the table.
    function _payoutOf(uint8 classIndex) private view returns (uint256) {
        uint256 p = _swapDownPayouts[classIndex];
        if (!_swapDownPremiumEnabled) {
            uint256 n = classCores(classIndex);
            if (p > n) {
                return n;
            }
        }
        return p;
    }

    /// @dev Reverts unless `ids[index]` appears nowhere else in `ids` and is not
    ///      `other`. Bags are short (the fee-token floor and the weight budget
    ///      both bound them), so the pairwise scan stays cheap and callers are
    ///      spared an ordering requirement.
    function _requireDistinct(uint256[] calldata ids, uint256 index, uint256 other) private pure {
        uint256 id = ids[index];
        if (id == other) {
            revert DuplicateToken(id);
        }
        uint256 n = ids.length;
        for (uint256 j = index + 1; j < n; ++j) {
            if (ids[j] == id) {
                revert DuplicateToken(id);
            }
        }
    }

    /// @dev A Mythic is a Lithic and a Lumic half bonded together, so it shares a
    ///      tier with the Pure talisman of half its cores and sits in the upper
    ///      half of the index. Tiers outside Raw to Prime cannot be produced by
    ///      the collection; rejecting them by name beats an array-bounds panic.
    function _classIndex(uint256 coreCount, TalismanTransformationLib.Pole pole) private pure returns (uint8) {
        uint256 halfCores = pole == TalismanTransformationLib.Pole.Mythic ? coreCount / 2 : coreCount;
        if (halfCores == 0) {
            revert UnsupportedClass(coreCount);
        }
        uint256 tier = halfCores - 1;
        if (tier > TOP_TIER) {
            revert UnsupportedClass(coreCount);
        }
        // The bounds check above pins tier to 0..3, so the sum is at most 7 and
        // the cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8((pole == TalismanTransformationLib.Pole.Mythic ? 4 : 0) + tier);
    }

    function _classTier(uint8 classIndex) private pure returns (uint256) {
        return classIndex & 3;
    }

    /// @dev How many halves the class is priced as: one for a Lithic or Lumic,
    ///      two for a Mythic.
    function _classMult(uint8 classIndex) private pure returns (uint256) {
        return classIndex < 4 ? 1 : 2;
    }

    /// @dev Lithic/Lumic: 2^tier. Mythic: both halves, 2 * 2^tier.
    function _classWeight(uint8 classIndex) private pure returns (uint256) {
        return _classMult(classIndex) << _classTier(classIndex);
    }

    function _isOpen(uint8 mask, uint8 classIndex) private pure returns (bool) {
        return (mask >> classIndex) & 1 == 1;
    }

    function _cooldown() private view returns (uint64) {
        uint64 c = _shelfCooldown;
        return c == 0 ? DEFAULT_SHELF_COOLDOWN : c;
    }

    function _requireSelectable(uint256 tokenOut) private view {
        address res = _reserve;
        if (res == address(0)) {
            revert ReserveNotSet();
        }
        if (talismans.ownerOf(tokenOut) != res) {
            revert NotInReserve(tokenOut);
        }
        uint64 listedAt = _listedAt[tokenOut];
        if (listedAt == 0) {
            revert NotListed(tokenOut);
        }
        uint256 from = uint256(listedAt) + _cooldown();
        if (block.timestamp < from) {
            revert CooldownActive(tokenOut, from);
        }
    }

    function _takeIn(uint256 tokenId) private {
        // An incoming token goes straight onto the shelf: list it here so its
        // cooldown starts with the transfer.
        _listedAt[tokenId] = uint64(block.timestamp);
        talismans.transferFrom(msg.sender, _reserve, tokenId);
    }

    function _giveOut(uint256 tokenId) private {
        // Clear the listing so the token cannot return to the shelf
        // pre-cooled if it ever re-enters the reserve.
        delete _listedAt[tokenId];
        talismans.transferFrom(_reserve, msg.sender, tokenId);
    }

    function _isOfClass(TalismanMaterials mats, uint256 tokenId, TalismanTransformationLib.Pole pole, uint256 coreCount)
        private
        view
        returns (bool)
    {
        // Unrevealed tokens (no cores yet) belong to no class, so a
        // coreCount of 0 never matches.
        uint256[] memory cores = talismans.coresOf(tokenId);
        if (cores.length != coreCount || cores.length == 0) {
            return false;
        }
        return TalismanTransformationLib.poleOf(mats, cores) == pole;
    }
}
