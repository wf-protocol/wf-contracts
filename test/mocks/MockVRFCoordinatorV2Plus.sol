// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVRFCoordinatorV2Plus} from "../../src/games/lotto3d/interfaces/IVRFCoordinatorV2.sol";

interface IVRFConsumer {
    function rawFulfillRandomWords(uint256 requestId, uint256[] memory randomWords) external;
}

/// @title MockVRFCoordinatorV2Plus
contract MockVRFCoordinatorV2Plus is IVRFCoordinatorV2Plus {
    uint256 public nextRequestId = 1;
    mapping(uint256 => address) public requestConsumer;
    bytes public lastExtraArgs;

    event RandomWordsRequested(uint256 indexed requestId, address indexed consumer);

    function requestRandomWords(RandomWordsRequest calldata req) external override returns (uint256 requestId) {
        lastExtraArgs = req.extraArgs;
        requestId = nextRequestId++;
        requestConsumer[requestId] = msg.sender;
        emit RandomWordsRequested(requestId, msg.sender);
    }

    function fulfillRandomWords(uint256 requestId, uint256 randomWord) external {
        address consumer = requestConsumer[requestId];
        require(consumer != address(0), "unknown request");

        uint256[] memory words = new uint256[](1);
        words[0] = randomWord;
        IVRFConsumer(consumer).rawFulfillRandomWords(requestId, words);
    }
}
