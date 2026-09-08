// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVRFCoordinatorV2Plus} from "../../src/games/lotto3d/interfaces/IVRFCoordinatorV2.sol";

interface IVRFConsumer {
    function rawFulfillRandomWords(uint256 requestId, uint256[] memory randomWords) external;
}

/// @title MockVRFCoordinatorV2Plus
/// @notice 原样移植自 lotto7-refactored/src/mocks/MockVRFCoordinatorV2Plus.sol。
///         测试用最小化 VRF Coordinator 模拟：记录请求，由测试脚本手动调用
///         `fulfillRandomWords` 触发回调，模拟真实 Chainlink VRF 的异步流程。
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

    /// @notice 测试辅助函数：模拟 VRF Coordinator 回调消费者合约。
    function fulfillRandomWords(uint256 requestId, uint256 randomWord) external {
        address consumer = requestConsumer[requestId];
        require(consumer != address(0), "unknown request");

        uint256[] memory words = new uint256[](1);
        words[0] = randomWord;
        IVRFConsumer(consumer).rawFulfillRandomWords(requestId, words);
    }
}
