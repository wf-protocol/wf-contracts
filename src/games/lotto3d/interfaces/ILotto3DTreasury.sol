// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILotto3DTreasury {
    /// @notice Convert reserved sales into this round's snapshotted revenue allocation.
    function collectSales(uint40 roundId, uint256 totalSales) external;

    /// @notice Get the current prize pool for a round after settlement.
    function settleRoundPrize(uint40 roundId, bool isReleaseRound) external returns (uint256 prizePool);

    /// @notice Pay a refund for a cancelled round.
    function payRefund(address to, uint256 amount) external;

    /// @notice Reserve funds for a cancelled round's refunds.
    function reserveForRefund(uint256 amount) external;

    /// @notice Get the current accumulated pool balance.
    function accumulatedPool() external view returns (uint256);
}
