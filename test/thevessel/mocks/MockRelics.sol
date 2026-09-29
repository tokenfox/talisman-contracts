// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev A relics contract The Vessel owner could point `relics` at, answering
///      `isRelic` in one of the shapes a wrapper must survive.
contract MockRelics {
    enum Answer {
        NotRelic,
        Relic,
        Reverts,
        ShortWord,
        NonBoolWord,
        TwoFacedReverts,
        TwoFacedRelic
    }

    // The Vessel's address, where tests etch MockVessel: a two-faced relics
    // contract tells the wrapper "not a relic" and The Vessel something else.
    address internal constant VESSEL = 0xECb92Cc7112b80A2234936315BbB493fb48d1463;

    Answer public answer;

    function setAnswer(Answer answer_) external {
        answer = answer_;
    }

    function isRelic(uint256) external view returns (bool) {
        Answer a = answer;
        if (a == Answer.TwoFacedReverts || a == Answer.TwoFacedRelic) {
            if (msg.sender != VESSEL) {
                return false;
            }
            if (a == Answer.TwoFacedReverts) {
                revert("relics down");
            }
            return true;
        }
        if (a == Answer.Reverts) {
            revert("relics down");
        }
        if (a == Answer.ShortWord) {
            assembly {
                mstore(0x00, 0)
                return(0x1f, 0x01)
            }
        }
        if (a == Answer.NonBoolWord) {
            assembly {
                mstore(0x00, 2)
                return(0x00, 0x20)
            }
        }
        return a == Answer.Relic;
    }

    function relicToPayload(uint256) external pure returns (bytes memory) {
        return "relic";
    }
}
