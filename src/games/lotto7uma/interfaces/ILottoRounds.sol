// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILottoRounds {
    enum DrawStatus {
        None,
        PendingAssertion,
        ReadyForRetry,
        Drawn,
        Cancelled
    }

    struct RoundConfig {
        uint64 salesOpenTime;
        uint64 salesCloseTime;
        uint64 drawDataDeadline;
        uint64 claimDeadline;
        uint16 maxMultiplierPerTicket;
        uint64 assertionLiveness;
    }

    struct RoundData {
        bool exists;
        bool salesClosed;
        bool cancelled;
        bool hasHadAssertion; // true once any assertion has been initiated for this round
        RoundConfig config;
        uint256 totalSales;
        uint256 totalUnits;
        uint32 winningNumber;
        uint32 winningNumberPreview;
        bytes32 sourceBundleHash;
        bytes32 normalizedDataHash;
        bytes32 oracleAssertionId;
        address oracleAdapter;
        uint64 drawResolvedAt;
        DrawStatus drawStatus;
    }

    event TicketPurchased(
        uint256 indexed ticketId,
        uint40 indexed roundId,
        address indexed buyer,
        uint32 number,
        uint16 multiplier,
        uint256 paid
    );

    /// @dev Field order packs ticket data into three storage slots.
    struct TicketData {
        address buyer;
        uint32 number;
        uint16 multiplier;
        bool refunded;
        bool claimed;
        address payer;
        uint40 roundId;
        uint256 paid;
    }

    function exact7Units(uint40 roundId, uint32 number) external view returns (uint256);
    function prefix6Units(uint40 roundId, uint32 prefix6) external view returns (uint256);
    function prefix5Units(uint40 roundId, uint32 prefix5) external view returns (uint256);
    function slide4Units(uint40 roundId, uint32 windowKey) external view returns (uint256);
    function slide3Units(uint40 roundId, uint32 windowKey) external view returns (uint256);
    function getTicket(uint256 ticketId) external view returns (TicketData memory);
    function roundTicketCount(uint40 roundId) external view returns (uint256);
    function roundTicketIdAt(uint40 roundId, uint256 index) external view returns (uint256);
    function markTicketClaimed(uint256 ticketId) external;
    function roundWinningNumber(uint40 roundId) external view returns (uint32);
    function roundClaimDeadline(uint40 roundId) external view returns (uint64);
    function roundTotalSales(uint40 roundId) external view returns (uint256);
    function roundSourceBundleHash(uint40 roundId) external view returns (bytes32);
    function roundNormalizedDataHash(uint40 roundId) external view returns (bytes32);
    function roundOracleAssertionId(uint40 roundId) external view returns (bytes32);
    function roundDrawStatus(uint40 roundId) external view returns (DrawStatus);
    function isRoundDrawn(uint40 roundId) external view returns (bool);
    function latestRoundId() external view returns (uint40);
    function previousRoundId(uint40 roundId) external view returns (uint40);
    function getRound(uint40 roundId) external view returns (RoundData memory);

    function markDrawAssertionPending(
        uint40 roundId,
        bytes32 assertionId,
        bytes32 sourceBundleHash,
        uint32 winningNumberPreview,
        bytes32 normalizedDataHash
    ) external;

    function markDrawAssertionDisputed(uint40 roundId, bytes32 assertionId) external;

    function clearPendingAssertionForRetry(uint40 roundId, bytes32 assertionId) external;

    function submitDraw(uint40 roundId, uint32 winningNumber, bytes32 sourceBundleHash) external;

    function buy(uint40 roundId, uint32 number, uint16 multiplier) external;

    function batchBuy(uint40 roundId, uint32[] calldata numbers, uint16[] calldata multipliers) external;

    function buyFor(address beneficiary, uint40 roundId, uint32 number, uint16 multiplier) external;

    function batchBuyFor(address beneficiary, uint40 roundId, uint32[] calldata numbers, uint16[] calldata multipliers)
        external;
}
