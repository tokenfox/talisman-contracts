// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TalismanForms} from "./TalismanForms.sol";

/// @notice A read-only snapshot of a (possibly hypothetical) token's full
///         derived state plus its rendered art. Returned by the `simulate*`
///         previews so a frontend can show the before/after of a transformation
///         without sending a transaction.
/// @dev `image`/`html` are raw markup (an `<svg ...>` document / an HTML
///      document), not base64 `data:` URIs - the frontend embeds them directly.
///      `tokenId` is the recorded id when the cores sequence is already known,
///      else the id the next mint would assign.
struct TokenState {
    uint256 tokenId;
    uint256[] cores;
    uint8 materialId;
    TalismanForms.ShapeForm form;
    uint8 coreCount;
    uint16 seed;
    string image;
    string html;
}

/// @title ITalismanTransformationSimulator
/// @notice Read-only previews of the four transformations. Each function
///         predicts the exact outcome of its matching transformation - the
///         output tokens, their derived state, and their rendered art - without
///         sending a transaction, and reverts with the same error a real
///         transformation would when the inputs are invalid.
/// @dev Each preview applies the same validity guards (and reverts with the
///      same error selectors) as its real op, but skips the enabled-gate and
///      skips authorization, so a frontend can preview an op - including why it
///      would fail - via `eth_call` with no sender.
interface ITalismanTransformationSimulator {
    /// @notice Preview bonding `a` and `b`: the Mythic they would bond into.
    /// @param a The first input; its cores would lead the bonded sequence.
    /// @param b The opposite-pole input; its cores would be appended.
    /// @return result The predicted Mythic's derived state and rendered art.
    function simulateBond(uint256 a, uint256 b) external view returns (TokenState memory result);

    /// @notice Preview cleaving `tokenId`: the Lithic and Lumic halves it would
    ///         split into.
    /// @param tokenId The Mythic to preview cleaving.
    /// @return lithic The predicted Lithic half.
    /// @return lumic The predicted Lumic half.
    function simulateCleave(uint256 tokenId) external view returns (TokenState memory lithic, TokenState memory lumic);

    /// @notice Preview cutting `tokenId` at `index`: the head and tail it would
    ///         split into.
    /// @param tokenId The token to preview cutting.
    /// @param index The split point; head takes cores `[0, index)`, tail the rest.
    /// @return head The predicted head.
    /// @return tail The predicted tail.
    function simulateCut(uint256 tokenId, uint256 index)
        external
        view
        returns (TokenState memory head, TokenState memory tail);

    /// @notice Preview merging `a` and `b`: the token they would merge into.
    /// @param a The first input; its cores would lead the merged sequence.
    /// @param b The same-kind input; its cores would be appended.
    /// @return result The predicted token's derived state and rendered art.
    function simulateMerge(uint256 a, uint256 b) external view returns (TokenState memory result);
}
