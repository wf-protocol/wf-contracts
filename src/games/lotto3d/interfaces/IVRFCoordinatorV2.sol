// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IVRFCoordinatorV2Plus
/// @notice Minimal interface for Chainlink VRF Coordinator V2.5 (V2Plus).
interface IVRFCoordinatorV2Plus {
    struct RandomWordsRequest {
        bytes32 keyHash;
        uint256 subId;
        uint16 requestConfirmations;
        uint32 callbackGasLimit;
        uint32 numWords;
        bytes extraArgs;
    }

    function requestRandomWords(RandomWordsRequest calldata req) external returns (uint256 requestId);
}
