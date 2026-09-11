// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ITransferValidator} from "../../src/ICreatorToken.sol";

/// @dev Stand-in for Limit Break's on-chain transfer validator. The canonical
///      validator has no code on a local chain, so enforcement tests point the
///      token at this instead. Blocks every transfer whose initiating operator
///      is not explicitly allowed — the shape of an operator-whitelist policy,
///      which is what royalty enforcement relies on.
contract MockTransferValidator is ITransferValidator {
    /// @dev Mirrors the revert a real validator raises when a transfer breaks
    ///      the collection's operator policy.
    error OperatorNotAllowed(address caller);

    mapping(address operator => bool allowed) public allowedOperator;

    function setAllowedOperator(address operator, bool allowed) external {
        allowedOperator[operator] = allowed;
    }

    function validateTransfer(address caller, address, address, uint256) external view {
        if (!allowedOperator[caller]) {
            revert OperatorNotAllowed(caller);
        }
    }
}
