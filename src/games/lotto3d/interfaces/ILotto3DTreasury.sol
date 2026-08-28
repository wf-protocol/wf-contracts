// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILotto3DTreasury {
    /// @notice Record sales revenue and split into pools (50/30/20).
    function collectSales(uint40 roundId, uint256 totalSales) external;

    /// @notice Get the current prize pool for a round after settlement.
    function settleRoundPrize(uint40 roundId, bool isReleaseRound) external returns (uint256 prizePool);

    /// @notice Pay a claim to a winner.
    function payClaim(address to, uint256 amount) external;

    /// @notice Pay multiple claims to the same winner with one ledger transfer.
    function payClaimBatch(address to, uint256 amount) external;

    /// @notice Pay a refund for a cancelled round.
    function payRefund(address to, uint256 amount) external;

    /// @notice Reserve funds for a cancelled round's refunds.
    function reserveForRefund(uint256 amount) external;

    /// @notice Get the current accumulated pool balance.
    function accumulatedPool() external view returns (uint256);
}
