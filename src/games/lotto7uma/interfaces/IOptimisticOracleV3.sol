// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IOptimisticOracleV3 {
    function defaultIdentifier() external view returns (bytes32);

    function getMinimumBond(IERC20 currency) external view returns (uint256);

    function assertTruth(
        bytes memory claim,
        address asserter,
        address callbackRecipient,
        address escalationManager,
        uint64 liveness,
        IERC20 currency,
        uint256 bond,
        bytes32 identifier,
        bytes32 domainId
    ) external returns (bytes32);

    function settleAndGetAssertionResult(bytes32 assertionId) external returns (bool);
}
