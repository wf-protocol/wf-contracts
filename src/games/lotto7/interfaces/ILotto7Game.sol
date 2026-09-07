// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ILotto7Game
/// @notice Round lifecycle, ticket sales and settlement callback interface for the
///         7-digit "1000-Millions" lottery.
interface ILotto7Game {
    enum RoundStatus {
        None,
        Open,
        BetClosed,
        Resolved,
        Cancelled
    }

    struct EconomySnapshot {
        uint256 ticketPrice;
        uint256 maxPerUserPerRound;
        uint32 maxMultiplier;
        uint32 maxTotalMultiplierPerUserPerRound;
        uint256 allocPrizeBps;
        uint256 allocOpsBps;
        uint256 floatTier1Bps;
        uint256 floatTier2Bps;
        uint256 floatTier3Bps;
        uint256 fixedTier4;
        uint256 fixedTier5;
        uint256 capTier1;
        uint256 capTier2;
        uint256 capTier3;
        uint256 circuitBreakerBps;
    }

    struct Round {
        uint256 startTime;
        uint256 betCloseTime;
        uint256 endTime;
        RoundStatus status;
        uint32 winningNumber;
        uint256 sales;
        uint256 prizePool;
        uint256 winUnits1;
        uint256 winUnits2;
        uint256 winUnits3;
        uint256 payout1;
        uint256 payout2;
        uint256 payout3;
        uint256 payout4;
        uint256 payout5;
        EconomySnapshot economy;
    }

    event RoundStarted(uint256 indexed roundId, uint256 startTime, uint256 betCloseTime, uint256 endTime);
    event TicketBought(uint256 indexed roundId, address indexed buyer, uint32[] numbers, uint32[] multipliers);
    event BetClosed(uint256 indexed roundId);
    event RoundResolved(uint256 indexed roundId, uint32 winningNumber, uint256 prizePool);
    event RoundCancelled(uint256 indexed roundId, uint256 cancelledAt);
    event RefundClaimed(uint256 indexed roundId, address indexed user, uint256 amount);
    event PrizeClaimed(uint256 indexed roundId, address indexed user, uint256 ticketIdx, uint8 tier, uint256 amount);
    event FixedPrizeRecycled(uint256 indexed roundId, address indexed user, uint256 ticketIdx, uint256 recycledAmount);

    /// @notice 由 VRF Adapter 调用，使用随机数结算指定轮次。
    function settleDraw(uint256 roundId, uint32 winningNumber) external;

    /// @notice 仅 VRF Adapter 可调用；Adapter 必须先确认该轮从未生成 requestId。
    function cancelTimedOutRound(uint256 roundId) external;

    /// @notice Adapter 在请求随机数前读取轮次状态与请求窗口。
    function getRound(uint256 roundId) external view returns (Round memory);
}
