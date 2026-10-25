// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Hashes} from "@openzeppelin/contracts/utils/cryptography/Hashes.sol";

/// @notice Minimal Merkle tree builder compatible with OpenZeppelin's MerkleProof (sorted pairs).
///         Odd layers carry their last node up unchanged, so odd and even leaf counts both work.
library Merkle {
    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        require(leaves.length > 0, "Merkle: empty");
        bytes32[] memory layer = leaves;
        while (layer.length > 1) {
            layer = _nextLayer(layer);
        }
        return layer[0];
    }

    function proof(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory out) {
        require(index < leaves.length, "Merkle: index");
        // Upper bound on proof length is ceil(log2(n)); allocate generously then trim.
        bytes32[] memory tmp = new bytes32[](64);
        uint256 n;
        bytes32[] memory layer = leaves;
        uint256 i = index;
        while (layer.length > 1) {
            uint256 sibling = i ^ 1;
            if (sibling < layer.length) {
                tmp[n++] = layer[sibling];
            }
            layer = _nextLayer(layer);
            i /= 2;
        }
        out = new bytes32[](n);
        for (uint256 k; k < n; ++k) {
            out[k] = tmp[k];
        }
    }

    function _nextLayer(bytes32[] memory layer) private pure returns (bytes32[] memory next) {
        uint256 len = (layer.length + 1) / 2;
        next = new bytes32[](len);
        for (uint256 i; i < len; ++i) {
            uint256 a = 2 * i;
            uint256 b = a + 1;
            next[i] = b < layer.length ? Hashes.commutativeKeccak256(layer[a], layer[b]) : layer[a];
        }
    }
}
