// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {CreatorTokenBase} from "./CreatorTokenBase.sol";
import {ICreatorToken, ICreatorTokenLegacy} from "./ICreatorToken.sol";
import {ITalismanRenderer} from "./ITalismanRenderer.sol";
import {ITalismanTransformable} from "./ITalismanTransformable.sol";
import {TalismanTransformationLib} from "./TalismanTransformationLib.sol";
import {TalismanCore} from "./TalismanCore.sol";
import {TalismanForms} from "./TalismanForms.sol";
import {TalismanMaterials, MATERIAL_COUNT, NON_MYTHIC_MATERIAL_COUNT} from "./TalismanMaterials.sol";
import {
    MaterialsNotSet,
    RendererNotSet,
    NotRevealed,
    CannotBondSameToken,
    BondTokenNotRevealed,
    BondRequiresMatchedCores,
    BondRequiresOppositePoles,
    TokenNotCleavable,
    CutRejectsMythic,
    TokenNotCuttable,
    InvalidCutIndex,
    CannotMergeSameToken,
    MergeRejectsMythic,
    MergeRequiresSameKind,
    MergeExceedsTier
} from "./TalismanErrors.sol";

/// @title Talismans
contract Talismans is ERC721, ERC2981, Ownable2Step, CreatorTokenBase, IERC4906, ITalismanTransformable {
    /// @notice Thrown when an address other than the {minter} calls {mintWithCommitment}.
    /// @param caller The unauthorised caller.
    error UnauthorizedMinter(address caller);
    /// @notice Thrown by {reveal} and {recommit} when `tokenId` has no pending
    ///         commit - it was never minted, or has already revealed.
    /// @param tokenId The token with nothing to reveal.
    error NothingToReveal(uint256 tokenId);
    /// @notice Thrown by {reveal} when called before the token's commit block has been mined.
    /// @param tokenId The token being revealed.
    /// @param commitBlock The block that must be mined before revealing.
    error RevealTooEarly(uint256 tokenId, uint256 commitBlock);
    /// @notice Thrown by {reveal} when the commit block's hash is no longer
    ///         available - the 256-block window has passed. Use {recommit} to re-arm.
    /// @param tokenId The token being revealed.
    /// @param commitBlock The commit block whose hash has expired.
    error RevealUnavailable(uint256 tokenId, uint256 commitBlock);
    /// @notice Thrown by {recommit} when the token's reveal window is still
    ///         open, so re-arming is not yet permitted.
    /// @param tokenId The token being recommitted.
    /// @param commitBlock The still-valid commit block.
    error CommitStillFresh(uint256 tokenId, uint256 commitBlock);
    /// @notice Thrown when a transformation is attempted while its pair is
    ///         disabled - see {setTransformationSettings}.
    error TransformationDisabled();
    /// @notice Thrown by {setTransformationSettings} and
    ///         {freezeTransformationSettings} once the transformation toggles
    ///         have been permanently frozen.
    error TransformationSettingsAreFrozen();
    /// @notice Thrown by {setRenderer} and {freezeRenderer} once the renderer
    ///         reference has been permanently frozen.
    error RendererIsFrozen();
    /// @notice Thrown by {setMaterials} and {freezeMaterials} once the materials
    ///         table reference has been permanently frozen.
    error MaterialsAreFrozen();
    /// @notice Thrown by {mintWithCommitment} once {MAX_GENESIS_SUPPLY} genesis
    ///         tokens have been minted.
    error GenesisMintExhausted();
    /// @notice Thrown by {setRoyalty} when the requested royalty exceeds {MAX_ROYALTY_BPS}.
    /// @param bps The rejected royalty, in basis points.
    error RoyaltyTooHigh(uint96 bps);
    /// @notice Thrown by {setTransferValidator} and
    ///         {disableRoyaltyEnforcementForever} once royalty enforcement has
    ///         been permanently switched off - the validator can never be
    ///         changed again.
    error RoyaltyEnforcementFrozen();
    /// @notice Thrown by {rescueBalance} when the contract holds no ETH to sweep.
    error NothingToRescue();
    /// @notice Thrown by {bond} when its two inputs are held by different owners.
    /// @dev The two-input transforms mint their output to the inputs' shared
    ///      owner, never to `msg.sender`, so they require one common owner even
    ///      when run by an approved operator.
    /// @param tokenIdA The first input.
    /// @param tokenIdB The second input.
    error BondRequiresSameOwner(uint256 tokenIdA, uint256 tokenIdB);
    /// @notice Thrown by {merge} when its two inputs are held by different owners.
    /// @param tokenIdA The first input.
    /// @param tokenIdB The second input.
    error MergeRequiresSameOwner(uint256 tokenIdA, uint256 tokenIdB);
    /// @notice Thrown when the caller is neither the owner nor an approved
    ///         transformation operator for `tokenId`.
    /// @dev The transformation-right analogue of ERC-721's
    ///      {ERC721InsufficientApproval}: an ERC-721 transfer approval never
    ///      satisfies a transformation; only the owner or a
    ///      {setTransformationApprovalForAll} operator passes.
    /// @param operator The caller that lacked transformation rights.
    /// @param tokenId The token it tried to transform.
    error TransformationInsufficientApproval(address operator, uint256 tokenId);

    /// @notice Emitted when the owner changes the authorised {minter}.
    /// @param previousMinter The minter before the change.
    /// @param newMinter The minter after the change.
    event MinterUpdated(address indexed previousMinter, address indexed newMinter);
    /// @notice Emitted when the owner swaps the metadata {renderer}.
    /// @param previousRenderer The renderer before the change.
    /// @param newRenderer The renderer after the change.
    event RendererUpdated(address indexed previousRenderer, address indexed newRenderer);
    /// @notice Emitted when the owner sets a new {materials} table.
    /// @param previousMaterials The materials table before the change.
    /// @param newMaterials The materials table after the change.
    event MaterialsUpdated(address indexed previousMaterials, address indexed newMaterials);
    /// @notice Emitted when the owner enables or disables either transformation pair.
    /// @param bondAndCleaveEnabled Whether {bond} and {cleave} are now callable.
    /// @param cutAndMergeEnabled Whether {cut} and {merge} are now callable.
    event TransformationSettingsUpdated(bool bondAndCleaveEnabled, bool cutAndMergeEnabled);
    /// @notice Emitted once when {freezeTransformationSettings} permanently locks
    ///         the two transformation toggles. Fires at most once in the
    ///         contract's lifetime.
    event TransformationSettingsFrozen();
    /// @notice Emitted once when {freezeRenderer} permanently locks the
    ///         {renderer} reference. Fires at most once in the contract's lifetime.
    event RendererFrozen();
    /// @notice Emitted once when {freezeMaterials} permanently locks the
    ///         {materials} reference. Fires at most once in the contract's lifetime.
    event MaterialsFrozen();
    /// @notice Emitted when the owner updates the EIP-2981 default royalty.
    /// @param receiver The new royalty receiver.
    /// @param bps The new royalty, in basis points.
    event RoyaltyUpdated(address indexed receiver, uint96 bps);
    /// @notice Emitted once when {disableRoyaltyEnforcementForever} permanently
    ///         switches off royalty enforcement. Fires at most once in the
    ///         contract's lifetime.
    event RoyaltyEnforcementDisabledForever();

    /// @notice Emitted by {bond}: inputs `tokenIdA` and `tokenIdB` were burned
    ///         and the Mythic `bondedId` was minted to their owner.
    /// @dev Records the input->output link that the raw burn/mint Transfers (to
    ///      and from the zero address) cannot carry on their own. `operator` is
    ///      the caller; the output always mints to the inputs' shared owner,
    ///      never the operator.
    /// @param tokenIdA The first burned input.
    /// @param tokenIdB The second burned input.
    /// @param bondedId The minted Mythic.
    /// @param operator The caller that ran the bond.
    event Bonded(uint256 indexed tokenIdA, uint256 indexed tokenIdB, uint256 indexed bondedId, address operator);
    /// @notice Emitted by {cleave}: `tokenId` was burned and split into the
    ///         Lithic half `lithicId` and the Lumic half `lumicId`, both minted
    ///         to its owner.
    /// @dev Records the input->output link that the raw burn/mint Transfers
    ///      cannot carry on their own. `operator` is the caller; the outputs
    ///      mint to the token's owner.
    /// @param tokenId The burned Mythic.
    /// @param lithicId The minted Lithic half.
    /// @param lumicId The minted Lumic half.
    /// @param operator The caller that ran the cleave.
    event Cleaved(uint256 indexed tokenId, uint256 indexed lithicId, uint256 indexed lumicId, address operator);
    /// @notice Emitted by {cut}: `tokenId` was burned and split at `index` into
    ///         the head `headId` and tail `tailId`, both minted to its owner.
    /// @dev Records the input->output link that the raw burn/mint Transfers
    ///      cannot carry on their own. `operator` is the caller; the outputs
    ///      mint to the token's owner.
    /// @param tokenId The burned input.
    /// @param headId The minted head.
    /// @param tailId The minted tail.
    /// @param index The split point used.
    /// @param operator The caller that ran the cut.
    event Cut(uint256 indexed tokenId, uint256 indexed headId, uint256 indexed tailId, uint256 index, address operator);
    /// @notice Emitted by {merge}: inputs `tokenIdA` and `tokenIdB` were burned
    ///         and the merged token `mergedId` was minted to their owner.
    /// @dev Records the input->output link that the raw burn/mint Transfers
    ///      cannot carry on their own. `operator` is the caller; the output
    ///      mints to the inputs' shared owner, never the operator.
    /// @param tokenIdA The first burned input.
    /// @param tokenIdB The second burned input.
    /// @param mergedId The minted token.
    /// @param operator The caller that ran the merge.
    event Merged(uint256 indexed tokenIdA, uint256 indexed tokenIdB, uint256 indexed mergedId, address operator);

    /// @notice The maximum number of genesis Talismans mintable through the
    ///         primary sale, and the top of the genesis id range - genesis ids
    ///         run 1..{MAX_GENESIS_SUPPLY}.
    /// @dev Transformations ({bond}/{cleave}/{cut}/{merge}) mint freely beyond
    ///      this; only the primary sale is bounded.
    uint256 public constant MAX_GENESIS_SUPPLY = 1536;

    /// @notice The number of genesis Talismans reserved as artist proofs - the
    ///         first {MAX_ARTIST_PROOFS} ids.
    /// @dev Enforced by the minter, which only mints proofs while genesis stays
    ///      within this range; the token contract itself draws no distinction
    ///      between a proof and any other genesis token.
    uint256 public constant MAX_ARTIST_PROOFS = 36;

    /// @notice The most cores a single genesis reveal can produce, and the core
    ///         ceiling of a merged pure-tier Talisman.
    /// @dev {merge} enforces this as the pure-tier ceiling.
    uint256 public constant MAX_CORES_PER_MINT = 4;

    /// @notice The most cores any single Talisman can hold. A talisman tops out
    ///         at a Prime Mythic - 4 cores of matter (Lithic) bonded with 4 of
    ///         event (Lumic).
    /// @dev Twice {MAX_CORES_PER_MINT}. Mint produces at most
    ///      {MAX_CORES_PER_MINT}; only {bond} can carry a token to this ceiling.
    uint256 public constant MAX_CORES_PER_TOKEN = 2 * MAX_CORES_PER_MINT;

    /// @notice The number of blocks after a genesis mint before the token's
    ///         {reveal} can be drawn.
    /// @dev The commit block is a *future* block, so its `blockhash` - the seed
    ///      {reveal} draws from - is unknown when the token is minted and
    ///      cannot be chosen by the minter.
    uint256 public constant REVEAL_DELAY = 2;

    /// @notice The EIP-2981 royalty applied at deploy: 500 basis points (5%) of
    ///         the sale price.
    /// @dev Denominator is 10000. Owner-tunable afterwards via {setRoyalty}.
    uint96 public constant DEFAULT_ROYALTY_BPS = 500;

    /// @notice The highest royalty the owner can set, in basis points (1000 = 10%).
    uint96 public constant MAX_ROYALTY_BPS = 1000;

    /// @notice True once royalty enforcement has been permanently switched off.
    ///         After freezing, the ERC-721C transfer validator stays the zero
    ///         address forever: no operator is ever gated, every marketplace can
    ///         settle a sale, and enforcement can never be re-enabled.
    /// @dev One-way: set by {disableRoyaltyEnforcementForever}. While false the
    ///      owner may still repoint the validator via {setTransferValidator};
    ///      once true that always reverts {RoyaltyEnforcementFrozen}. The
    ///      irrevocable hand-off to optional royalties. The EIP-2981 rate
    ///      ({setRoyalty}) and every other owner control stay live.
    bool public royaltyEnforcementFrozen;

    uint256 private _totalSupply;
    /// @dev Count of genesis tokens minted via {mintWithCommitment}. Doubles
    ///      as the genesis id sequence: the n-th genesis token takes id `n`,
    ///      so genesis ids run 1..{MAX_GENESIS_SUPPLY} contiguously. Only this
    ///      counter is capped by {MAX_GENESIS_SUPPLY}; transformations and
    ///      burns never touch it - burning a genesis token leaves the counter
    ///      (and thus the genesis id space) intact.
    uint256 private _genesisMinted;
    /// @dev Free-id counter for transformation outputs. Starts one past the
    ///      genesis range so transform ids never collide with genesis ids -
    ///      even when a transform runs while the genesis sale is still open.
    ///      Monotonic; burns/merges never roll it back.
    uint256 private _nextTransformId = MAX_GENESIS_SUPPLY + 1;
    /// @notice The sole address allowed to mint genesis Talismans via {mintWithCommitment}.
    /// @dev Set by the owner via {setMinter}; the zero address disables minting.
    address public minter;

    /// @notice Whether {bond} and {cleave} are currently callable.
    /// @dev Owner-toggled via {setTransformationSettings}, independently of the
    ///      cut/merge pair. Both pairs default off so transforms can open after
    ///      the genesis mint settles. No owner bypass - when off, every caller
    ///      reverts {TransformationDisabled}.
    bool public bondAndCleaveEnabled;
    /// @notice Whether {cut} and {merge} are currently callable.
    bool public cutAndMergeEnabled;
    /// @notice True once the transformation toggles have been permanently
    ///         locked. After freezing, the two pairs keep their current on/off
    ///         state forever.
    /// @dev One-way: set by {freezeTransformationSettings}. While false the
    ///      owner may still flip either pair; once true {setTransformationSettings}
    ///      always reverts. This is the irrevocable hand-off that makes the
    ///      transformations a permanent, owner-ungated part of the collection.
    ///      Other owner controls (renderer, royalty, materials, minter) are
    ///      unaffected.
    bool public transformationSettingsFrozen;
    /// @dev Per-owner transformation operator approvals - the transformation
    ///      analogue of ERC-721's `_operatorApprovals`. A true entry lets the
    ///      operator run {bond}/{cleave}/{cut}/{merge} on the owner's tokens,
    ///      and grants no transfer right whatsoever; it is wholly independent of
    ///      {setApprovalForAll}. Read via {isTransformationApprovedForAll}.
    mapping(address owner => mapping(address operator => bool)) private _transformationApprovalForAll;
    /// @notice The active metadata renderer that produces each token's {tokenURI}.
    /// @dev Replaceable by the owner via {setRenderer}. Treated as an untrusted
    ///      read-only oracle: a misbehaving renderer can revert {tokenURI} but
    ///      cannot mutate token state.
    ITalismanRenderer public renderer;
    /// @notice True once the {renderer} reference has been permanently locked.
    ///         After freezing, {tokenURI} keeps resolving through whatever
    ///         renderer was active at that moment, forever.
    /// @dev One-way: set by {freezeRenderer}. While false the owner may still
    ///      swap the renderer via {setRenderer}; once true {setRenderer} always
    ///      reverts. The irrevocable hand-off that fixes the metadata pipeline.
    bool public rendererFrozen;
    /// @notice The material identity table backing token-level material
    ///         synthesis in {coreMaterialId}.
    /// @dev Owner-settable; treated as trusted reference data - its records
    ///      define the element grids {coreMaterialId} folds cores into.
    TalismanMaterials public materials;
    /// @notice True once the {materials} reference has been permanently locked.
    ///         After freezing, {coreMaterialId} keeps reading whatever table was
    ///         active at that moment, forever.
    /// @dev One-way: set by {freezeMaterials}. While false the owner may still
    ///      swap the table via {setMaterials}; once true {setMaterials} always
    ///      reverts. The irrevocable hand-off that fixes material identity.
    bool public materialsFrozen;

    mapping(uint256 tokenId => uint256 commitBlock) private _commitBlock;
    mapping(uint256 tokenId => uint256[] cores) private _cores;

    /// @dev Per-owner token index, maintained in {_update}. Backs
    ///      {tokensOfOwner} so the frontend can enumerate a wallet's holdings
    ///      with a single contract read - no Transfer-log replay and no
    ///      external indexer. Only the *per-owner* side is kept: the
    ///      collection's id space is sparse and its high-water mark grows with
    ///      crafting churn, so a global token index (a la ERC721Enumerable's
    ///      `_allTokens`) would tax every mint to serve a `tokenByIndex`
    ///      nothing here calls - `totalSupply()` already covers counts cheaply.
    ///
    ///      This is balance-indexed: `_ownedTokens[owner][i]` holds the owner's
    ///      i-th token for `i` in `0..balanceOf(owner)-1`, and
    ///      `_ownedTokensIndex[tokenId]` is that token's slot for O(1)
    ///      swap-and-pop removal. Reusing `balanceOf` as the position counter
    ///      is what makes this cheaper than a per-owner `EnumerableSet` (no
    ///      separate values-array length slot) on every mint, transfer, and
    ///      burn.
    mapping(address owner => mapping(uint256 index => uint256 tokenId)) private _ownedTokens;
    mapping(uint256 tokenId => uint256 index) private _ownedTokensIndex;

    /// @dev The canonical token id for an *ordered* core sequence, keyed on
    ///      `keccak256(abi.encodePacked(cores))`. The first time a sequence
    ///      is produced it claims a fresh id; every later
    ///      recurrence (e.g. a bond->cleave round-trip) re-mints that same id.
    ///      Burned tokens keep their entry, so a token's cores - and thus its
    ///      id - never change once it exists. This is why transformations do
    ///      not emit MetadataUpdate: a given id always renders identically.
    mapping(bytes32 coreKey => uint256 tokenId) private _tokenIdForCores;

    /// @dev Reveal weights for core counts 1..MAX_CORES_PER_MINT - the tier
    ///      distribution (Raw 40%, Cut 30%, Fine 20%, Prime 10%). Index 0 is
    ///      the weight for 1 core, etc. Mean 2.0 cores per mint (variance 1.0);
    ///      Prime is a 1-in-10 apex. Fixed; not mutable.
    function _coreRarityWeights() private pure returns (uint256[MAX_CORES_PER_MINT] memory) {
        return [uint256(40), 30, 20, 10];
    }

    modifier onlyMinter() {
        if (msg.sender != minter) {
            revert UnauthorizedMinter(msg.sender);
        }
        _;
    }

    constructor() ERC721("Talismans", "TLSM") Ownable(msg.sender) {
        // EIP-2981 default: 5% to the deployer (the initial owner). Both the
        // rate and the recipient are owner-tunable later via {setRoyalty}; the
        // recipient does not auto-follow ownership transfers.
        _setDefaultRoyalty(msg.sender, DEFAULT_ROYALTY_BPS);
    }

    // --- Views ---------------------------------------------------------------

    /// @notice The number of Talismans currently in existence - genesis tokens
    ///         and transformation outputs alike, net of burns.
    /// @return The live token count.
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    /// @notice The number of genesis Talismans minted so far - also the highest
    ///         genesis id in existence.
    /// @dev Capped at {MAX_GENESIS_SUPPLY}.
    /// @return The count of genesis tokens minted.
    function genesisMinted() external view returns (uint256) {
        return _genesisMinted;
    }

    /// @notice The id the next brand-new transformation output will claim.
    /// @dev Genesis ids are a separate sequence (see {genesisMinted}); this only
    ///      advances when a transformation mints a never-before-seen core
    ///      sequence.
    /// @return The next transformation id to be assigned.
    function nextTransformId() external view returns (uint256) {
        return _nextTransformId;
    }

    /// @notice True when `tokenId` falls in the genesis id range
    ///         (1..{MAX_GENESIS_SUPPLY}).
    /// @dev Purely positional - derived from the id alone, independent of
    ///      whether the token currently exists, is revealed, or how it was
    ///      formed. Transformation outputs (ids above {MAX_GENESIS_SUPPLY}) are
    ///      never genesis.
    /// @param tokenId The id to test; need not refer to a live token.
    /// @return True when `tokenId` sits in the genesis id range.
    /// @custom:category Token
    function isGenesis(uint256 tokenId) public pure returns (bool) {
        return tokenId != 0 && tokenId <= MAX_GENESIS_SUPPLY;
    }

    /// @notice The canonical token id for an ordered core sequence, or 0 if the
    ///         sequence has never been produced.
    /// @dev Lets the frontend resolve the id a transformation output will
    ///      (re)mint.
    /// @param cores The ordered core sequence to resolve.
    /// @return The canonical id recorded for that sequence, or 0 if never seen.
    /// @custom:category Transformable
    function tokenIdForCores(uint256[] calldata cores) external view returns (uint256) {
        return _tokenIdForCores[TalismanTransformationLib.coreKey(cores)];
    }

    /// @notice The block whose hash will seed `tokenId`'s {reveal}, or 0 once
    ///         the token has revealed or was never minted.
    /// @dev {reveal} is callable after this block, within the following
    ///      256-block window.
    /// @param tokenId The token to look up.
    /// @return The pending commit block, or 0 if there is nothing to reveal.
    /// @custom:category Token
    function commitBlockOf(uint256 tokenId) external view returns (uint256) {
        return _commitBlock[tokenId];
    }

    /// @notice The reveal odds for each genesis core count, as weights indexed
    ///         by (count - 1): index 0 weights a 1-core token, up to
    ///         {MAX_CORES_PER_MINT}.
    /// @dev Fixed for the life of the contract.
    /// @return weights The per-core-count rarity weights, lowest count first.
    function coreRarityWeights() external pure returns (uint256[] memory weights) {
        uint256[MAX_CORES_PER_MINT] memory w = _coreRarityWeights();
        weights = new uint256[](MAX_CORES_PER_MINT);
        for (uint256 i; i < MAX_CORES_PER_MINT; ++i) {
            weights[i] = w[i];
        }
    }

    /// @notice The cores composing `tokenId`, in order - empty until the token
    ///         is revealed.
    /// @dev Each core packs a material, shape form, and seed; see {TalismanCore}.
    /// @param tokenId The token to read.
    /// @return The token's ordered cores, or an empty array if unrevealed.
    /// @custom:category Token
    function coresOf(uint256 tokenId) external view returns (uint256[] memory) {
        return _cores[tokenId];
    }

    /// @notice How many cores `tokenId` holds - its tier signal. 0 until
    ///         revealed; a bonded Mythic can reach {MAX_CORES_PER_TOKEN}.
    /// @param tokenId The token to read.
    /// @return The token's core count, or 0 if unrevealed.
    /// @custom:category Token
    function coreCount(uint256 tokenId) external view returns (uint256) {
        return _cores[tokenId].length;
    }

    /// @notice Every live token id held by `owner`, in one call. Lets a wallet
    ///         enumerate its Talismans from contract state alone - no
    ///         Transfer-log replay and no external indexer.
    /// @dev Returned in storage (insertion/swap) order, not sorted - callers
    ///      that need a stable order should sort client-side. The array is
    ///      bounded by live supply, so it stays small. This intentionally does
    ///      NOT implement the full {IERC721Enumerable} interface (there is no
    ///      global `tokenByIndex`) - see {_ownedTokens}.
    /// @param owner The wallet to enumerate.
    /// @return tokens The owner's live token ids, in storage order.
    function tokensOfOwner(address owner) external view returns (uint256[] memory tokens) {
        uint256 count = balanceOf(owner);
        tokens = new uint256[](count);
        mapping(uint256 index => uint256 tokenId) storage ownerTokens = _ownedTokens[owner];
        for (uint256 i; i < count; ++i) {
            tokens[i] = ownerTokens[i];
        }
    }

    /// @notice True once `tokenId` has been revealed and carries its final
    ///         cores - and thus renders its final art.
    /// @param tokenId The token to test.
    /// @return True once the token has revealed and carries its cores.
    /// @custom:category Token
    function isRevealed(uint256 tokenId) external view returns (bool) {
        return _cores[tokenId].length > 0;
    }

    /// @notice True when `tokenId` can be {cleave}d - i.e. it is a revealed
    ///         Mythic, with cores spanning both the Lithic and Lumic poles.
    /// @dev Pole-based, not provenance-based: any Mythic cleaves, regardless of
    ///      how it was formed.
    /// @param tokenId The token to test.
    /// @return True when the token is a revealed Mythic eligible for {cleave}.
    /// @custom:category Token
    function isCleavable(uint256 tokenId) external view returns (bool) {
        uint256[] memory cores = _cores[tokenId];
        if (cores.length == 0) {
            return false;
        }
        return TalismanTransformationLib.poleOf(materials, cores) == TalismanTransformationLib.Pole.Mythic;
    }

    // The two guards below are guard-and-bind helpers: each validates a
    // precondition and hands back the value the caller needs, so the check and
    // the load live in one place and the value is never read twice.

    /// @dev Load `tokenId`'s cores, reverting {NotRevealed} if it has none. The
    ///      single source of truth for the revealed-token guard shared by the
    ///      core-trait reads and the {tokenView} / {tokenImage} / {tokenShape}
    ///      renders.
    function _revealedCores(uint256 tokenId) internal view returns (uint256[] memory cores) {
        cores = _cores[tokenId];
        if (cores.length == 0) {
            revert NotRevealed(tokenId);
        }
    }

    /// @dev Load `tokenId`'s cores for a render, separating the two failure
    ///      modes the core-trait reads collapse: reverts {ERC721NonexistentToken}
    ///      for an unminted id and {NotRevealed} for a minted-but-unrevealed one.
    ///      The shared guard for {tokenView} / {tokenImage} / {tokenShape} /
    ///      {tokenData}.
    function _renderableCores(uint256 tokenId) internal view returns (uint256[] memory) {
        if (_ownerOf(tokenId) == address(0)) {
            revert IERC721Errors.ERC721NonexistentToken(tokenId);
        }
        return _revealedCores(tokenId);
    }

    /// @dev Return the active renderer, reverting {RendererNotSet} if none is
    ///      wired. The single source of truth for the renderer guard shared by
    ///      {tokenURI} and the {tokenView} / {tokenImage} / {tokenShape} renders.
    function _activeRenderer() internal view returns (ITalismanRenderer r) {
        r = renderer;
        if (address(r) == address(0)) {
            revert RendererNotSet();
        }
    }

    /// @notice The token-level material id, synthesised from its cores' element
    ///         signatures.
    /// @dev Requires {materials} to be set; reverts {MaterialsNotSet} otherwise.
    ///      See {TalismanTransformationLib} for the derivation.
    /// @param tokenId The token to read; reverts {NotRevealed} if unrevealed.
    /// @return The token-level material id synthesised from its cores.
    /// @custom:category Token
    function coreMaterialId(uint256 tokenId) external view returns (uint8) {
        return TalismanTransformationLib.deriveMaterialId(materials, _revealedCores(tokenId));
    }

    /// @notice The token-level shape form, derived from its cores.
    /// @dev The most common form across the cores wins; on a tie the
    ///      higher-index (later) core's form overrides.
    /// @param tokenId The token to read; reverts {NotRevealed} if unrevealed.
    /// @return The token-level shape form derived from its cores.
    /// @custom:category Token
    function coreShapeForm(uint256 tokenId) external view returns (TalismanForms.ShapeForm) {
        return TalismanTransformationLib.deriveShapeForm(_revealedCores(tokenId));
    }

    /// @notice The token-level entropy that drives its on-chain art's
    ///         perturbation and color draws, derived from its cores.
    /// @dev The XOR of the cores' seeds. Duplicate seeds are dropped first: XOR
    ///      is self-cancelling, so an even number of equal seeds would vanish -
    ///      only the first occurrence of each distinct seed contributes. The
    ///      renderer consumes this; shape form is a separate core field, not
    ///      derived from this seed.
    /// @param tokenId The token to read; reverts {NotRevealed} if unrevealed.
    /// @return The token-level shape-randomization seed derived from its cores.
    /// @custom:category Token
    function coreSeed(uint256 tokenId) external view returns (uint16) {
        return TalismanTransformationLib.deriveSeed(_revealedCores(tokenId));
    }

    // --- tokenURI / token surfaces ---------------------------------------------

    /// @notice A token's cores and the token-level traits derived from them - the
    ///         complete derived state {tokenData} returns in one read.
    /// @param cores The token's ordered cores, as {coresOf} returns them.
    /// @param materialId The token-level material id, as {coreMaterialId}.
    /// @param form The token-level shape form, as {coreShapeForm}.
    /// @param coreCount The number of cores, as {coreCount} (equals `cores.length`).
    /// @param seed The token-level shape-randomization seed, as {coreSeed}.
    struct TokenData {
        uint256[] cores;
        uint8 materialId;
        TalismanForms.ShapeForm form;
        uint8 coreCount;
        uint16 seed;
    }

    /// @notice The ERC-721 metadata URI for `tokenId`, produced by the active
    ///         renderer.
    /// @dev Resolves the token's state here and hands the renderer only what it
    ///      needs: a pre-reveal token routes to the renderer's `unrevealedURI`
    ///      placeholder, a revealed one has its `(materialId, form, cores, seed)`
    ///      derived exactly as {tokenView} does and forwarded to
    ///      `tokenURIFromTraits`. Reverts {ERC721NonexistentToken} for unknown
    ///      ids, {RendererNotSet} if no renderer is wired, and {MaterialsNotSet}
    ///      if a revealed token is rendered before the material table is set. The
    ///      renderer is treated as an untrusted view oracle - its return value is
    ///      forwarded verbatim, so any malformed payload is a renderer bug, not a
    ///      token-state issue.
    /// @param tokenId The token to render; reverts {ERC721NonexistentToken} if
    ///        it does not exist.
    /// @return The metadata URI produced by the active renderer.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (_ownerOf(tokenId) == address(0)) {
            revert IERC721Errors.ERC721NonexistentToken(tokenId);
        }
        ITalismanRenderer r = _activeRenderer();
        uint256[] memory cores = _cores[tokenId];
        if (cores.length == 0) {
            return r.unrevealedURI(tokenId);
        }
        return r.tokenURIFromTraits(
            tokenId,
            TalismanTransformationLib.deriveMaterialId(materials, cores),
            TalismanTransformationLib.deriveShapeForm(cores),
            uint8(cores.length),
            TalismanTransformationLib.deriveSeed(cores),
            isGenesis(tokenId)
        );
    }

    /// @notice The standalone interactive viewer for `tokenId` - the same
    ///         animated document wallets load as the token's `animation_url`,
    ///         returned as raw markup. The result is a complete HTML file: write
    ///         it to a `.html` and open it in a browser as-is.
    /// @dev Reads the token's cores and derives its `(materialId, form,
    ///      coreCount, seed)` exactly as {coreMaterialId}, {coreShapeForm},
    ///      {coreCount} and {coreSeed} do, then forwards them to the active
    ///      renderer's `htmlFromTraits`. Returns the document verbatim - no
    ///      base64, no `data:` prefix - unlike {tokenURI}, which wraps the same
    ///      HTML into the metadata `animation_url`. Reverts {RendererNotSet} when
    ///      no renderer is wired and {MaterialsNotSet} when the material table is
    ///      unset.
    /// @param tokenId The token to render; reverts {ERC721NonexistentToken} if it
    ///        does not exist and {NotRevealed} until it has revealed.
    /// @return The complete, self-contained interactive viewer document.
    /// @custom:category Token
    function tokenView(uint256 tokenId) external view returns (string memory) {
        uint256[] memory cores = _renderableCores(tokenId);
        return _activeRenderer()
            .htmlFromTraits(
                TalismanTransformationLib.deriveMaterialId(materials, cores),
                TalismanTransformationLib.deriveShapeForm(cores),
                uint8(cores.length),
                TalismanTransformationLib.deriveSeed(cores)
            );
    }

    /// @notice The still image for `tokenId` - the same artwork wallets load as
    ///         the token's `image`, returned as raw markup. The result is a
    ///         complete SVG file: write it to a `.svg` and open it as-is.
    /// @dev Derives the token's traits exactly as {tokenView} does, then forwards
    ///      them to the active renderer's `imageFromTraits`. Returns the document
    ///      verbatim - no base64, no `data:` prefix - unlike {tokenURI}, which
    ///      wraps the same SVG into the metadata `image`. Reverts {RendererNotSet}
    ///      when no renderer is wired and {MaterialsNotSet} when the material
    ///      table is unset.
    /// @param tokenId The token to render; reverts {ERC721NonexistentToken} if it
    ///        does not exist and {NotRevealed} until it has revealed.
    /// @return The complete, self-contained SVG image document.
    /// @custom:category Token
    function tokenImage(uint256 tokenId) external view returns (string memory) {
        uint256[] memory cores = _renderableCores(tokenId);
        return _activeRenderer()
            .imageFromTraits(
                TalismanTransformationLib.deriveMaterialId(materials, cores),
                TalismanTransformationLib.deriveShapeForm(cores),
                uint8(cores.length),
                TalismanTransformationLib.deriveSeed(cores)
            );
    }

    /// @notice The 3D model for `tokenId` as a binary STL file - the raw bytes,
    ///         ready to write to a `.stl` and open in any 3D viewer or slicer.
    ///         Faces carry per-material colour, so colour-aware viewers show the
    ///         same materials as {tokenImage}.
    /// @dev Derives the token's traits exactly as {tokenView} does, then forwards
    ///      them to the active renderer's `stlFromTraits`. Returns the file as raw
    ///      bytes - not base64, not a `data:` prefix. Reverts {RendererNotSet}
    ///      when no renderer is wired and {MaterialsNotSet} when the material
    ///      table is unset.
    /// @param tokenId The token to render; reverts {ERC721NonexistentToken} if it
    ///        does not exist and {NotRevealed} until it has revealed.
    /// @return The binary STL file as raw bytes.
    /// @custom:category Token
    function tokenShape(uint256 tokenId) external view returns (bytes memory) {
        uint256[] memory cores = _renderableCores(tokenId);
        return _activeRenderer()
            .stlFromTraits(
                TalismanTransformationLib.deriveMaterialId(materials, cores),
                TalismanTransformationLib.deriveShapeForm(cores),
                uint8(cores.length),
                TalismanTransformationLib.deriveSeed(cores)
            );
    }

    /// @notice Every derived trait of `tokenId` in one read: its ordered cores
    ///         plus the token-level `(materialId, form, coreCount, seed)` the art
    ///         is built from. The struct form of {coresOf}, {coreMaterialId},
    ///         {coreShapeForm}, {coreCount} and {coreSeed}, in a single call.
    /// @dev Needs no renderer - {materials} alone, for {coreMaterialId}'s
    ///      derivation. Reverts {MaterialsNotSet} when the material table is unset.
    /// @param tokenId The token to read; reverts {ERC721NonexistentToken} if it
    ///        does not exist and {NotRevealed} until it has revealed.
    /// @return data The token's cores and derived token-level traits.
    /// @custom:category Token
    function tokenData(uint256 tokenId) external view returns (TokenData memory data) {
        uint256[] memory cores = _renderableCores(tokenId);
        data = TokenData({
            cores: cores,
            materialId: TalismanTransformationLib.deriveMaterialId(materials, cores),
            form: TalismanTransformationLib.deriveShapeForm(cores),
            coreCount: uint8(cores.length),
            seed: TalismanTransformationLib.deriveSeed(cores)
        });
    }

    // --- Owner controls ------------------------------------------------------

    /// @notice Set the sole address allowed to call {mintWithCommitment} -
    ///         normally the sale contract. Owner only.
    /// @param newMinter The new authorised minter; the zero address disables
    ///        minting entirely.
    /// @custom:category Admin
    function setMinter(address newMinter) external onlyOwner {
        emit MinterUpdated(minter, newMinter);
        minter = newMinter;
    }

    /// @notice Swap the metadata renderer. Setting it to the zero address
    ///         disables {tokenURI} (it then reverts {RendererNotSet}). Owner only.
    /// @dev The new renderer is treated as read-only - see {tokenURI}. Emits
    ///      ERC-4906 {BatchMetadataUpdate} across the full id range so any
    ///      marketplace watching the event refreshes the whole collection: one
    ///      log, instead of a per-token update.
    /// @param newRenderer The renderer to activate; the zero address disables
    ///        {tokenURI} (it then reverts {RendererNotSet}).
    /// @custom:category Admin
    function setRenderer(ITalismanRenderer newRenderer) external onlyOwner {
        if (rendererFrozen) {
            revert RendererIsFrozen();
        }
        emit RendererUpdated(address(renderer), address(newRenderer));
        renderer = newRenderer;
        emit BatchMetadataUpdate(0, type(uint256).max);
    }

    /// @notice Permanently freeze the metadata renderer in its current state.
    ///         Owner only and irreversible - afterwards the renderer can never
    ///         be swapped again, fixing the metadata pipeline for good.
    /// @dev One-way: after this {setRenderer} always reverts. Intended for the
    ///      final hand-off once a permanent renderer is linked. Leaves every
    ///      other owner control (materials, royalty, transformations, minter)
    ///      intact. Reverts {RendererIsFrozen} if already frozen.
    /// @custom:category Admin
    function freezeRenderer() external onlyOwner {
        if (rendererFrozen) {
            revert RendererIsFrozen();
        }
        rendererFrozen = true;
        emit RendererFrozen();
    }

    /// @notice Set the material identity table used by {coreMaterialId}.
    ///         Required before any revealed token's material can be derived.
    ///         Owner only.
    /// @dev Emits ERC-4906 {BatchMetadataUpdate} so marketplaces refresh the
    ///      whole collection if the table changes a token's derived material.
    /// @param newMaterials The material identity table {coreMaterialId} reads.
    /// @custom:category Admin
    function setMaterials(TalismanMaterials newMaterials) external onlyOwner {
        if (materialsFrozen) {
            revert MaterialsAreFrozen();
        }
        emit MaterialsUpdated(address(materials), address(newMaterials));
        materials = newMaterials;
        emit BatchMetadataUpdate(0, type(uint256).max);
    }

    /// @notice Permanently freeze the material identity table in its current
    ///         state. Owner only and irreversible - afterwards the table can
    ///         never be swapped again, fixing every token's derived material.
    /// @dev One-way: after this {setMaterials} always reverts. Intended for the
    ///      final hand-off once the permanent materials table is linked. Leaves
    ///      every other owner control (renderer, royalty, transformations,
    ///      minter) intact. Reverts {MaterialsAreFrozen} if already frozen.
    /// @custom:category Admin
    function freezeMaterials() external onlyOwner {
        if (materialsFrozen) {
            revert MaterialsAreFrozen();
        }
        materialsFrozen = true;
        emit MaterialsFrozen();
    }

    /// @notice Enable or disable the two transformation pairs independently.
    ///         Bond/cleave and cut/merge toggle separately so the collection can
    ///         stage rollout. Owner only.
    /// @dev No owner bypass: when a pair is off, every caller (owner included)
    ///      reverts {TransformationDisabled}. Reverts
    ///      {TransformationSettingsAreFrozen} once {freezeTransformationSettings}
    ///      has locked the toggles - after that the pairs can never change.
    /// @param bondAndCleaveEnabled_ Whether {bond} and {cleave} are callable.
    /// @param cutAndMergeEnabled_ Whether {cut} and {merge} are callable.
    /// @custom:category Admin
    function setTransformationSettings(bool bondAndCleaveEnabled_, bool cutAndMergeEnabled_) external onlyOwner {
        if (transformationSettingsFrozen) {
            revert TransformationSettingsAreFrozen();
        }
        bondAndCleaveEnabled = bondAndCleaveEnabled_;
        cutAndMergeEnabled = cutAndMergeEnabled_;
        emit TransformationSettingsUpdated(bondAndCleaveEnabled_, cutAndMergeEnabled_);
    }

    /// @notice Permanently freeze the two transformation toggles in their
    ///         current state. Owner only and irreversible - afterwards neither
    ///         pair can ever be enabled or disabled again.
    /// @dev One-way: after this {setTransformationSettings} always reverts. This
    ///      removes the owner's ability to switch transformations off - the
    ///      final hand-off that makes them a permanent, ungated part of the
    ///      collection. Leaves every other owner control (renderer, royalty,
    ///      materials, minter) intact. Reverts
    ///      {TransformationSettingsAreFrozen} if already frozen.
    /// @custom:category Admin
    function freezeTransformationSettings() external onlyOwner {
        if (transformationSettingsFrozen) {
            revert TransformationSettingsAreFrozen();
        }
        transformationSettingsFrozen = true;
        emit TransformationSettingsFrozen();
    }

    /// @notice Set the collection-wide EIP-2981 royalty: `receiver` collects
    ///         `bps` basis points (denominator 10000) of every sale price.
    ///         Owner only.
    /// @dev `receiver` must be non-zero (OZ rejects the zero address); pass
    ///      `bps = 0` to waive royalties while keeping a valid receiver. Reverts
    ///      {RoyaltyTooHigh} above {MAX_ROYALTY_BPS}.
    /// @param receiver The address that collects royalties; must be non-zero.
    /// @param bps The royalty in basis points; capped at {MAX_ROYALTY_BPS}.
    /// @custom:category Admin
    function setRoyalty(address receiver, uint96 bps) external onlyOwner {
        if (bps > MAX_ROYALTY_BPS) {
            revert RoyaltyTooHigh(bps);
        }
        _setDefaultRoyalty(receiver, bps);
        emit RoyaltyUpdated(receiver, bps);
    }

    /// @notice Permanently switch off royalty enforcement in a single call.
    ///         Points the ERC-721C transfer validator to the zero address and
    ///         locks it there: every marketplace can settle a sale again, and
    ///         enforcement can never be turned back on. Owner only and
    ///         irreversible. The EIP-2981 royalty ({setRoyalty}) still applies -
    ///         it simply becomes a request marketplaces may honour rather than a
    ///         gate they must pass.
    /// @dev One-way: afterwards {setTransferValidator} always reverts
    ///      {RoyaltyEnforcementFrozen}. The credible, on-chain commitment to
    ///      optional royalties - the launch window can run enforcing, then this
    ///      relaxes it for good. Reverts {RoyaltyEnforcementFrozen} if already
    ///      called. Leaves every other owner control (renderer, materials,
    ///      transformations, minter, royalty rate) intact.
    /// @custom:category Admin
    function disableRoyaltyEnforcementForever() external onlyOwner {
        if (royaltyEnforcementFrozen) {
            revert RoyaltyEnforcementFrozen();
        }
        royaltyEnforcementFrozen = true;
        _setTransferValidator(address(0));
        emit RoyaltyEnforcementDisabledForever();
    }

    /// @notice Sweep any ETH stranded in this contract to the owner. Owner only;
    ///         reverts {NothingToRescue} when the balance is zero.
    /// @dev The token exposes no payable entry point and is not meant to custody
    ///      ETH, so a balance can only arrive by force - a `selfdestruct`
    ///      beneficiary, a validator payout to this address, or a pre-deployment
    ///      send to the counterfactual address. This owner-only escape hatch
    ///      returns any such stranded ETH.
    /// @custom:category Admin
    function rescueBalance() external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance == 0) {
            revert NothingToRescue();
        }
        Address.sendValue(payable(owner()), balance);
    }

    // --- ERC-165 -------------------------------------------------------------

    /// @notice ERC-165 interface detection. Returns true for ERC-721 (and its
    ///         metadata), EIP-2981, ERC-4906, ERC-165 itself, the ERC-721C
    ///         creator-token surface ({ICreatorToken}), and the
    ///         transformation-approval surface ({ITalismanTransformable}).
    /// @dev Advertises ERC-4906 (`0x49064906`), {ICreatorToken} and its legacy
    ///      id (so royalty-enforcing marketplaces recognise the collection), and
    ///      {ITalismanTransformable} alongside the inherited sets; `super` chains
    ///      through {ERC2981} and {ERC721} down to ERC-165.
    /// @param interfaceId The ERC-165 interface identifier to query.
    /// @return True if the interface is supported.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721, ERC2981, IERC165)
        returns (bool)
    {
        return interfaceId == bytes4(0x49064906) || interfaceId == type(ITalismanTransformable).interfaceId
            || interfaceId == type(ICreatorToken).interfaceId || interfaceId == type(ICreatorTokenLegacy).interfaceId
            || super.supportsInterface(interfaceId);
    }

    // --- Minter interface ----------------------------------------------------

    /// @notice Mint a genesis Talisman to `to` and assign its future
    ///         reveal-commitment block. Callable only by the {minter}. The
    ///         token's cores are unknown until {reveal}; it takes the next id in
    ///         the genesis sequence (1..{MAX_GENESIS_SUPPLY}).
    /// @dev Public-sale hot path - kept gas-tight. ERC-721 Transfer and the
    ///      {commitBlockOf} view supply everything indexers need, so no
    ///      commitment event is emitted. Trust assumption: callers reach this
    ///      only through the trusted {minter}, which is owner-controlled (see
    ///      {setMinter}) and is expected to guard its own user-facing entry
    ///      points against reentrancy. Because of that, this function relies on
    ///      checks-effects-interactions alone (state writes happen before
    ///      `_safeMint`'s external callback) and pays for no reentrancy guard on
    ///      the hot path.
    /// @param to The recipient of the freshly minted genesis token.
    /// @return tokenId The id assigned from the genesis sequence.
    /// @return commitBlock The block whose hash will seed the token's {reveal}.
    function mintWithCommitment(address to) external onlyMinter returns (uint256 tokenId, uint256 commitBlock) {
        if (_genesisMinted >= MAX_GENESIS_SUPPLY) {
            revert GenesisMintExhausted();
        }
        // Genesis ids are the genesis count itself: 1..{MAX_GENESIS_SUPPLY}.
        tokenId = ++_genesisMinted;
        commitBlock = block.number + REVEAL_DELAY;
        _commitBlock[tokenId] = commitBlock;
        _safeMint(to, tokenId);
    }

    // --- Reveal (permissionless) ---------------------------------------------

    /// @notice Finalise a pending Talisman, drawing its cores and revealing its
    ///         art. Anyone may call.
    /// @dev Randomness is the blockhash of the token's commit block combined
    ///      with the tokenId - valid only within the 256-block window after the
    ///      commit block. Gas-sensitive (anyone-pays); reveal state is
    ///      observable via {isRevealed}/{coresOf}, so no event beyond ERC-4906
    ///      is emitted. The seed is fixed once the commit block is mined, so a
    ///      permissionless re-call always yields the same cores: a caller cannot
    ///      grind the outcome by retrying across blocks. The one residual is the
    ///      standard blockhash-reveal trade-off - the commit-block proposer can
    ///      bias their own blockhash, but only as the validator of that exact
    ///      slot, single-shot, and only partially: an accepted limitation, not
    ///      the cheap reveal-time grinding that reading a reveal-block value
    ///      would have allowed.
    /// @param tokenId The pending token to finalise.
    /// @custom:category Reveal
    function reveal(uint256 tokenId) external {
        _reveal(tokenId);
    }

    /// @notice Reveal many pending Talismans in one call. The batch is atomic -
    ///         if any id is not pending (never minted or already revealed) or
    ///         falls outside its reveal window, the whole call reverts and
    ///         nothing is revealed.
    /// @dev Thin wrapper running {reveal}'s shared core per id, so each token
    ///      follows the exact same rules as a single {reveal}. Gas-sensitive
    ///      (anyone-pays); cost scales with `tokenIds.length`, which the caller
    ///      bounds - an over-large array simply runs out of gas.
    /// @param tokenIds The pending tokens to finalise; the whole batch reverts
    ///        if any id is not revealable.
    /// @custom:category Reveal
    function batchReveal(uint256[] calldata tokenIds) external {
        uint256 len = tokenIds.length;
        for (uint256 i; i < len; ++i) {
            _reveal(tokenIds[i]);
        }
    }

    /// @dev Shared reveal core for {reveal} and {batchReveal}. Reverts
    ///      {NothingToReveal} when `tokenId` has no pending commit - the case for
    ///      a never-minted id AND for an already-revealed one ({reveal} deletes
    ///      the commit block on success), so a double-reveal can never silently
    ///      no-op.
    function _reveal(uint256 tokenId) internal {
        uint256 commitBlock = _commitBlock[tokenId];
        if (commitBlock == 0) {
            revert NothingToReveal(tokenId);
        }
        if (block.number <= commitBlock) {
            revert RevealTooEarly(tokenId, commitBlock);
        }
        bytes32 commitHash = blockhash(commitBlock);
        if (commitHash == bytes32(0)) {
            revert RevealUnavailable(tokenId, commitBlock);
        }

        uint256 randomness = uint256(keccak256(abi.encode(commitHash, tokenId)));
        uint256 cores = _pickCoreCount(randomness);

        // Every core in a talisman shares the same material and shape form, but
        // carries its own seed so no two cores are byte-identical. Material and
        // form are drawn once, outside the loop; only the per-core seed is
        // rehashed per index.
        uint8 mid = _pickCoreMaterial(randomness);
        uint8 form = uint8(_pickCoreShape(randomness));

        // Build into memory first so we can key the cores sequence, then commit
        // both the cores and the id<->cores mapping in one shot. Genesis seeds
        // derive from `tokenId`, so each genesis token's cores are unique and
        // its key never collides with another's.
        uint256[] memory built = new uint256[](cores);
        for (uint256 i; i < cores; ++i) {
            built[i] = TalismanCore.pack(mid, form, _pickCoreSeed(randomness, i));
        }
        _cores[tokenId] = built;
        _tokenIdForCores[TalismanTransformationLib.coreKey(built)] = tokenId;
        delete _commitBlock[tokenId];

        // ERC-4906: tokenURI flips from the empty pre-reveal placeholder to
        // full image + animation + traits - marketplaces need this signal
        // to invalidate their cached metadata.
        emit MetadataUpdate(tokenId);
    }

    /// @notice Re-arm a Talisman whose reveal window lapsed - i.e. whose commit
    ///         block fell out of the 256-block blockhash window - by assigning a
    ///         fresh future commit block so {reveal} can succeed again. Anyone
    ///         may call.
    /// @dev Only permitted once the original blockhash is unavailable, so
    ///      callers cannot pre-empt a reveal that would still work.
    ///      Gas-sensitive (anyone-pays); the new commit block is visible via
    ///      {commitBlockOf}, so no event is emitted. Reverts {CommitStillFresh}
    ///      while the window is still open, and {NothingToReveal} when there is
    ///      no pending commit.
    /// @param tokenId The pending token whose commit window has lapsed.
    /// @custom:category Reveal
    function recommit(uint256 tokenId) external {
        uint256 commitBlock = _commitBlock[tokenId];
        if (commitBlock == 0) {
            revert NothingToReveal(tokenId);
        }
        if (block.number <= commitBlock || blockhash(commitBlock) != bytes32(0)) {
            revert CommitStillFresh(tokenId, commitBlock);
        }
        _commitBlock[tokenId] = block.number + REVEAL_DELAY;
    }

    // --- Transformation approval --------------------------------------------
    //
    // A standalone operator-delegation surface, decoupled from ERC-721 transfer
    // approval: an ERC-721 operator cannot transform, and a transformation
    // operator cannot transfer or receive. So listing on a marketplace never
    // confers reshape power, and authorising a batch-transform helper never
    // confers the power to move tokens - every transformation mints its outputs
    // to the owner.

    /// @notice Grant or revoke `operator` the right to run transformations
    ///         ({bond}/{cleave}/{cut}/{merge}) on all of the caller's tokens.
    ///         Independent of ERC-721 transfer approval ({setApprovalForAll}): a
    ///         transformation operator can reshape the caller's tokens but can
    ///         never transfer or receive them.
    /// @param operator The address being authorised for transformations.
    /// @param approved True to grant the right, false to revoke it.
    /// @dev Emits {TransformationApprovalForAll}. The transformation analogue of
    ///      ERC-721's {setApprovalForAll}.
    /// @custom:category Transformable
    function setTransformationApprovalForAll(address operator, bool approved) external override {
        _transformationApprovalForAll[msg.sender][operator] = approved;
        emit TransformationApprovalForAll(msg.sender, operator, approved);
    }

    /// @notice Whether `operator` may run transformations on all of `owner`'s
    ///         tokens.
    /// @dev Distinct from {isApprovedForAll}: an ERC-721 transfer approval never
    ///      satisfies this, nor the reverse.
    /// @param owner The token holder.
    /// @param operator The address queried for transformation rights.
    /// @return True if `operator` may transform `owner`'s tokens.
    /// @custom:category Transformable
    function isTransformationApprovedForAll(address owner, address operator) external view override returns (bool) {
        return _transformationApprovalForAll[owner][operator];
    }

    // Authorise `operator` to transform `owner`'s `tokenId`. Passes for the
    // owner or a {setTransformationApprovalForAll} operator; an ERC-721 transfer
    // approval never satisfies it. Reverts {TransformationInsufficientApproval}
    // otherwise. The transformation analogue of OZ's `_checkAuthorized`.
    function _checkTransformAuthorized(address owner, address operator, uint256 tokenId) internal view {
        if (operator != owner && !_transformationApprovalForAll[owner][operator]) {
            revert TransformationInsufficientApproval(operator, tokenId);
        }
    }

    // --- Transformations ------------------------------------------------------
    //
    // Every transformation BURNS its inputs and MINTS its outputs. An output's
    // id is resolved through {_resolveTokenId} on the *ordered* core sequence,
    // so the same sequence always (re)mints the same id - a transformation is a
    // pure function from input cores to output ids. A freshly resolved key has
    // negligible collision probability with any live token's key; and if one
    // ever did collide, `_safeMint` reverts (OZ rejects an already-minted id)
    // and the whole transformation unwinds - the worst case is a safe revert,
    // never a double-mint or a live-state overwrite. CEI: all cores/mapping/burn
    // state is finalised before any `_safeMint` callback fires, so a reentrant
    // call observes consistent state.

    /// @notice Bond two opposite-pole, equal-count Talismans into a single
    ///         Mythic. `tokenIdA`'s cores lead and `tokenIdB`'s follow, so
    ///         `bond(A,B)` differs from `bond(B,A)`. Both inputs are burned and
    ///         the Mythic is minted to their owner. The caller must be the owner
    ///         or an approved transformation operator
    ///         ({setTransformationApprovalForAll}) on both inputs, and both
    ///         inputs must share one owner - an operator can run the bond, but
    ///         the Mythic lands with the owner, never the operator.
    /// @param tokenIdA The first input; its cores lead the bonded sequence.
    /// @param tokenIdB The opposite-pole input; its cores are appended.
    /// @return bondedId The id of the minted Mythic.
    /// @custom:category Transformable
    function bond(uint256 tokenIdA, uint256 tokenIdB) external returns (uint256 bondedId) {
        _requireBondCleaveEnabled();
        if (tokenIdA == tokenIdB) {
            revert CannotBondSameToken(tokenIdA);
        }
        address owner = _requireOwned(tokenIdA);
        _checkTransformAuthorized(owner, msg.sender, tokenIdA);
        address ownerB = _requireOwned(tokenIdB);
        _checkTransformAuthorized(ownerB, msg.sender, tokenIdB);
        if (ownerB != owner) {
            revert BondRequiresSameOwner(tokenIdA, tokenIdB);
        }

        uint256[] memory combined = TalismanTransformationLib.bondCores(
            materials, tokenIdA, tokenIdB, _cores[tokenIdA], _cores[tokenIdB], MAX_CORES_PER_TOKEN
        );

        bondedId = _resolveTokenId(combined);
        _cores[bondedId] = combined;

        delete _cores[tokenIdA];
        delete _cores[tokenIdB];
        _burn(tokenIdA);
        _burn(tokenIdB);

        _safeMint(owner, bondedId);
        emit Bonded(tokenIdA, tokenIdB, bondedId, msg.sender);
    }

    /// @notice Cleave a Mythic back into its two poles - the inverse of {bond}.
    ///         Splits the cores by essence (Lithic cores in order, then Lumic
    ///         cores in order), burns the Mythic, and mints both halves to its
    ///         owner. Reverts {TokenNotCleavable} unless the token is a Mythic.
    /// @dev Because ids are resolved from cores, a bond->cleave round-trip
    ///      restores exactly the two original ids. See
    ///      {TalismanTransformationLib} for the self-enforcing split.
    /// @param tokenId The Mythic to split.
    /// @return lithicId The id of the minted Lithic half.
    /// @return lumicId The id of the minted Lumic half.
    /// @custom:category Transformable
    function cleave(uint256 tokenId) external returns (uint256 lithicId, uint256 lumicId) {
        _requireBondCleaveEnabled();
        address owner = _requireOwned(tokenId);
        _checkTransformAuthorized(owner, msg.sender, tokenId);

        // Partition by essence, preserving each pole's internal order so the
        // recovered tokens match their pre-bond cores exactly - see
        // {TalismanTransformationLib.cleaveCores} for the self-enforcing split.
        (uint256[] memory lithicCores, uint256[] memory lumicCores) =
            TalismanTransformationLib.cleaveCores(materials, tokenId, _cores[tokenId]);

        lithicId = _resolveTokenId(lithicCores);
        lumicId = _resolveTokenId(lumicCores);

        delete _cores[tokenId];
        _burn(tokenId);

        _cores[lithicId] = lithicCores;
        _cores[lumicId] = lumicCores;

        _safeMint(owner, lithicId);
        _safeMint(owner, lumicId);
        emit Cleaved(tokenId, lithicId, lumicId, msg.sender);
    }

    /// @notice Cut a homogeneous Talisman at `index` into a head (cores
    ///         `[0, index)`) and a tail (cores `[index, len)`). The token must
    ///         be revealed with every core sharing the same material AND form -
    ///         which also rejects Mythics, since they span two materials. Both
    ///         halves mint to the token's owner.
    /// @dev A cut->merge round-trip restores the original id.
    /// @param tokenId The homogeneous token to split.
    /// @param index The split point; head takes cores `[0, index)`, tail the
    ///        rest. Must satisfy `1 <= index < coreCount`.
    /// @return headId The id of the minted head.
    /// @return tailId The id of the minted tail.
    /// @custom:category Transformable
    function cut(uint256 tokenId, uint256 index) external returns (uint256 headId, uint256 tailId) {
        _requireCutMergeEnabled();
        address owner = _requireOwned(tokenId);
        _checkTransformAuthorized(owner, msg.sender, tokenId);

        (uint256[] memory head, uint256[] memory tail) =
            TalismanTransformationLib.cutCores(materials, tokenId, index, _cores[tokenId]);

        headId = _resolveTokenId(head);
        tailId = _resolveTokenId(tail);

        delete _cores[tokenId];
        _burn(tokenId);

        _cores[headId] = head;
        _cores[tailId] = tail;

        _safeMint(owner, headId);
        _safeMint(owner, tailId);
        emit Cut(tokenId, headId, tailId, index, msg.sender);
    }

    /// @notice Merge two same-kind non-Mythic Talismans into one - the inverse
    ///         of {cut}. Both must be revealed, share derived material AND form,
    ///         and their combined core count must stay within the pure-tier
    ///         ceiling ({MAX_CORES_PER_MINT}). `tokenIdA`'s cores lead; both
    ///         inputs burn and the merged token mints to their owner. The caller
    ///         must be the owner or an approved transformation operator
    ///         ({setTransformationApprovalForAll}) on both inputs, and both
    ///         inputs must share one owner - an operator can run the merge, but
    ///         the result lands with the owner, never the operator.
    /// @param tokenIdA The first input; its cores lead the merged sequence.
    /// @param tokenIdB The same-kind input; its cores are appended.
    /// @return mergedId The id of the minted token.
    /// @custom:category Transformable
    function merge(uint256 tokenIdA, uint256 tokenIdB) external returns (uint256 mergedId) {
        _requireCutMergeEnabled();
        if (tokenIdA == tokenIdB) {
            revert CannotMergeSameToken(tokenIdA);
        }
        address owner = _requireOwned(tokenIdA);
        _checkTransformAuthorized(owner, msg.sender, tokenIdA);
        address ownerB = _requireOwned(tokenIdB);
        _checkTransformAuthorized(ownerB, msg.sender, tokenIdB);
        if (ownerB != owner) {
            revert MergeRequiresSameOwner(tokenIdA, tokenIdB);
        }

        uint256[] memory combined = TalismanTransformationLib.mergeCores(
            materials, tokenIdA, tokenIdB, _cores[tokenIdA], _cores[tokenIdB], MAX_CORES_PER_MINT
        );
        mergedId = _resolveTokenId(combined);
        _cores[mergedId] = combined;

        delete _cores[tokenIdA];
        delete _cores[tokenIdB];
        _burn(tokenIdA);
        _burn(tokenIdB);

        _safeMint(owner, mergedId);
        emit Merged(tokenIdA, tokenIdB, mergedId, msg.sender);
    }

    // --- Internal ------------------------------------------------------------

    function _requireBondCleaveEnabled() internal view {
        if (!bondAndCleaveEnabled) {
            revert TransformationDisabled();
        }
    }

    function _requireCutMergeEnabled() internal view {
        if (!cutAndMergeEnabled) {
            revert TransformationDisabled();
        }
    }

    /// @dev Mutating id resolver for transformation outputs: returns the recorded
    ///      id for this exact ordered sequence, or claims a fresh transform id
    ///      from {_nextTransformId} and records it. A recorded sequence may map
    ///      back to a genesis id (e.g. a cleave reversing a bond) - only genuinely
    ///      new sequences draw from the transform range.
    function _resolveTokenId(uint256[] memory cores) internal returns (uint256 id) {
        bytes32 key = TalismanTransformationLib.coreKey(cores);
        id = _tokenIdForCores[key];
        if (id == 0) {
            id = _nextTransformId++;
            _tokenIdForCores[key] = id;
        }
    }

    function _pickCoreCount(uint256 randomness) internal pure returns (uint256) {
        uint256[MAX_CORES_PER_MINT] memory weights = _coreRarityWeights();
        uint256 total;
        for (uint256 i; i < MAX_CORES_PER_MINT; ++i) {
            total += weights[i];
        }
        uint256 r = randomness % total;
        uint256 acc;
        for (uint256 i; i < MAX_CORES_PER_MINT; ++i) {
            acc += weights[i];
            if (r < acc) {
                return i + 1;
            }
        }
        return MAX_CORES_PER_MINT;
    }

    /// @dev Draws a genesis core's material uniformly across the 32 non-mythic
    ///      materials. Uniform is the intended distribution, not a stopgap:
    ///      every material is equally likely to mint, and the core count
    ///      ({_coreRarityWeights}) is the sole rarity axis. Mythic materials
    ///      are never minted - they are reached only by {bond} synthesis.
    function _pickCoreMaterial(uint256 randomness) internal pure returns (uint8) {
        uint256 r = uint256(keccak256(abi.encode(randomness, "material")));
        return uint8(r % NON_MYTHIC_MATERIAL_COUNT);
    }

    /// @dev Draws a genesis core's form uniformly across the 14
    ///      {TalismanForms.ShapeForm} values. Uniform is intended: form is a
    ///      flat identity axis, not a rarity tier - every cut is equally likely,
    ///      and core count alone ({_coreRarityWeights}) carries rarity.
    function _pickCoreShape(uint256 randomness) internal pure returns (TalismanForms.ShapeForm) {
        uint256 r = uint256(keccak256(abi.encode(randomness, "shape")));
        return TalismanForms.ShapeForm(uint8(r % TalismanForms.SHAPE_FORM_COUNT));
    }

    /// @dev Uniform draw of a core's 16-bit shape randomization seed. Mixed with
    ///      the core's `index` so every core in a token draws an independent
    ///      seed while material and shape form stay shared. The seed drives the
    ///      renderer's perturbation and color-region draws; shape form is a
    ///      separate field on the core, not derived from this seed.
    function _pickCoreSeed(uint256 randomness, uint256 index) internal pure returns (uint16) {
        return uint16(uint256(keccak256(abi.encode(randomness, index, "seed"))));
    }

    /// @dev Maintains `_totalSupply` and the per-owner enumeration
    ///      ({_ownedTokens}) on every mint, transfer, and burn. Enumeration is
    ///      touched only when ownership actually changes (`from != to`), so a
    ///      same-owner transfer is a no-op there - and burn fully clears the
    ///      token's index entry, so a content-addressed id that is burned and
    ///      later re-minted (a fresh mint, `from == address(0)`) re-enters
    ///      cleanly. Reveal does not flow through here, so its anyone-pays gas is
    ///      untouched. {balanceOf} is read *after* `super._update`, i.e. already
    ///      reflects this op's increment/decrement.
    // {CreatorTokenBase} defers ownership to the token; route it through
    // {Ownable2Step}. Used to gate {setTransferValidator}.
    function _requireCallerIsContractOwner() internal view override {
        _checkOwner();
    }

    // Once enforcement is frozen off ({disableRoyaltyEnforcementForever}), the
    // validator can never be repointed - {setTransferValidator} reverts here.
    function _requireTransferValidatorNotFrozen() internal view override {
        if (royaltyEnforcementFrozen) {
            revert RoyaltyEnforcementFrozen();
        }
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = super._update(to, tokenId, auth);
        // ERC-721C: gate real owner->owner transfers through the active transfer
        // validator, so a sale only settles on a marketplace that honours the
        // royalty. Mints (from == 0) and burns (to == 0) - including the
        // transformation burn/mint - are never gated. A reverting validator
        // unwinds the whole op via this revert.
        if (from != address(0) && to != address(0)) {
            _validateTransfer(_msgSender(), from, to, tokenId);
        }
        if (from == address(0)) {
            _totalSupply++;
        } else if (from != to) {
            _removeTokenFromOwnerEnumeration(from, tokenId);
        }
        if (to == address(0)) {
            _totalSupply--;
        } else if (from != to) {
            _addTokenToOwnerEnumeration(to, tokenId);
        }
    }

    /// @dev Appends `tokenId` to `to`'s index at the slot freed by the balance
    ///      increment `super._update` just applied.
    function _addTokenToOwnerEnumeration(address to, uint256 tokenId) private {
        uint256 index = balanceOf(to) - 1;
        _ownedTokens[to][index] = tokenId;
        _ownedTokensIndex[tokenId] = index;
    }

    /// @dev Swap-and-pop removal of `tokenId` from `from`'s index. `balanceOf` is
    ///      already decremented, so it is the index of the current last element.
    function _removeTokenFromOwnerEnumeration(address from, uint256 tokenId) private {
        uint256 lastIndex = balanceOf(from);
        uint256 tokenIndex = _ownedTokensIndex[tokenId];
        mapping(uint256 index => uint256 tokenId) storage ownerTokens = _ownedTokens[from];
        if (tokenIndex != lastIndex) {
            uint256 lastTokenId = ownerTokens[lastIndex];
            ownerTokens[tokenIndex] = lastTokenId;
            _ownedTokensIndex[lastTokenId] = tokenIndex;
        }
        delete _ownedTokensIndex[tokenId];
        delete ownerTokens[lastIndex];
    }
}
