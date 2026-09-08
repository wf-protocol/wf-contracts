// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {LottoSettlement} from "../src/games/lotto7uma/LottoSettlement.sol";
import {ILottoRounds} from "../src/games/lotto7uma/interfaces/ILottoRounds.sol";
import {ILottoTreasury} from "../src/games/lotto7uma/interfaces/ILottoTreasury.sol";

contract MockOrderedLottoRounds {
    uint40 public latestRoundId;
    mapping(uint40 => uint40) public previousRoundId;
    mapping(uint40 => ILottoRounds.RoundData) internal _rounds;
    mapping(uint40 => uint256[]) internal _roundTicketIds;
    mapping(uint256 => ILottoRounds.TicketData) internal _tickets;

    function addDrawnRound(uint40 roundId, uint256 sales, uint32 winningNumber, uint32 ticketNumber) external {
        previousRoundId[roundId] = latestRoundId;
        latestRoundId = roundId;
        ILottoRounds.RoundData storage round = _rounds[roundId];
        round.exists = true;
        round.salesClosed = true;
        round.totalSales = sales;
        round.winningNumber = winningNumber;
        round.drawStatus = ILottoRounds.DrawStatus.Drawn;
        round.config.claimDeadline = uint64(block.timestamp + 365 days);

        uint256 ticketId = uint256(roundId);
        _roundTicketIds[roundId].push(ticketId);
        _tickets[ticketId] = ILottoRounds.TicketData({
            buyer: address(this),
            number: ticketNumber,
            multiplier: 1,
            refunded: false,
            claimed: false,
            payer: address(this),
            roundId: roundId,
            paid: sales
        });
    }

    function getRound(uint40 roundId) external view returns (ILottoRounds.RoundData memory) {
        return _rounds[roundId];
    }

    function isRoundDrawn(uint40 roundId) external view returns (bool) {
        return _rounds[roundId].drawStatus == ILottoRounds.DrawStatus.Drawn;
    }

    function roundTicketCount(uint40 roundId) external view returns (uint256) {
        return _roundTicketIds[roundId].length;
    }

    function roundTicketIdAt(uint40 roundId, uint256 index) external view returns (uint256) {
        return _roundTicketIds[roundId][index];
    }

    function getTicket(uint256 ticketId) external view returns (ILottoRounds.TicketData memory) {
        return _tickets[ticketId];
    }

    function roundWinningNumber(uint40 roundId) external view returns (uint32) {
        return _rounds[roundId].winningNumber;
    }

    function roundTotalSales(uint40 roundId) external view returns (uint256) {
        return _rounds[roundId].totalSales;
    }

    function roundClaimDeadline(uint40 roundId) external view returns (uint64) {
        return _rounds[roundId].config.claimDeadline;
    }

    function markTicketClaimed(uint256 ticketId) external {
        _tickets[ticketId].claimed = true;
    }
}

contract MockLottoSettlementTreasury {
    uint256 public carryPool = 100e6;
    uint256 public lastPrizeReserve;

    function setCarryPool(uint256 amount) external {
        carryPool = amount;
    }

    function currentCarryPool() external view returns (uint256) {
        return carryPool;
    }

    function releaseRefundsForSettlement(uint256) external {}

    function applySettlementCarry(uint256 amount) external returns (uint256 carryApplied, uint256 overflowToFund) {
        carryPool = amount;
        return (amount, 0);
    }

    function reserveRoundPrizes(uint40, uint64, uint256 amount) external {
        lastPrizeReserve = amount;
    }

    function previewRoundPrize(uint256, uint256 sales) external pure returns (uint256) {
        return sales * 8000 / 10000;
    }

    function finalizeRoundRevenue(uint256, uint256 sales) external pure returns (uint256) {
        return sales * 8000 / 10000;
    }
    function payRoundClaim(uint40, address, uint256, uint256) external {}
    function recycleToCarryPool(uint256) external {}
    function payClaim(address, uint256) external {}

    function expireRoundPrizes(uint40) external pure returns (uint256 recycledAmount) {
        return 0;
    }
}

contract LottoSettlementSecurityTest is Test {
    MockOrderedLottoRounds internal rounds;
    MockLottoSettlementTreasury internal treasury;
    LottoSettlement internal settlement;

    function setUp() public {
        vm.warp(1_800_000_000);
        rounds = new MockOrderedLottoRounds();
        treasury = new MockLottoSettlementTreasury();
        settlement = LottoSettlement(
            address(
                new ERC1967Proxy(
                    address(new LottoSettlement()),
                    abi.encodeCall(
                        LottoSettlement.initialize,
                        (address(this), ILottoRounds(address(rounds)), ILottoTreasury(address(treasury)))
                    )
                )
            )
        );
    }

    function testCannotSettleLaterRoundBeforeItsPredecessor() public {
        rounds.addDrawnRound(1, 100e6, 1_234_567, 1_234_567);
        rounds.addDrawnRound(2, 100e6, 7_654_321, 1_111_111);

        vm.expectRevert(abi.encodeWithSelector(LottoSettlement.PreviousRoundUnresolved.selector, uint40(1)));
        settlement.postSettlement(2);

        settlement.postSettlement(1);
        settlement.postSettlement(2);
        assertEq(settlement.getRoundSettlement(1).payout1, 90e6);
    }

    function testFixedPrizeReserveCannotExceedPrizePool() public {
        treasury.setCarryPool(0);
        settlement.pause();
        settlement.setCircuitBreaker(10_000);
        settlement.unpause();

        rounds.addDrawnRound(1, 100e6, 7_654_321, 1_765_432);
        settlement.postSettlement(1);

        assertEq(settlement.getRoundSettlement(1).payout4, 80e6);
        assertEq(treasury.lastPrizeReserve(), 80e6);
    }

    function testCannotChangePayoutRulesWhileRoundIsActive() public {
        rounds.addDrawnRound(1, 100e6, 1_234_567, 1_234_567);
        settlement.pause();

        vm.expectRevert(abi.encodeWithSelector(LottoSettlement.ActiveRoundExists.selector, uint40(1)));
        settlement.setFixedPrizes(1, 1);
    }
}
