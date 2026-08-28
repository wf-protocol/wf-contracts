// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IProtocolRevenueRouter {
    struct RevenueAllocation {
        uint16 prizeBps;
        uint16 datBps;
        uint16 partnerBps;
        uint16 opsBps;
        uint32 version;
    }

    function activeVersion() external view returns (uint32);
    function activeAllocation() external view returns (RevenueAllocation memory);
    function allocation(uint32 version) external view returns (RevenueAllocation memory);
}
