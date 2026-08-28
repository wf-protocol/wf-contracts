// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILottoTreasury {
    function currentCarryPool() external view returns (uint256);

    function reserveRefunds(uint256 amount) external;

    function releaseRefundsForSettlement(uint256 amount) external;

    function reservePrizes(uint256 amount) external;

    function reserveRoundPrizes(uint40 roundId, uint64 claimDeadline, uint256 amount) external;

    function totalLiabilities() external view returns (uint256);

    function surplusBalance() external view returns (uint256);

    function applySettlementCarry(uint256 carryProposed) external returns (uint256 carryApplied, uint256 overflowToFund);

    function collectRevenue(uint256 totalSales) external;

    function recycleToCarryPool(uint256 amount) external;

    function payClaim(address to, uint256 amount) external;

    function payRoundClaim(uint40 roundId, address to, uint256 amount, uint256 recycledAmount) external;

    function expireRoundPrizes(uint40 roundId) external returns (uint256 recycledAmount);

    function payRefund(address to, uint256 amount) external;
}
