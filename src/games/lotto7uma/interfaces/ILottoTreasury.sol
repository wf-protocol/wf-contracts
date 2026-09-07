// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev 原样移植自 smart-contract-pd-main/src/interfaces/ILottoTreasury.sol。
///      本次"全链上结算"改造新增了 `recycleToCarryPool`，用于修复
///      一二三等奖号码天然重叠进四五等奖滑动窗口计数、导致部分奖池资金
///      永久卡死的记账 bug（见 LottoTreasury.recycleToCarryPool 详细说明）。
///      其余接口签名未作改动。
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

    /// @notice 把四五等奖预留但因归属更高等级而从未真正派发的金额重新计入奖池
    ///         滚存。见 LottoTreasury.recycleToCarryPool 的详细说明。
    function recycleToCarryPool(uint256 amount) external;

    function payClaim(address to, uint256 amount) external;

    function payRoundClaim(uint40 roundId, address to, uint256 amount, uint256 recycledAmount) external;

    function expireRoundPrizes(uint40 roundId) external returns (uint256 recycledAmount);

    function payRefund(address to, uint256 amount) external;
}
