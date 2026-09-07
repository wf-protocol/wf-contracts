// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev 原样移植自 smart-contract-pd-main/src/interfaces/IOptimisticOracleV3.sol，
///      UMA Optimistic Oracle V3 的最小接口子集，未作改动，与资金托管层无关。
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
