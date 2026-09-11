// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ITalismanTransformable
/// @notice Operator-delegation surface for the transformations
///         ({bond}/{cleave}/{cut}/{merge}). It mirrors ERC-721's
///         {setApprovalForAll}/{isApprovedForAll} pattern, but governs a
///         SEPARATE right: a transformation operator may reshape a holder's
///         tokens yet can never transfer or receive them - every transformation
///         mints its outputs to the owner. A transformation approval and an
///         ERC-721 transfer approval are independent; neither implies the other.
interface ITalismanTransformable {
    /// @notice Emitted when `owner` grants or revokes `operator` the right to
    ///         run transformations on all of the owner's tokens.
    /// @param owner The token holder granting or revoking the right.
    /// @param operator The address whose transformation right changed.
    /// @param approved True when the right is granted, false when revoked.
    event TransformationApprovalForAll(address indexed owner, address indexed operator, bool approved);

    /// @notice Grant or revoke `operator` the right to run transformations
    ///         ({bond}/{cleave}/{cut}/{merge}) on all of the caller's tokens.
    ///         Independent of ERC-721 transfer approval: a transformation
    ///         operator can reshape the caller's tokens but can never transfer
    ///         or receive them.
    /// @param operator The address being authorised for transformations.
    /// @param approved True to grant the right, false to revoke it.
    /// @dev Emits {TransformationApprovalForAll}. The transformation analogue of
    ///      ERC-721's {setApprovalForAll}.
    function setTransformationApprovalForAll(address operator, bool approved) external;

    /// @notice Whether `operator` may run transformations on all of `owner`'s
    ///         tokens.
    /// @param owner The token holder.
    /// @param operator The address queried for transformation rights.
    /// @return True if `operator` may transform `owner`'s tokens.
    /// @dev Distinct from {isApprovedForAll}: an ERC-721 transfer approval never
    ///      satisfies this, nor the reverse.
    function isTransformationApprovedForAll(address owner, address operator) external view returns (bool);
}
