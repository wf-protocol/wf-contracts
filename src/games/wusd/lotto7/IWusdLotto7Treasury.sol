// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ILotto7Treasury} from "../../lotto7/interfaces/ILotto7Treasury.sol";
import {IRevenueAllocationTreasury} from "../../../protocol/IRevenueAllocationTreasury.sol";

/// @title IWusdLotto7Treasury
/// @notice Extended accounting interface used by the WUSD World Lotto game.
interface IWusdLotto7Treasury is ILotto7Treasury, IRevenueAllocationTreasury {
    struct RoundAccounting {
        uint256 roundId;
        uint64 claimDeadline;
        uint256 floatPool;
        uint256 fixedLiability;
        uint256 tier1Liability;
        uint256 tier2Liability;
        uint256 tier3Liability;
        uint256 tier1Bps;
        uint256 tier2Bps;
        uint256 tier3Bps;
    }

    function sharedCarryPool() external view returns (uint256);

    function previewRoundPools(uint256 floatPool, uint256 tier1Bps, uint256 tier2Bps, uint256 tier3Bps)
        external
        view
        returns (uint256 tier1Available, uint256 tier2Available, uint256 tier3Available, uint256 sharedDust);

    function finalizeRoundAccounting(RoundAccounting calldata accounting) external;

    function payRoundClaim(uint256 roundId, address to, uint256 amount) external;

    function recycleRoundLiability(uint256 roundId, uint256 amount) external;

    function expireRoundClaims(uint256 roundId) external returns (uint256 recycledAmount);

    function injectSharedCarry(uint256 amount) external;
}
