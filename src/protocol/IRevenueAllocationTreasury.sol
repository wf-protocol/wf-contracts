// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRevenueAllocationTreasury {
    struct RoundRevenueAllocation {
        uint16 prizeBps;
        uint16 datBps;
        uint16 partnerBps;
        uint16 opsBps;
        uint32 version;
        bool snapshotted;
    }

    function snapshotRoundAllocation(uint256 roundId) external returns (RoundRevenueAllocation memory);
    function roundRevenueAllocation(uint256 roundId) external view returns (RoundRevenueAllocation memory);
}
