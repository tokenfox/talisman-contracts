// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Talismans} from "./Talismans.sol";

/// @title TalismanMinter
/// @notice The primary sale for {Talismans}. The owner configures the window
///         and price via {setMintConfig}; buyers call {publicMint} during the
///         window. An optional allowlist runs first: addresses proven against
///         {merkleRoot} call {allowlistMint} from `allowlistStartTime` until the
///         public sale opens. The sale is capped at {Talismans.MAX_GENESIS_SUPPLY}
///         tokens, and each token reveals later via {Talismans} directly. The
///         owner may also claim up to {Talismans.MAX_ARTIST_PROOFS} artist
///         proofs from the first genesis ids via {artistProofMint}, and once the
///         window closes may sweep any unsold remainder to the {Talismans} owner
///         via {concludeMint}.
/// @dev Trust contract with {Talismans}: {Talismans.mintWithCommitment} is
///      `onlyMinter` and intentionally carries no reentrancy guard of its own,
///      on the assumption that the sanctioned minter (this contract) guards its
///      own user-facing entry points. This contract honours that by marking
///      every externally-callable mint/withdraw path `nonReentrant`. Any future
///      user-facing mint function added here MUST also be `nonReentrant`, or the
///      assumption breaks.
contract TalismanMinter is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Thrown when a mint is attempted before the owner has set a sale window.
    error MintNotConfigured();
    /// @notice Thrown by {publicMint} before the public sale opens.
    error MintNotStarted();
    /// @notice Thrown by {publicMint} after the public sale window has closed.
    error MintEnded();
    /// @notice Thrown by {concludeMint} while the public sale window is still open.
    error MintNotEnded();
    /// @notice Thrown when the genesis supply is exhausted.
    error SoldOut();
    /// @notice Thrown when `msg.value` does not cover the required price.
    /// @param sent The value sent with the call.
    /// @param required The price the call had to cover.
    error InsufficientPayment(uint256 sent, uint256 required);
    /// @notice Thrown when a mint quantity is zero or above the caller's allowance.
    error InvalidQuantity();
    /// @notice Thrown by the withdraw paths when there is nothing to sweep.
    error NothingToWithdraw();
    /// @notice Thrown by {artistProofMint} once the artist-proof id range is used up.
    error ArtistProofsExhausted();
    /// @notice Thrown by {allowlistMint} when no allowlist is configured.
    error AllowlistNotConfigured();
    /// @notice Thrown by {allowlistMint} before the allowlist opens.
    error AllowlistNotStarted();
    /// @notice Thrown by {allowlistMint} once the public sale has opened, which closes the allowlist.
    error AllowlistEnded();
    /// @notice Thrown when an address that has already used its allowlist spot calls {allowlistMint} again.
    error AlreadyAllowlistMinted();
    /// @notice Thrown when an address that has already used its public mint calls {publicMint} again.
    error AlreadyPublicMinted();
    /// @notice Thrown by {allowlistMint} when the supplied proof is not in {merkleRoot}.
    error NotAllowlisted();

    /// @notice Emitted when the owner updates the sale configuration.
    /// @param startTime The public-sale opening Unix timestamp.
    /// @param mintLengthMins The public-sale duration in minutes.
    /// @param mintPrice The public price per token, in wei.
    /// @param allowlistStartTime The allowlist opening Unix timestamp.
    /// @param allowlistPrice The allowlist price per token, in wei.
    /// @param allowlistMaxMints The tokens a single allowlist spot may claim.
    event MintConfigUpdated(
        uint256 startTime,
        uint256 mintLengthMins,
        uint256 mintPrice,
        uint256 allowlistStartTime,
        uint256 allowlistPrice,
        uint256 allowlistMaxMints
    );
    /// @notice Emitted when the owner sets the allowlist Merkle root.
    /// @param merkleRoot The new allowlist root; 0 disables the allowlist.
    event MerkleRootUpdated(bytes32 merkleRoot);

    struct MintConfig {
        uint256 startTime;
        uint256 mintLengthMins;
        uint256 mintPrice;
        uint256 allowlistStartTime;
        uint256 allowlistPrice;
        uint256 allowlistMaxMints;
    }

    /// @notice The tokens minted by a single {publicMint} call: one. The public
    ///         sale is one mint per wallet, enforced by {publicMinted}.
    /// @dev Exposed so integrators read the public allotment from state rather
    ///      than decoding calldata; keep in sync with {publicMint} if ever
    ///      changed. Neither this nor the per-wallet cap is sybil-proof - a
    ///      determined accumulator splits across wallets - so price and the
    ///      curated allowlist remain the real distribution levers.
    uint256 public constant MAX_MINTS_PER_CALL = 1;

    Talismans public immutable talismans;
    MintConfig public mintConfig;

    /// @notice The Merkle root proving allowlist membership. A root of 0 leaves
    ///         the allowlist unset, so {allowlistMint} reverts
    ///         {AllowlistNotConfigured}. Set independently of the sale window via
    ///         {setMerkleRoot}.
    /// @dev Leaf encoding is `keccak256(bytes.concat(keccak256(abi.encode(account))))`,
    ///      the OpenZeppelin `StandardMerkleTree` single-`address` encoding.
    bytes32 public merkleRoot;

    /// @notice Whether an address has already claimed its allowlist spot. The
    ///         allowlist grants a single {allowlistMint} call of up to
    ///         `allowlistMaxMints` tokens; claiming fewer forfeits the remainder.
    mapping(address => bool) public allowlistMinted;

    /// @notice Whether an address has used its single public mint. The public
    ///         sale grants one {publicMint} per address; a second call reverts
    ///         {AlreadyPublicMinted}. Independent of {allowlistMinted} - an
    ///         allowlist claimant may still mint once in the public phase.
    mapping(address => bool) public publicMinted;

    /// @notice Deploys the sale bound to `talismansContract`.
    /// @param talismansContract The {Talismans} token this contract mints into.
    ///        Stored immutably; this contract must be wired as its `minter`.
    constructor(Talismans talismansContract) Ownable(msg.sender) {
        talismans = talismansContract;
    }

    modifier mintOpen() {
        MintConfig memory cfg = mintConfig;
        if (cfg.startTime == 0) {
            revert MintNotConfigured();
        }
        if (block.timestamp < cfg.startTime) {
            revert MintNotStarted();
        }
        if (block.timestamp >= cfg.startTime + cfg.mintLengthMins * 60) {
            revert MintEnded();
        }
        if (talismans.genesisMinted() >= talismans.MAX_GENESIS_SUPPLY()) {
            revert SoldOut();
        }
        _;
    }

    modifier allowlistOpen() {
        MintConfig memory cfg = mintConfig;
        if (cfg.allowlistStartTime == 0 || merkleRoot == bytes32(0)) {
            revert AllowlistNotConfigured();
        }
        if (block.timestamp < cfg.allowlistStartTime) {
            revert AllowlistNotStarted();
        }
        // The allowlist stage runs until the public sale opens; it has no
        // length of its own. A `startTime` of 0 means no public sale is
        // configured yet, so the allowlist stays open until sold out.
        if (cfg.startTime != 0 && block.timestamp >= cfg.startTime) {
            revert AllowlistEnded();
        }
        if (talismans.genesisMinted() >= talismans.MAX_GENESIS_SUPPLY()) {
            revert SoldOut();
        }
        _;
    }

    /// @notice Set the public-sale window and the allowlist. Owner only. A
    ///         `startTime` of 0 leaves the public sale unconfigured, so
    ///         {publicMint} reverts {MintNotConfigured}; an `allowlistStartTime`
    ///         of 0 leaves the allowlist off, so {allowlistMint} reverts
    ///         {AllowlistNotConfigured}.
    /// @param startTime Unix timestamp the public sale opens; 0 leaves it unconfigured.
    /// @param mintLengthMins How long the public sale stays open, in minutes.
    /// @param mintPrice Public price per token, in wei.
    /// @param allowlistStartTime Unix timestamp the allowlist stage opens; 0 leaves it off.
    /// @param allowlistPrice Allowlist price per token, in wei.
    /// @param allowlistMaxMints Tokens a single allowlist spot may claim.
    function setMintConfig(
        uint256 startTime,
        uint256 mintLengthMins,
        uint256 mintPrice,
        uint256 allowlistStartTime,
        uint256 allowlistPrice,
        uint256 allowlistMaxMints
    ) external onlyOwner {
        mintConfig = MintConfig({
            startTime: startTime,
            mintLengthMins: mintLengthMins,
            mintPrice: mintPrice,
            allowlistStartTime: allowlistStartTime,
            allowlistPrice: allowlistPrice,
            allowlistMaxMints: allowlistMaxMints
        });
        emit MintConfigUpdated(
            startTime, mintLengthMins, mintPrice, allowlistStartTime, allowlistPrice, allowlistMaxMints
        );
    }

    /// @notice Set the allowlist {merkleRoot}. Owner only. A root of 0 disables
    ///         the allowlist independently of the configured window.
    /// @param root Merkle root over the eligible addresses; 0 to disable.
    function setMerkleRoot(bytes32 root) external onlyOwner {
        merkleRoot = root;
        emit MerkleRootUpdated(root);
    }

    /// @notice Mint one genesis Talisman to the caller at the public price
    ///         during the open sale window. One mint per wallet - a second call
    ///         from the same address reverts {AlreadyPublicMinted}. `msg.value`
    ///         must cover the public price. The token is minted with a future
    ///         reveal commitment and reveals later via {Talismans} directly.
    /// @dev Public-sale hot path - kept gas-tight. ERC-721 Transfer from
    ///      {Talismans.mintWithCommitment} already signals the mint to indexers,
    ///      so no extra event is emitted here.
    function publicMint() external payable nonReentrant mintOpen {
        if (publicMinted[msg.sender]) {
            revert AlreadyPublicMinted();
        }
        if (msg.value < mintConfig.mintPrice) {
            revert InsufficientPayment(msg.value, mintConfig.mintPrice);
        }
        publicMinted[msg.sender] = true;
        talismans.mintWithCommitment(msg.sender);
    }

    /// @notice Claim an allowlist spot: buy `quantity` genesis Talismans at the
    ///         allowlist price after proving membership with a Merkle `proof`
    ///         against {merkleRoot}. The spot is single-use - claim
    ///         1..`allowlistMaxMints` tokens in this one call; claiming fewer
    ///         forfeits the remainder, and a further call reverts
    ///         {AlreadyAllowlistMinted}. Each token is minted with a future
    ///         reveal commitment and reveals later via {Talismans} directly.
    /// @dev Marked `nonReentrant` per the {Talismans} trust contract - this is a
    ///      user-facing mint path.
    /// @param proof Merkle proof that `msg.sender` is on the allowlist.
    /// @param quantity How many tokens to claim; 1..`allowlistMaxMints`.
    ///        `msg.value` must cover `quantity * allowlistPrice`.
    function allowlistMint(bytes32[] calldata proof, uint256 quantity) external payable nonReentrant allowlistOpen {
        MintConfig memory cfg = mintConfig;
        if (quantity == 0 || quantity > cfg.allowlistMaxMints) {
            revert InvalidQuantity();
        }
        if (allowlistMinted[msg.sender]) {
            revert AlreadyAllowlistMinted();
        }
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender))));
        if (!MerkleProof.verify(proof, merkleRoot, leaf)) {
            revert NotAllowlisted();
        }
        uint256 cost = quantity * cfg.allowlistPrice;
        if (msg.value < cost) {
            revert InsufficientPayment(msg.value, cost);
        }
        if (talismans.genesisMinted() + quantity > talismans.MAX_GENESIS_SUPPLY()) {
            revert SoldOut();
        }
        allowlistMinted[msg.sender] = true;
        for (uint256 i; i < quantity; ++i) {
            talismans.mintWithCommitment(msg.sender);
        }
    }

    /// @notice Mint artist-proof genesis Talismans to the caller (owner). Proofs
    ///         are free, ignore the sale window, and may only occupy the first
    ///         {Talismans.MAX_ARTIST_PROOFS} genesis ids - once genesis has
    ///         advanced past that range the call reverts {ArtistProofsExhausted}.
    ///         Owner only.
    /// @dev No `nonReentrant`: this is `onlyOwner`, so only the trusted owner can
    ///      (re)enter. The {Talismans} trust contract applies to user-facing
    ///      paths; an owner-gated mint is outside it.
    /// @param quantity How many artist proofs to mint to the caller (owner).
    function artistProofMint(uint256 quantity) external onlyOwner {
        _artistProofMint(quantity, msg.sender);
    }

    /// @notice Mint artist-proof genesis Talismans to `to`. Owner only;
    ///         otherwise identical to {artistProofMint}.
    /// @param quantity How many artist proofs to mint.
    /// @param to The recipient of the proofs.
    function artistProofMint(uint256 quantity, address to) external onlyOwner {
        _artistProofMint(quantity, to);
    }

    function _artistProofMint(uint256 quantity, address to) private {
        if (quantity == 0) {
            revert InvalidQuantity();
        }
        if (talismans.genesisMinted() + quantity > talismans.MAX_ARTIST_PROOFS()) {
            revert ArtistProofsExhausted();
        }
        for (uint256 i; i < quantity; ++i) {
            talismans.mintWithCommitment(to);
        }
    }

    /// @notice Conclude the genesis sale by minting its unsold remainder to the
    ///         {Talismans} owner. Owner only, and only after the configured
    ///         public sale has closed - no sale configured reverts
    ///         {MintNotConfigured}, a still-open window reverts {MintNotEnded}.
    ///         Mints `min(maxQuantity, remaining)` tokens so a large unsold
    ///         remainder can be swept across transactions; call repeatedly until
    ///         {Talismans.genesisMinted} reaches {Talismans.MAX_GENESIS_SUPPLY}.
    ///         Reverts {SoldOut} once none remain.
    /// @dev No `nonReentrant`: like {artistProofMint} this is `onlyOwner`, so
    ///      only the trusted owner can (re)enter, and {Talismans.mintWithCommitment}
    ///      caps the genesis count regardless.
    /// @param maxQuantity Upper bound on tokens minted this call; the actual
    ///        count is `min(maxQuantity, remaining supply)`.
    function concludeMint(uint256 maxQuantity) external onlyOwner {
        if (maxQuantity == 0) {
            revert InvalidQuantity();
        }
        MintConfig memory cfg = mintConfig;
        if (cfg.startTime == 0) {
            revert MintNotConfigured();
        }
        if (block.timestamp < cfg.startTime + cfg.mintLengthMins * 60) {
            revert MintNotEnded();
        }
        uint256 minted = talismans.genesisMinted();
        uint256 maxSupply = talismans.MAX_GENESIS_SUPPLY();
        if (minted >= maxSupply) {
            revert SoldOut();
        }
        uint256 remaining = maxSupply - minted;
        uint256 quantity = maxQuantity < remaining ? maxQuantity : remaining;
        address recipient = talismans.owner();
        for (uint256 i; i < quantity; ++i) {
            talismans.mintWithCommitment(recipient);
        }
    }

    /// @notice Sweep the full ETH balance to the caller (owner). Owner only;
    ///         reverts {NothingToWithdraw} when the balance is zero.
    function withdraw() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        if (balance == 0) {
            revert NothingToWithdraw();
        }
        Address.sendValue(payable(msg.sender), balance);
    }

    /// @notice Sweep the full balance of `token` to the caller (owner). Owner
    ///         only; reverts {NothingToWithdraw} when the balance is zero.
    /// @param token The ERC-20 to sweep.
    function withdrawErc20(IERC20 token) external onlyOwner nonReentrant {
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) {
            revert NothingToWithdraw();
        }
        token.safeTransfer(msg.sender, balance);
    }

    /// @notice The Unix timestamp when the public sale window closes, or 0 when
    ///         no sale is configured.
    /// @return The sale's closing Unix timestamp, or 0 if unconfigured.
    function mintEndTime() external view returns (uint256) {
        MintConfig memory cfg = mintConfig;
        if (cfg.startTime == 0) {
            return 0;
        }
        return cfg.startTime + cfg.mintLengthMins * 60;
    }
}
