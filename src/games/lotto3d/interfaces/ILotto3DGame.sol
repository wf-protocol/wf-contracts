// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILotto3DGame {
    enum RoundStatus {
        None,
        Open,
        SalesClosed,
        Settled,
        Cancelled
    }

    struct RoundConfig {
        uint64 salesOpenTime;
        uint64 salesCloseTime;
        uint64 drawDeadline;
    }

    struct RoundData {
        bool exists;
        RoundStatus status;
        RoundConfig config;
        uint256 totalSales;
        uint256 totalTickets;
        uint16 winningNumber;
        uint256 prizePool;
        uint256 prize1PerUnit;
        uint256 prize2PerUnit;
        uint256 prize3PerUnit;
        uint256 winUnits1;
        uint256 winUnits2;
        uint256 winUnits3;
    }

    event RoundCreated(uint40 indexed roundId, uint64 salesOpenTime, uint64 salesCloseTime);
    event TicketPurchased(uint256 indexed ticketId, uint40 indexed roundId, address indexed buyer, uint16 number);
    event SalesClosed(uint40 indexed roundId);
    event RoundSettled(
        uint40 indexed roundId,
        uint16 winningNumber,
        uint256 prizePool,
        uint256 prize1PerUnit,
        uint256 prize2PerUnit,
        uint256 prize3PerUnit,
        uint256 winUnits1,
        uint256 winUnits2,
        uint256 winUnits3
    );
    event RoundCancelled(uint40 indexed roundId);
    event PrizeClaimed(
        uint256 indexed ticketId, uint40 indexed roundId, address indexed user, uint8 tier, uint256 amount
    );
    event TicketRefunded(uint256 indexed ticketId, uint40 indexed roundId, address indexed buyer, uint256 amount);

    function settleDraw(uint40 roundId, uint16 winningNumber) external;

    function cancelTimedOutRound(uint40 roundId) external;

    function getRound(uint40 roundId) external view returns (RoundData memory);
}
