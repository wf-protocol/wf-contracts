// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ILottoRounds} from "./interfaces/ILottoRounds.sol";
import {ILottoTreasury} from "./interfaces/ILottoTreasury.sol";
import {LottoPrizeMath} from "../libraries/LottoPrizeMath.sol";
import {IWusdLottoUmaRevenueTreasury} from "../wusd/lotto7uma/IWusdLottoUmaRevenueTreasury.sol";

/// @title World Lotto settlement
/// @notice Counts each ticket at its highest tier, reserves payouts, and recycles unclaimed prizes.
/// @dev Anyone may advance deterministic settlement; only ticket owners may claim.
contract LottoSettlement is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    UUPSUpgradeable
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    uint256 public constant BPS = 10_000;
    uint64 public constant DEFAULT_CLAIM_PERIOD = 90 days;
    uint256 public constant AUTO_COUNT_LIMIT = 100;

    error ZeroAddress();
    error InvalidRound();
    error RoundNotDrawn();
    error SettlementAlreadyPosted();
    error SettlementNotPosted();
    error InvalidConfig();
    error ClaimExpired();
    error NotTicketOwner();
    error InvalidTicket();
    error NoPrize();
    error ClaimPeriodOutOfRange();
    error RoundClaimsNotExpirable();
    error SettlementCountingIncomplete(uint256 processed, uint256 total);
    error PreviousRoundUnresolved(uint40 previousRoundId);
    error ActiveRoundExists(uint40 roundId);

    struct RoundSettlement {
        bool posted;
        uint256 payout1;
        uint256 payout2;
        uint256 payout3;
        uint256 payout4;
        uint256 payout5;
        uint256 winUnits1;
        uint256 winUnits2;
        uint256 winUnits3;
        uint256 winUnits4;
        uint256 winUnits5;
        uint256 carryNext;
        uint64 claimDeadline;
    }

    struct TierCountProgress {
        uint256 cursor;
        uint256 winUnits1;
        uint256 winUnits2;
        uint256 winUnits3;
        uint256 winUnits4;
        uint256 winUnits5;
    }

    ILottoRounds public rounds;
    ILottoTreasury public treasury;

    /// @notice Per-unit payout caps for floating tiers (6 decimals). 0 = no cap.
    uint256 public payoutCap1;
    uint256 public payoutCap2;
    uint256 public payoutCap3;

    /// @notice Floating-tier (1/2/3) budget split, in bps. Must sum to BPS.
    uint256 public floatTier1Bps;
    uint256 public floatTier2Bps;
    uint256 public floatTier3Bps;

    /// @notice Fixed per-unit payout for tiers 4/5 (before circuit-breaker scaling).
    uint256 public fixedTier4;
    uint256 public fixedTier5;

    /// @notice Fraction of the round's sales that fixed tiers 4/5 may consume
    ///         before being scaled down proportionally.
    uint256 public circuitBreakerBps;

    mapping(uint40 roundId => RoundSettlement settlementData) private _settlements;
    uint64 public claimPeriod;
    mapping(uint40 roundId => bool enabled) public roundLiabilityAccountingEnabled;
    mapping(uint40 roundId => TierCountProgress progress) public settlementProgress;

    event SettlementConfigUpdated(
        uint256 floatTier1Bps,
        uint256 floatTier2Bps,
        uint256 floatTier3Bps,
        uint256 fixedTier4,
        uint256 fixedTier5,
        uint256 circuitBreakerBps
    );
    event SettlementPosted(
        uint40 indexed roundId,
        uint256 payout1,
        uint256 payout2,
        uint256 payout3,
        uint256 payout4,
        uint256 payout5,
        uint256 winUnits1,
        uint256 winUnits2,
        uint256 winUnits3,
        uint256 winUnits4,
        uint256 winUnits5,
        uint256 carryNext
    );
    event PrizeClaimed(
        uint40 indexed roundId, uint256 indexed ticketId, address indexed user, uint8 tier, uint256 amount
    );
    event ClaimPeriodUpdated(uint64 previousPeriod, uint64 newPeriod);
    event RoundPrizesExpired(uint40 indexed roundId, uint256 recycledAmount);
    event SettlementCountingProgress(uint40 indexed roundId, uint256 processed, uint256 total);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin_, ILottoRounds rounds_, ILottoTreasury treasury_) public initializer {
        if (admin_ == address(0) || address(rounds_) == address(0) || address(treasury_) == address(0)) {
            revert ZeroAddress();
        }

        __AccessControl_init();
        __Pausable_init();

        rounds = rounds_;
        treasury = treasury_;

        // Default caps per rules: 10M / 1M / 10K USDT (6 decimals)
        payoutCap1 = 10_000_000 * 1e6;
        payoutCap2 = 1_000_000 * 1e6;
        payoutCap3 = 10_000 * 1e6;

        // Default float split 50/30/20, matching the original off-chain settler
        // convention documented in the pre-migration code.
        floatTier1Bps = 5000;
        floatTier2Bps = 3000;
        floatTier3Bps = 2000;

        fixedTier4 = 100 * 1e6;
        fixedTier5 = 5 * 1e6;
        circuitBreakerBps = 5000;
        claimPeriod = DEFAULT_CLAIM_PERIOD;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
    }

    /// @notice Update per-unit payout caps for floating tiers. 0 = no cap.
    function setPayoutCaps(uint256 cap1, uint256 cap2, uint256 cap3) external onlyRole(ADMIN_ROLE) whenPaused {
        _requireNoActiveRound();
        payoutCap1 = cap1;
        payoutCap2 = cap2;
        payoutCap3 = cap3;
    }

    /// @notice Update the floating-tier (1/2/3) budget split. Must sum to BPS.
    function setFloatBps(uint256 t1, uint256 t2, uint256 t3) external onlyRole(ADMIN_ROLE) whenPaused {
        _requireNoActiveRound();
        if (t1 + t2 + t3 != BPS) {
            revert InvalidConfig();
        }
        floatTier1Bps = t1;
        floatTier2Bps = t2;
        floatTier3Bps = t3;
        emit SettlementConfigUpdated(t1, t2, t3, fixedTier4, fixedTier5, circuitBreakerBps);
    }

    /// @notice Update the fixed per-unit payout for tiers 4/5.
    function setFixedPrizes(uint256 tier4, uint256 tier5) external onlyRole(ADMIN_ROLE) whenPaused {
        _requireNoActiveRound();
        fixedTier4 = tier4;
        fixedTier5 = tier5;
        emit SettlementConfigUpdated(floatTier1Bps, floatTier2Bps, floatTier3Bps, tier4, tier5, circuitBreakerBps);
    }

    /// @notice Update the circuit-breaker cap (bps of round sales) for fixed tiers 4/5.
    function setCircuitBreaker(uint256 bps) external onlyRole(ADMIN_ROLE) whenPaused {
        _requireNoActiveRound();
        if (bps > BPS) {
            revert InvalidConfig();
        }
        circuitBreakerBps = bps;
        emit SettlementConfigUpdated(floatTier1Bps, floatTier2Bps, floatTier3Bps, fixedTier4, fixedTier5, bps);
    }

    /// @notice Count winning units in bounded batches. Each ticket contributes
    ///         only to its highest prize tier, matching the claim path exactly.
    function processSettlement(uint40 roundId, uint256 maxTickets) external whenNotPaused nonReentrant {
        _validateUnpostedDrawnRound(roundId);
        if (maxTickets == 0) revert InvalidConfig();
        _processTicketBatch(roundId, maxTickets);
    }

    /// @notice Settle a drawn round entirely from on-chain state. Anyone may
    ///         call this — the result is a deterministic function of on-chain
    ///         counters and admin-configured parameters, so there is nothing
    ///         for a caller to manipulate. This removes the SETTLER_ROLE trust
    ///         point entirely (see contract-level NatSpec).
    function postSettlement(uint40 roundId) external whenNotPaused nonReentrant {
        _validateUnpostedDrawnRound(roundId);

        RoundSettlement storage settlementData = _settlements[roundId];
        uint256 ticketCount = rounds.roundTicketCount(roundId);
        TierCountProgress storage progress = settlementProgress[roundId];
        if (progress.cursor == 0 && ticketCount <= AUTO_COUNT_LIMIT) {
            _processTicketBatch(roundId, ticketCount);
        }
        if (progress.cursor != ticketCount) {
            revert SettlementCountingIncomplete(progress.cursor, ticketCount);
        }

        uint256 totalSales = rounds.roundTotalSales(roundId);
        uint256 prevCarry = treasury.currentCarryPool();
        uint256 winUnits1 = progress.winUnits1;
        uint256 winUnits2 = progress.winUnits2;
        uint256 winUnits3 = progress.winUnits3;
        uint256 winUnits4 = progress.winUnits4;
        uint256 winUnits5 = progress.winUnits5;

        uint256 roundPrizeAmount =
            IWusdLottoUmaRevenueTreasury(address(treasury)).previewRoundPrize(roundId, totalSales);
        uint256 prizePool = roundPrizeAmount + prevCarry;

        // ---- Tier 4/5：固定单价，超出熔断预算按比例缩水（与 VRF 版算法一致） ----
        uint256 fixedTotal = winUnits4 * fixedTier4 + winUnits5 * fixedTier5;
        // The fixed-prize circuit breaker is based on this round's sales, not
        // the total prize pool. Carry funds remain available to the floating
        // tiers and are not used to expand the fixed-prize budget.
        uint256 circuitCap = (totalSales * circuitBreakerBps) / BPS;

        uint256 fixedBudget = fixedTotal < circuitCap ? fixedTotal : circuitCap;
        if (fixedBudget > prizePool) fixedBudget = prizePool;

        uint256 payout4;
        uint256 payout5;
        if (fixedTotal > fixedBudget && fixedTotal > 0) {
            payout4 = (fixedBudget * fixedTier4) / fixedTotal;
            payout5 = (fixedBudget * fixedTier5) / fixedTotal;
        } else {
            payout4 = fixedTier4;
            payout5 = fixedTier5;
        }

        uint256 fixedReserve = fixedBudget;
        uint256 floatPool = prizePool > fixedReserve ? prizePool - fixedReserve : 0;

        // ---- Tier 1/2/3：按配置的 bps 从统一浮动奖池分账，逐级计算 ----
        uint256 payout1 = _calcTierFloat(winUnits1, floatPool, floatTier1Bps, payoutCap1);
        uint256 payout2 = _calcTierFloat(winUnits2, floatPool, floatTier2Bps, payoutCap2);
        uint256 payout3 = _calcTierFloat(winUnits3, floatPool, floatTier3Bps, payoutCap3);

        // 未派发出去的浮动奖池份额（无中奖者、封顶节省、取整余数）全部自动滚存到
        // 下一轮，不存在"settler 少报 carryNext"的空间。
        uint256 totalFloatPaid = payout1 * winUnits1 + payout2 * winUnits2 + payout3 * winUnits3;
        uint256 totalFixedPaid = payout4 * winUnits4 + payout5 * winUnits5;
        uint256 prizeReserveAmount = totalFloatPaid + totalFixedPaid;
        uint256 carryNext = prizePool > prizeReserveAmount ? prizePool - prizeReserveAmount : 0;

        // Set posted before external calls to prevent reentrancy bypass.
        settlementData.posted = true;

        // The full ticket sales were reserved for cancellation refunds while
        // the round was unresolved. Settlement atomically converts that
        // liability into carry, posted prizes and revenue liabilities.
        treasury.releaseRefundsForSettlement(totalSales);
        (uint256 carryApplied,) = treasury.applySettlementCarry(carryNext);
        uint64 configuredDeadline = rounds.roundClaimDeadline(roundId);
        uint64 minimumDeadline = uint64(block.timestamp + _effectiveClaimPeriod());
        uint64 claimDeadline = configuredDeadline > minimumDeadline ? configuredDeadline : minimumDeadline;
        treasury.reserveRoundPrizes(roundId, claimDeadline, prizeReserveAmount);
        uint256 finalizedPrize =
            IWusdLottoUmaRevenueTreasury(address(treasury)).finalizeRoundRevenue(roundId, totalSales);
        if (finalizedPrize != roundPrizeAmount) revert InvalidConfig();

        settlementData.payout1 = payout1;
        settlementData.payout2 = payout2;
        settlementData.payout3 = payout3;
        settlementData.payout4 = payout4;
        settlementData.payout5 = payout5;
        settlementData.winUnits1 = winUnits1;
        settlementData.winUnits2 = winUnits2;
        settlementData.winUnits3 = winUnits3;
        settlementData.winUnits4 = winUnits4;
        settlementData.winUnits5 = winUnits5;
        settlementData.carryNext = carryApplied;
        settlementData.claimDeadline = claimDeadline;
        roundLiabilityAccountingEnabled[roundId] = true;

        emit SettlementPosted(
            roundId,
            payout1,
            payout2,
            payout3,
            payout4,
            payout5,
            winUnits1,
            winUnits2,
            winUnits3,
            winUnits4,
            winUnits5,
            carryApplied
        );
    }

    function _validateUnpostedDrawnRound(uint40 roundId) private view {
        if (roundId == 0) revert InvalidRound();
        if (!rounds.isRoundDrawn(roundId)) revert RoundNotDrawn();
        if (_settlements[roundId].posted) revert SettlementAlreadyPosted();

        uint40 previous = rounds.previousRoundId(roundId);
        while (previous != 0 && !_settlements[previous].posted) {
            ILottoRounds.RoundData memory previousRound = rounds.getRound(previous);
            if (!previousRound.cancelled) revert PreviousRoundUnresolved(previous);
            previous = rounds.previousRoundId(previous);
        }
    }

    function _processTicketBatch(uint40 roundId, uint256 maxTickets) private {
        uint256 ticketCount = rounds.roundTicketCount(roundId);
        TierCountProgress storage progress = settlementProgress[roundId];
        uint256 cursor = progress.cursor;
        if (cursor >= ticketCount || maxTickets == 0) return;

        uint256 remaining = ticketCount - cursor;
        uint256 end = maxTickets >= remaining ? ticketCount : cursor + maxTickets;
        uint32 winningNumber = rounds.roundWinningNumber(roundId);

        for (uint256 i = cursor; i < end; ++i) {
            ILottoRounds.TicketData memory ticket = rounds.getTicket(rounds.roundTicketIdAt(roundId, i));
            if (ticket.roundId != roundId) revert InvalidTicket();

            uint256 units = uint256(ticket.multiplier);
            uint8 tier = LottoPrizeMath.highestTier(ticket.number, winningNumber);
            if (tier == 1) progress.winUnits1 += units;
            else if (tier == 2) progress.winUnits2 += units;
            else if (tier == 3) progress.winUnits3 += units;
            else if (tier == 4) progress.winUnits4 += units;
            else if (tier == 5) progress.winUnits5 += units;
        }

        progress.cursor = end;
        emit SettlementCountingProgress(roundId, end, ticketCount);
    }

    /// @notice Claim the prize for a single ticket. The caller must be the
    ///         ticket's buyer; tier and amount are recomputed on-chain from the
    ///         ticket's stored number/multiplier — no proof or external input
    ///         is trusted.
    function claim(uint256 ticketId) external nonReentrant {
        ILottoRounds.TicketData memory ticket = rounds.getTicket(ticketId);
        if (ticket.buyer == address(0)) {
            revert InvalidTicket();
        }
        if (ticket.buyer != msg.sender) {
            revert NotTicketOwner();
        }

        RoundSettlement storage settlementData = _settlements[ticket.roundId];
        if (!settlementData.posted) {
            revert SettlementNotPosted();
        }
        if (block.timestamp > settlementData.claimDeadline) {
            revert ClaimExpired();
        }

        uint32 winningNumber = rounds.roundWinningNumber(ticket.roundId);
        uint8 tier = LottoPrizeMath.highestTier(ticket.number, winningNumber);
        uint256 basePayout = _tierPayout(settlementData, tier);
        if (tier == 0 || basePayout == 0) {
            revert NoPrize();
        }

        uint256 amount = basePayout * ticket.multiplier;

        rounds.markTicketClaimed(ticketId);
        treasury.payRoundClaim(ticket.roundId, msg.sender, amount, 0);

        emit PrizeClaimed(ticket.roundId, ticketId, msg.sender, tier, amount);
    }

    function expireRoundPrizes(uint40 roundId) external returns (uint256 recycledAmount) {
        if (!roundLiabilityAccountingEnabled[roundId]) revert RoundClaimsNotExpirable();
        recycledAmount = treasury.expireRoundPrizes(roundId);
        emit RoundPrizesExpired(roundId, recycledAmount);
    }

    function setClaimPeriod(uint64 newPeriod) external onlyRole(ADMIN_ROLE) whenPaused {
        _requireNoActiveRound();
        if (newPeriod < 1 days || newPeriod > 365 days) revert ClaimPeriodOutOfRange();
        uint64 previous = _effectiveClaimPeriod();
        claimPeriod = newPeriod;
        emit ClaimPeriodUpdated(previous, newPeriod);
    }

    function _effectiveClaimPeriod() internal view returns (uint64) {
        return claimPeriod == 0 ? DEFAULT_CLAIM_PERIOD : claimPeriod;
    }

    function _requireNoActiveRound() internal view {
        uint40 latest = rounds.latestRoundId();
        while (latest != 0 && !_settlements[latest].posted) {
            if (!rounds.getRound(latest).cancelled) revert ActiveRoundExists(latest);
            latest = rounds.previousRoundId(latest);
        }
    }

    function _authorizeUpgrade(address) internal override onlyRole(ADMIN_ROLE) {}

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function getRoundSettlement(uint40 roundId) external view returns (RoundSettlement memory) {
        return _settlements[roundId];
    }

    function _tierPayout(RoundSettlement storage settlementData, uint8 tier) private view returns (uint256) {
        if (tier == 1) return settlementData.payout1;
        if (tier == 2) return settlementData.payout2;
        if (tier == 3) return settlementData.payout3;
        if (tier == 4) return settlementData.payout4;
        if (tier == 5) return settlementData.payout5;
        return 0;
    }

    function _calcTierFloat(uint256 winUnits, uint256 floatPool, uint256 bps, uint256 cap)
        private
        pure
        returns (uint256 payout)
    {
        if (winUnits == 0) {
            return 0;
        }
        uint256 share = (floatPool * bps) / BPS;
        uint256 perUnit = share / winUnits;
        payout = (cap > 0 && perUnit > cap) ? cap : perUnit;
    }
}
