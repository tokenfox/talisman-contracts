// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICreatorToken, ITransferValidator} from "./ICreatorToken.sol";

/// @title CreatorTokenBase
/// @notice ERC-721C transfer-validator plumbing, ported to OpenZeppelin 5.
///         Holds the active transfer validator, exposes the {ICreatorToken}
///         surface marketplaces read to recognise the collection as
///         royalty-enforcing, and gates transfers through the validator so a
///         sale only settles on a marketplace that honours the royalty.
/// @dev Limit Break's own ERC-721C hangs its validation off OpenZeppelin 4's
///      `_beforeTokenTransfer`, which OpenZeppelin 5 removed in favour of a
///      single `_update`. This base carries the same logic and the same
///      canonical validator, leaving the OpenZeppelin-5 token to call
///      {_validateTransfer} from its `_update`. Ownership and any freeze are
///      deferred to the inheriting contract via the two `_require*` hooks.
abstract contract CreatorTokenBase is ICreatorToken {
    /// @notice Thrown by {setTransferValidator} when the given address is
    ///         neither the zero address nor a deployed contract.
    error InvalidTransferValidatorContract();

    /// @notice The transfer validator a collection uses until its owner sets
    ///         another - Limit Break's canonical, chain-wide validator. Active
    ///         on every chain that validator is deployed to; inert elsewhere.
    address public constant DEFAULT_TRANSFER_VALIDATOR = 0x721C008fdff27BF06E7E123956E2Fe03B63342e3;

    /// @dev False until {setTransferValidator} (or the inheriting contract's
    ///      internal {_setTransferValidator}) runs once, after which
    ///      {getTransferValidator} reports `_transferValidator` verbatim - even
    ///      when that is the zero address - instead of falling back to the
    ///      default. This is what lets enforcement be switched fully off.
    bool private _validatorInitialized;
    address private _transferValidator;

    constructor() {
        // Signal the default validator at deploy, mirroring ERC-721C, so an
        // indexer reads the enforcing validator from the first block.
        emit TransferValidatorUpdated(address(0), DEFAULT_TRANSFER_VALIDATOR);
    }

    /// @notice The transfer validator currently gating this collection's
    ///         transfers. Reports {DEFAULT_TRANSFER_VALIDATOR} until a validator
    ///         is set, then whatever was set - including the zero address, which
    ///         means enforcement is off.
    /// @return validator The active transfer validator.
    function getTransferValidator() public view override returns (address validator) {
        validator = _transferValidator;
        if (validator == address(0) && !_validatorInitialized) {
            validator = DEFAULT_TRANSFER_VALIDATOR;
        }
    }

    /// @notice Point the collection at a new transfer validator. Restricted to
    ///         the contract owner.
    /// @param validator The validator to activate; the zero address disables
    ///        enforcement. A non-zero address must be a deployed contract.
    function setTransferValidator(address validator) external override {
        _requireCallerIsContractOwner();
        _requireTransferValidatorNotFrozen();
        _setTransferValidator(validator);
    }

    /// @notice The validator function a transfer simulation calls - the ERC-721C
    ///         `validateTransfer(address,address,address,uint256)` view.
    /// @return functionSignature The validator selector to simulate against.
    /// @return isViewFunction Always true; the validation is a view call.
    function getTransferValidationFunction()
        external
        pure
        override
        returns (bytes4 functionSignature, bool isViewFunction)
    {
        functionSignature = ITransferValidator.validateTransfer.selector;
        isViewFunction = true;
    }

    /// @dev Set the validator without the owner / freeze guards - the shared
    ///      core of {setTransferValidator} and any owner-side disable path.
    ///      Marks the validator initialized so the default fallback never
    ///      re-applies, which is how a zero validator sticks.
    function _setTransferValidator(address validator) internal {
        if (validator != address(0) && validator.code.length == 0) {
            revert InvalidTransferValidatorContract();
        }
        emit TransferValidatorUpdated(getTransferValidator(), validator);
        _validatorInitialized = true;
        _transferValidator = validator;
    }

    /// @dev Gate a transfer through the active validator, reverting if it breaks
    ///      the collection's policy. A no-op when no validator is set or when the
    ///      configured validator has no code on this chain (e.g. a local test
    ///      net, or before the canonical validator is deployed) - so the token
    ///      never bricks on a validator that isn't there. Callers pass real
    ///      transfers only; mints and burns are not gated.
    function _validateTransfer(address caller, address from, address to, uint256 tokenId) internal view {
        address validator = getTransferValidator();
        if (validator != address(0) && validator.code.length > 0) {
            ITransferValidator(validator).validateTransfer(caller, from, to, tokenId);
        }
    }

    /// @dev Revert unless the caller is the contract owner. Supplied by the
    ///      inheriting contract from its own ownership model.
    function _requireCallerIsContractOwner() internal view virtual;

    /// @dev Hook for the inheriting contract to block validator changes once it
    ///      has frozen enforcement. Permissive by default.
    function _requireTransferValidatorNotFrozen() internal view virtual {}
}
