// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ERC-721C creator-token surface, transcribed verbatim from Limit Break's
// creator-token-standards so the interface ids match byte-for-byte - that is
// what marketplaces (OpenSea, Magic Eden) probe for to recognise a collection
// as royalty-enforcing. Limit Break's own contracts are written against
// OpenZeppelin 4 (the `_beforeTokenTransfer` hook); these are plain interfaces,
// version-independent, so they pair cleanly with an OpenZeppelin 5 token.

/// @notice The ERC-721C creator-token interface: lets a collection point at an
///         external transfer validator that gates secondary transfers, so a
///         sale only settles on a marketplace that honours the royalty.
interface ICreatorToken {
    /// @notice Emitted when the active transfer validator changes.
    /// @param oldValidator The validator before the change.
    /// @param newValidator The validator after the change.
    event TransferValidatorUpdated(address oldValidator, address newValidator);

    /// @notice The transfer validator currently gating this collection's
    ///         transfers, or the zero address when enforcement is off.
    /// @return validator The active transfer validator.
    function getTransferValidator() external view returns (address validator);

    /// @notice Point the collection at a new transfer validator.
    /// @param validator The validator to activate; the zero address disables
    ///        enforcement.
    function setTransferValidator(address validator) external;

    /// @notice The validator function a transfer simulation should call, and
    ///         whether it is a view call.
    /// @return functionSignature The validator selector to simulate against.
    /// @return isViewFunction True when that function is a view call.
    function getTransferValidationFunction() external view returns (bytes4 functionSignature, bool isViewFunction);
}

/// @notice The pre-V2 creator-token interface. Some marketplaces still probe
///         this id, so it is advertised alongside {ICreatorToken}.
interface ICreatorTokenLegacy {
    /// @notice Emitted when the active transfer validator changes.
    /// @param oldValidator The validator before the change.
    /// @param newValidator The validator after the change.
    event TransferValidatorUpdated(address oldValidator, address newValidator);

    /// @notice The transfer validator currently gating this collection's transfers.
    /// @return validator The active transfer validator.
    function getTransferValidator() external view returns (address validator);

    /// @notice Point the collection at a new transfer validator.
    /// @param validator The validator to activate.
    function setTransferValidator(address validator) external;
}

/// @notice The slice of the transfer validator a creator token calls: the
///         per-transfer policy check. Reverts when the transfer breaks the
///         collection's security policy.
interface ITransferValidator {
    /// @notice Revert if moving `tokenId` from `from` to `to`, initiated by
    ///         `caller`, breaks the collection's transfer policy.
    /// @param caller The operator initiating the transfer.
    /// @param from The current owner.
    /// @param to The recipient.
    /// @param tokenId The token being moved.
    function validateTransfer(address caller, address from, address to, uint256 tokenId) external view;
}
