// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Talismans} from "./Talismans.sol";

/// @title TalismanQueueMinter
/// @notice A bot-resistant public-stage minter for {Talismans}. Each sale
///         happens in two transactions: a wallet first calls {queueToMint} to
///         take the next slot in the minting queue, then waits until that
///         slot's block before calling {mint} to settle at the configured
///         price. Slots are filled sequentially starting at
///         `firstMintableBlockNumber`, packing `spotsPerBlock` slots into each
///         block before advancing to the next - so colliding queue requests
///         land in a fair, fixed order. One live queue entry per wallet;
///         minting clears the entry, so a returning buyer must queue again.
///         The owner may {release} a stale entry to free its supply slot,
///         sweep any unsold remainder via {concludeMint} once {mintConfig}'s
///         `mintEndTime` has passed, and pull proceeds via {withdraw} /
///         {withdrawErc20}. New queue entries stop at `mintEndTime`, but a
///         wallet that already holds a live entry may still mint after that
///         point.
/// @dev Trust contract with {Talismans}: {Talismans.mintWithCommitment} is
///      `onlyMinter` and intentionally carries no reentrancy guard of its own,
///      on the assumption that the sanctioned minter (this contract) guards
///      its own user-facing entry points. {mint} and the withdraw paths are
///      therefore `nonReentrant`. Any future user-facing mint function added
///      here MUST also be `nonReentrant`, or the assumption breaks.
contract TalismanQueueMinter is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Thrown when a sale action is attempted before the owner has set a window.
    error MintNotConfigured();
    /// @notice Thrown by {setMintConfig} when the configuration is internally inconsistent: `mintEndTime` not strictly after `startTime`, or `spotsPerBlock` is zero.
    error InvalidMintConfig();
    /// @notice Thrown by {queueToMint} before the sale opens.
    error MintNotStarted();
    /// @notice Thrown by {queueToMint} after the sale has closed. {mint} is unaffected.
    error MintEnded();
    /// @notice Thrown by {concludeMint} while the sale window is still open.
    error MintNotEnded();
    /// @notice Thrown when no genesis slots remain to reserve or sweep.
    error SoldOut();
    /// @notice Thrown by {queueToMint} when the caller already holds a live queue entry.
    error AlreadyQueued();
    /// @notice Thrown by {mint} and {release} when the target wallet has no live queue entry.
    error NotQueued();
    /// @notice Thrown by {mint} when called before the queued eligibility block.
    /// @param current The current block number.
    /// @param eligible The earliest block from which the queue entry may be minted.
    error QueueNotReady(uint256 current, uint256 eligible);
    /// @notice Thrown by {mint} when `msg.value` does not cover {mintConfig}'s `mintPrice`.
    /// @param sent The value sent with the call.
    /// @param required The price the call had to cover.
    error InsufficientPayment(uint256 sent, uint256 required);
    /// @notice Thrown when a quantity argument is zero.
    error InvalidQuantity();
    /// @notice Thrown by the withdraw paths when there is nothing to sweep.
    error NothingToWithdraw();

    /// @notice Emitted when the owner updates the sale window, price, or queue layout.
    /// @param startTime The Unix timestamp the sale opens for new queue entries.
    /// @param mintEndTime The Unix timestamp after which {queueToMint} stops accepting new entries.
    /// @param mintPrice The per-token price, in wei, charged by {mint}.
    /// @param firstMintableBlockNumber The block assigned to slot 0; slot N is assigned to `firstMintableBlockNumber + N / spotsPerBlock`.
    /// @param spotsPerBlock The number of queue slots packed into each block before advancing.
    event MintConfigUpdated(
        uint256 startTime,
        uint256 mintEndTime,
        uint256 mintPrice,
        uint256 firstMintableBlockNumber,
        uint256 spotsPerBlock
    );

    /// @notice Emitted when a wallet claims a slot in the minting queue.
    /// @param wallet The queueing wallet.
    /// @param eligibleBlock The earliest block from which the wallet may {mint}.
    /// @param queueLength The {mintingQueueLength} after this entry.
    event Queued(address indexed wallet, uint256 eligibleBlock, uint256 queueLength);

    /// @notice Emitted when the owner clears a stale queue entry via {release}.
    /// @param wallet The wallet whose queue entry was cleared.
    /// @param eligibleBlock The eligibility block of the cleared entry.
    event Released(address indexed wallet, uint256 eligibleBlock);

    struct MintConfig {
        uint256 startTime;
        uint256 mintEndTime;
        uint256 mintPrice;
        uint256 firstMintableBlockNumber;
        uint256 spotsPerBlock;
    }

    /// @notice The tokens minted by a single {mint} call: one. The sale grants
    ///         one mint per live queue entry, and the entry is cleared on use.
    /// @dev Exposed so integrators read the allotment from state rather than
    ///      decoding calldata; keep in sync with {mint} if ever changed.
    uint256 public constant MAX_MINTS_PER_CALL = 1;

    /// @notice The {Talismans} token this minter mints into. Set once at
    ///         deployment; this contract must be wired as Talismans' `minter`.
    Talismans public immutable talismans;

    /// @notice The active sale configuration. A `startTime` of 0 leaves the
    ///         sale unconfigured, so {queueToMint} reverts {MintNotConfigured}.
    MintConfig public mintConfig;

    /// @notice The number of live queue entries: wallets that have queued but
    ///         neither minted nor been released. Each live entry reserves one
    ///         slot of genesis supply, so further entries are accepted only
    ///         while `genesisMinted + mintingQueueLength` stays below
    ///         {Talismans.MAX_GENESIS_SUPPLY}.
    uint256 public mintingQueueLength;

    /// @notice The total number of slots ever assigned by {queueToMint}.
    ///         Monotonic - never decrements on {mint} or {release}, so a slot
    ///         index, once issued, is never reused. The next slot a
    ///         {queueToMint} call would receive is `totalQueued`; after
    ///         assignment, the counter advances by one.
    uint256 public totalQueued;

    /// @notice The block from which a wallet may {mint}, or 0 when the wallet
    ///         holds no live queue entry. An entry is consumed on a
    ///         successful {mint} or cleared by the owner via {release}.
    mapping(address => uint256) public queueOf;

    /// @notice Deploys the sale bound to `talismansContract`.
    /// @param talismansContract The {Talismans} token this contract mints into.
    constructor(Talismans talismansContract) Ownable(msg.sender) {
        talismans = talismansContract;
    }

    /// @notice Set the sale window, price, and queue layout. Owner only. A
    ///         `startTime` of 0 leaves the sale unconfigured; otherwise
    ///         `mintEndTime` must be strictly greater than `startTime` and
    ///         `spotsPerBlock` must be non-zero. Reconfiguring during a live
    ///         sale does not retroactively change already-assigned eligibility
    ///         blocks - entries already in the queue keep their original
    ///         block; only subsequent {queueToMint} calls use the new layout.
    /// @param startTime Unix timestamp the sale opens for new queue entries; 0 leaves it unconfigured.
    /// @param mintEndTime Unix timestamp after which {queueToMint} stops accepting new entries.
    /// @param mintPrice Per-token price charged by {mint}, in wei.
    /// @param firstMintableBlockNumber The block assigned to slot 0; subsequent slots advance once every `spotsPerBlock` entries.
    /// @param spotsPerBlock The number of queue slots packed into each block before the next block is opened.
    function setMintConfig(
        uint256 startTime,
        uint256 mintEndTime,
        uint256 mintPrice,
        uint256 firstMintableBlockNumber,
        uint256 spotsPerBlock
    ) external onlyOwner {
        if (startTime != 0) {
            if (mintEndTime <= startTime) {
                revert InvalidMintConfig();
            }
            if (spotsPerBlock == 0) {
                revert InvalidMintConfig();
            }
        }
        mintConfig = MintConfig({
            startTime: startTime,
            mintEndTime: mintEndTime,
            mintPrice: mintPrice,
            firstMintableBlockNumber: firstMintableBlockNumber,
            spotsPerBlock: spotsPerBlock
        });
        emit MintConfigUpdated(startTime, mintEndTime, mintPrice, firstMintableBlockNumber, spotsPerBlock);
    }

    /// @notice Take the next slot in the minting queue. The caller may not
    ///         already hold a live queue entry. The slot index is the current
    ///         value of {totalQueued}; the eligibility block is
    ///         `firstMintableBlockNumber + slot / spotsPerBlock`, packing
    ///         `spotsPerBlock` entries into each block before advancing. Until
    ///         that block is reached the slot is reserved and counts against
    ///         {Talismans.MAX_GENESIS_SUPPLY}. When the queue has overtaken
    ///         the head block, late callers receive a slot whose block is
    ///         already in the past - they may {mint} in the same block.
    function queueToMint() external {
        MintConfig memory cfg = mintConfig;
        if (cfg.startTime == 0) {
            revert MintNotConfigured();
        }
        if (block.timestamp < cfg.startTime) {
            revert MintNotStarted();
        }
        if (block.timestamp >= cfg.mintEndTime) {
            revert MintEnded();
        }
        if (queueOf[msg.sender] != 0) {
            revert AlreadyQueued();
        }
        uint256 queueLength = mintingQueueLength;
        if (talismans.genesisMinted() + queueLength >= talismans.MAX_GENESIS_SUPPLY()) {
            revert SoldOut();
        }
        uint256 slot = totalQueued;
        uint256 eligibleBlock = cfg.firstMintableBlockNumber + slot / cfg.spotsPerBlock;
        queueOf[msg.sender] = eligibleBlock;
        totalQueued = slot + 1;
        mintingQueueLength = queueLength + 1;
        emit Queued(msg.sender, eligibleBlock, queueLength + 1);
    }

    /// @notice Settle a live queue entry by minting one genesis Talisman to
    ///         the caller. Reverts {NotQueued} when the caller holds no
    ///         entry, {QueueNotReady} before the queued block, and
    ///         {InsufficientPayment} when `msg.value` is below {mintConfig}'s
    ///         `mintPrice`. The entry is consumed on success - a returning
    ///         buyer must call {queueToMint} again. The mint is allowed past
    ///         `mintEndTime`: only new queue entries stop at the window's close.
    /// @dev Hot path - kept gas-tight. ERC-721 `Transfer` from
    ///      {Talismans.mintWithCommitment} already signals the mint to indexers,
    ///      so no extra event is emitted here.
    function mint() external payable nonReentrant {
        uint256 eligibleBlock = queueOf[msg.sender];
        if (eligibleBlock == 0) {
            revert NotQueued();
        }
        if (block.number < eligibleBlock) {
            revert QueueNotReady(block.number, eligibleBlock);
        }
        uint256 price = mintConfig.mintPrice;
        if (msg.value < price) {
            revert InsufficientPayment(msg.value, price);
        }
        queueOf[msg.sender] = 0;
        mintingQueueLength -= 1;
        talismans.mintWithCommitment(msg.sender);
    }

    /// @notice Clear a wallet's live queue entry and free its supply slot.
    ///         Owner only. Does NOT roll back the slot index - already-assigned
    ///         later entries keep their blocks, and a new {queueToMint} still
    ///         consumes a fresh slot index. Use to recover supply held by a
    ///         wallet that queued but never minted; the released wallet must
    ///         call {queueToMint} again to mint.
    /// @param wallet The wallet whose queue entry to clear.
    function release(address wallet) external onlyOwner {
        uint256 eligibleBlock = queueOf[wallet];
        if (eligibleBlock == 0) {
            revert NotQueued();
        }
        queueOf[wallet] = 0;
        mintingQueueLength -= 1;
        emit Released(wallet, eligibleBlock);
    }

    /// @notice Mint up to `maxQuantity` of the unsold remainder to the
    ///         {Talismans} owner. Owner only, and only after `mintEndTime`.
    ///         Live queue entries keep their reserved slots - the sweep takes
    ///         only supply that is neither minted nor queued. Call repeatedly
    ///         until {Talismans.genesisMinted} reaches
    ///         {Talismans.MAX_GENESIS_SUPPLY}; reverts {SoldOut} once none
    ///         remain to sweep.
    /// @param maxQuantity Upper bound on tokens minted this call; the actual
    ///        count is `min(maxQuantity, available)`.
    function concludeMint(uint256 maxQuantity) external onlyOwner nonReentrant {
        if (maxQuantity == 0) {
            revert InvalidQuantity();
        }
        MintConfig memory cfg = mintConfig;
        if (cfg.startTime == 0) {
            revert MintNotConfigured();
        }
        if (block.timestamp < cfg.mintEndTime) {
            revert MintNotEnded();
        }
        uint256 minted = talismans.genesisMinted();
        uint256 maxSupply = talismans.MAX_GENESIS_SUPPLY();
        uint256 reserved = minted + mintingQueueLength;
        if (reserved >= maxSupply) {
            revert SoldOut();
        }
        uint256 available = maxSupply - reserved;
        uint256 quantity = maxQuantity < available ? maxQuantity : available;
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

    /// @notice The eligibility block a fresh {queueToMint} call would receive
    ///         in this transaction. Equals
    ///         `firstMintableBlockNumber + totalQueued / spotsPerBlock`, so
    ///         the value can sit in the past once the queue has overtaken the
    ///         head block - a wallet queueing then can {mint} in the same
    ///         block. Reverts {MintNotConfigured} when no sale is configured.
    /// @return The block a new queue entry would be assigned, given current state.
    function nextAvailableBlock() external view returns (uint256) {
        MintConfig memory cfg = mintConfig;
        if (cfg.startTime == 0) {
            revert MintNotConfigured();
        }
        return cfg.firstMintableBlockNumber + totalQueued / cfg.spotsPerBlock;
    }
}
