// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev A test signer that approves one digest/signature pair, with malformed-response modes.
/// Authorization is deliberately explicit: merely calling this contract cannot approve a digest.
contract Registry1271Signer {
    enum Mode {
        Valid,
        WrongMagic,
        Revert,
        Empty,
        ShortMagic,
        DirtyMagic,
        WriteState
    }

    bytes32 public approvedDigest;
    bytes32 public approvedSignature;
    Mode public mode;
    uint256 public writes;

    function approve(bytes32 digest, bytes calldata signature) external {
        approvedDigest = digest;
        approvedSignature = keccak256(signature);
    }

    function setMode(Mode next) external {
        mode = next;
    }

    // Intentionally non-view: WriteState must fail inside the consumer's STATICCALL.
    function isValidSignature(bytes32 digest, bytes calldata signature) external returns (bytes4) {
        if (digest != approvedDigest || keccak256(signature) != approvedSignature) {
            return 0xffffffff;
        }
        Mode response = mode;
        if (response == Mode.WrongMagic) return 0xffffffff;
        if (response == Mode.Revert) revert("signer refused");
        if (response == Mode.Empty) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        if (response == Mode.ShortMagic) {
            assembly ("memory-safe") {
                mstore(0, shl(224, 0x1626ba7e))
                return(0, 4)
            }
        }
        if (response == Mode.DirtyMagic) {
            assembly ("memory-safe") {
                mstore(0, or(shl(224, 0x1626ba7e), 1))
                return(0, 32)
            }
        }
        if (response == Mode.WriteState) ++writes;
        return 0x1626ba7e;
    }
}

/// @dev Executable code on an EOA signer models the code-presence branch relevant to EIP-7702.
/// It intentionally has no ERC-1271 support. This is not an EIP-7702 transaction simulation.
contract RegistrySignerRejectingCode {
    fallback() external {
        revert("no contract signature support");
    }
}
