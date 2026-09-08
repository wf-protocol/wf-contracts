// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {IUnifiedLedgerV4} from "../../../wusd/IUnifiedLedgerV4.sol";
import {IGameModuleV4} from "../../../protocol/IGameModuleV4.sol";
import {IRevenueAllocationTreasury} from "../../../protocol/IRevenueAllocationTreasury.sol";
import {IWusdLotto3DTreasury} from "./IWusdLotto3DTreasury.sol";
import {ILotto3DGame} from "../../lotto3d/interfaces/ILotto3DGame.sol";
import {Lotto3DPrizeMath} from "../../lotto3d/libraries/Lotto3DPrizeMath.sol";

/// @title WusdLotto3DGame
/// @notice 使用统一 WUSD 内部余额的 3D 彩票状态机。
/// @dev 不持有或识别 USDT/USDC 地址；购票、派奖和退款均为 WUSD Ledger 内部转账。
contract WusdLotto3DGame is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    ILotto3DGame,
    IGameModuleV4
{
    using Lotto3DPrizeMath for uint16;

    // ─── Roles ──────────────────────────────────────────────────────────
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant VRF_ROLE = keccak256("VRF_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    // ─── Constants ──────────────────────────────────────────────────────
    uint256 public constant MAX_TICKETS_PER_ADDRESS = 10;
    uint256 public constant MAX_BATCH_SIZE = 100;
    uint256 public constant RELEASE_INTERVAL = 10;
    uint256 public constant PRIZE1_BPS = 5000; // 50% of prize pool
    uint256 public constant PRIZE2_BPS = 3000; // 30% of prize pool
    uint256 public constant PRIZE3_BPS = 2000; // 20% of prize pool
    uint256 public constant BPS_BASE = 10000;
    uint64 public constant DEFAULT_CLAIM_PERIOD = 90 days;

    // ─── Errors ─────────────────────────────────────────────────────────
    error ZeroAddress();
    error ZeroAmount();
    error InvalidRound();
    error RoundAlreadyExists();
    error RoundNotOpen();
    error RoundNotSettled();
    error RoundNotCancelled();
    error InvalidNumber();
    error MaxTicketsReached();
    error InvalidConfig();
    error AlreadyClaimed();
    error AlreadyRefunded();
    error NotTicketOwner();
    error NoPrize();
    error SalesNotClosed();
    error RoundAlreadySettled();
    error RoundAlreadyCancelled();
    error OnlyLedger();
    error PurchaseAmountMismatch();
    error UnsupportedBeneficiary();
    error PrizeClaimExpired(uint40 roundId);
    error ClaimPeriodOutOfRange();
    error InvalidRevenueAllocation();
    error InvalidRoundOrder();
    error PreviousRoundUnresolved(uint40 previousRoundId);

    // ─── Structs ────────────────────────────────────────────────────────
    struct TicketData {
        address buyer;
        uint40 roundId;
        uint16 number;
        bool claimed;
        bool refunded;
    }

    // ─── State ──────────────────────────────────────────────────────────
    IUnifiedLedgerV4 public ledger;
    IWusdLotto3DTreasury public treasury;
    uint256 public ticketPrice;
    uint256 public nextTicketId;

    mapping(uint40 roundId => RoundData) private _rounds;
    mapping(uint256 ticketId => TicketData) public tickets;
    mapping(uint40 roundId => mapping(address user => uint256 count)) public ticketsPerAddress;

    mapping(uint40 roundId => mapping(uint16 number => uint256 units)) public exactUnits;
    mapping(uint40 roundId => mapping(uint16 comboKey => uint256 units)) public comboUnits;
    mapping(uint40 roundId => mapping(uint16 pairKey => uint256 units)) public pairUnits;
    uint256 public purchaseReceiptNonce;
    uint64 public claimPeriod;
    mapping(uint40 roundId => uint64 period) public roundClaimPeriodSnapshot;
    mapping(uint40 roundId => uint64 deadline) public roundClaimDeadline;
    mapping(uint40 roundId => bool enabled) public liabilityAccountingEnabled;
    uint40 public latestRoundId;
    uint40 public roundSequenceCount;
    mapping(uint40 roundId => uint40 previous) public previousRoundId;
    mapping(uint40 roundId => uint40 sequence) public roundSequence;

    event LedgerPurchase(
        bytes32 indexed receiptId, uint40 indexed roundId, address indexed payer, address beneficiary, uint256 amount
    );
    event ClaimPeriodUpdated(uint64 previousPeriod, uint64 newPeriod);
    event RoundClaimsExpired(uint40 indexed roundId, uint256 recycledAmount);

    // ─── Initializer ────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin_, IUnifiedLedgerV4 ledger_, IWusdLotto3DTreasury treasury_, uint256 ticketPrice_)
        public
        initializer
    {
        if (admin_ == address(0) || address(ledger_) == address(0) || address(treasury_) == address(0)) {
            revert ZeroAddress();
        }
        if (ticketPrice_ == 0) revert ZeroAmount();

        __AccessControl_init();
        __Pausable_init();

        ledger = ledger_;
        treasury = treasury_;
        ticketPrice = ticketPrice_;
        claimPeriod = DEFAULT_CLAIM_PERIOD;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
    }

    // ─── Round Management ───────────────────────────────────────────────

    function createRound(uint40 roundId, RoundConfig calldata config) external {
        if (!hasRole(ADMIN_ROLE, msg.sender) && !hasRole(KEEPER_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, ADMIN_ROLE);
        }
        if (roundId == 0) revert InvalidRound();
        if (roundId <= latestRoundId) revert InvalidRoundOrder();
        if (_rounds[roundId].exists) revert RoundAlreadyExists();
        if (config.salesOpenTime >= config.salesCloseTime || config.salesCloseTime >= config.drawDeadline) {
            revert InvalidConfig();
        }

        treasury.snapshotRoundAllocation(roundId);

        RoundData storage rd = _rounds[roundId];
        rd.exists = true;
        rd.status = RoundStatus.Open;
        rd.config = config;
        roundClaimPeriodSnapshot[roundId] = _effectiveClaimPeriod();
        previousRoundId[roundId] = latestRoundId;
        latestRoundId = roundId;
        roundSequenceCount++;
        roundSequence[roundId] = roundSequenceCount;

        emit RoundCreated(roundId, config.salesOpenTime, config.salesCloseTime);
    }

    // ─── Ticket Purchase ────────────────────────────────────────────────

    function protocolImplementationHash() external view returns (bytes32) {
        return ERC1967Utils.getImplementation().codehash;
    }

    function quotePurchase(address, address beneficiary, bytes calldata purchaseData)
        external
        view
        returns (uint256 amount)
    {
        (uint40 roundId, uint16[] memory numbers) = abi.decode(purchaseData, (uint40, uint16[]));
        _validatePurchase(beneficiary, roundId, numbers);
        amount = ticketPrice * numbers.length;
    }

    function purchaseFromLedgerV4(
        address payer,
        address beneficiary,
        uint256 amount,
        IGameModuleV4.PurchaseContext calldata context,
        bytes calldata purchaseData
    ) external nonReentrant whenNotPaused returns (bytes32 receiptId, uint32 allocationVersion, uint16 partnerBps) {
        if (msg.sender != address(ledger)) revert OnlyLedger();
        if (payer != beneficiary) revert UnsupportedBeneficiary();

        (uint40 roundId, uint16[] memory numbers) = abi.decode(purchaseData, (uint40, uint16[]));
        IRevenueAllocationTreasury.RoundRevenueAllocation memory allocation_ = _requireRevenueAllocation(roundId);
        RoundData storage rd = _validatePurchase(beneficiary, roundId, numbers);
        uint256 expectedAmount = ticketPrice * numbers.length;
        if (amount != expectedAmount) revert PurchaseAmountMismatch();

        for (uint256 i = 0; i < numbers.length; i++) {
            _recordTicket(beneficiary, roundId, numbers[i], rd);
        }

        treasury.reserveForRefund(amount);
        uint256 receiptNonce = ++purchaseReceiptNonce;
        receiptId = keccak256(
            abi.encode(
                address(this),
                roundId,
                payer,
                beneficiary,
                amount,
                context.wfOrderId,
                context.partnerCode,
                allocation_.version,
                receiptNonce
            )
        );
        allocationVersion = allocation_.version;
        partnerBps = allocation_.partnerBps;
        emit LedgerPurchase(receiptId, roundId, payer, beneficiary, amount);
    }

    function _requireRevenueAllocation(uint40 roundId)
        internal
        view
        returns (IRevenueAllocationTreasury.RoundRevenueAllocation memory allocation_)
    {
        allocation_ = treasury.roundRevenueAllocation(roundId);
        if (!allocation_.snapshotted) revert InvalidRevenueAllocation();
    }

    function _validatePurchase(address buyer, uint40 roundId, uint16[] memory numbers)
        internal
        view
        returns (RoundData storage rd)
    {
        uint256 length = numbers.length;
        if (length == 0) revert ZeroAmount();
        if (length > MAX_BATCH_SIZE) revert MaxTicketsReached();

        rd = _rounds[roundId];
        if (!rd.exists || rd.status != RoundStatus.Open) revert RoundNotOpen();
        if (block.timestamp < rd.config.salesOpenTime || block.timestamp > rd.config.salesCloseTime) {
            revert RoundNotOpen();
        }
        if (ticketsPerAddress[roundId][buyer] + length > MAX_TICKETS_PER_ADDRESS) revert MaxTicketsReached();

        for (uint256 i = 0; i < length; i++) {
            if (!Lotto3DPrizeMath.isValidNumber(numbers[i])) revert InvalidNumber();
        }
    }

    function _recordTicket(address buyer, uint40 roundId, uint16 number, RoundData storage rd) internal {
        unchecked {
            ++nextTicketId;
        }
        uint256 ticketId = nextTicketId;

        tickets[ticketId] =
            TicketData({buyer: buyer, roundId: roundId, number: number, claimed: false, refunded: false});

        ticketsPerAddress[roundId][buyer]++;
        rd.totalSales += ticketPrice;
        rd.totalTickets++;

        exactUnits[roundId][number]++;
        comboUnits[roundId][Lotto3DPrizeMath.comboKey(number)]++;

        (uint16 key01, uint16 key02, uint16 key12) = Lotto3DPrizeMath.pairKeys(number);
        pairUnits[roundId][key01]++;
        pairUnits[roundId][key02]++;
        pairUnits[roundId][key12]++;

        emit TicketPurchased(ticketId, roundId, buyer, number);
    }

    // ─── Sales Close ────────────────────────────────────────────────────

    function closeSales(uint40 roundId) external {
        RoundData storage rd = _rounds[roundId];
        if (!rd.exists) revert InvalidRound();
        if (rd.status != RoundStatus.Open) revert RoundNotOpen();

        if (!hasRole(ADMIN_ROLE, msg.sender) && !hasRole(KEEPER_ROLE, msg.sender)) {
            if (block.timestamp <= rd.config.salesCloseTime) revert RoundNotOpen();
        }

        rd.status = RoundStatus.SalesClosed;
        emit SalesClosed(roundId);
    }

    // ─── Settlement (called by VRF Adapter) ─────────────────────────────

    /// @inheritdoc ILotto3DGame
    function settleDraw(uint40 roundId, uint16 winningNumber) external onlyRole(VRF_ROLE) nonReentrant {
        RoundData storage rd = _rounds[roundId];
        if (!rd.exists) revert InvalidRound();
        if (rd.status == RoundStatus.Settled) revert RoundAlreadySettled();
        if (rd.status == RoundStatus.Cancelled) revert RoundAlreadyCancelled();
        if (!Lotto3DPrizeMath.isValidNumber(winningNumber)) revert InvalidNumber();
        if (block.timestamp <= rd.config.salesCloseTime) revert SalesNotClosed();

        uint40 previous = previousRoundId[roundId];
        while (previous != 0) {
            RoundStatus previousStatus = _rounds[previous].status;
            if (previousStatus == RoundStatus.Settled) break;
            if (previousStatus != RoundStatus.Cancelled) revert PreviousRoundUnresolved(previous);
            previous = previousRoundId[previous];
        }

        if (rd.status == RoundStatus.Open) {
            rd.status = RoundStatus.SalesClosed;
            emit SalesClosed(roundId);
        }

        if (rd.totalSales > 0) {
            treasury.collectSales(roundId, rd.totalSales);
        }

        uint40 sequence = roundSequence[roundId];
        bool isReleaseRound = ((sequence == 0 ? roundId : sequence) % RELEASE_INTERVAL == 0);

        uint256 prizePool = treasury.settleRoundPrize(roundId, isReleaseRound);

        uint256 winUnits1 = exactUnits[roundId][winningNumber];

        uint256 winUnits2 = 0;
        if (!Lotto3DPrizeMath.isTriple(winningNumber)) {
            uint16 cKey = Lotto3DPrizeMath.comboKey(winningNumber);
            uint256 comboTotal = comboUnits[roundId][cKey];
            winUnits2 = comboTotal > winUnits1 ? comboTotal - winUnits1 : 0;
        }

        (uint16 wKey01, uint16 wKey02, uint16 wKey12) = Lotto3DPrizeMath.pairKeys(winningNumber);
        uint256 pairTotal = pairUnits[roundId][wKey01] + pairUnits[roundId][wKey02] + pairUnits[roundId][wKey12];

        uint256 tier2PairOvercount = _computeTier2PairOvercount(roundId, winningNumber, winUnits1);
        uint256 overcount = winUnits1 * 3 + tier2PairOvercount;
        uint256 winUnits3 = pairTotal > overcount ? pairTotal - overcount : 0;

        uint256 pool1 = (prizePool * PRIZE1_BPS) / BPS_BASE;
        uint256 pool2 = (prizePool * PRIZE2_BPS) / BPS_BASE;
        uint256 pool3 = prizePool - pool1 - pool2;

        uint256 prize1PerUnit = winUnits1 > 0 ? pool1 / winUnits1 : 0;
        uint256 prize2PerUnit = winUnits2 > 0 ? pool2 / winUnits2 : 0;
        uint256 prize3PerUnit = winUnits3 > 0 ? pool3 / winUnits3 : 0;
        uint256 winnerLiability = prize1PerUnit * winUnits1 + prize2PerUnit * winUnits2 + prize3PerUnit * winUnits3;
        uint64 deadline = uint64(block.timestamp + _roundClaimPeriod(roundId));

        treasury.finalizeRoundAccounting(roundId, deadline, winnerLiability);
        liabilityAccountingEnabled[roundId] = true;
        roundClaimDeadline[roundId] = deadline;

        rd.status = RoundStatus.Settled;
        rd.winningNumber = winningNumber;
        rd.prizePool = prizePool;
        rd.prize1PerUnit = prize1PerUnit;
        rd.prize2PerUnit = prize2PerUnit;
        rd.prize3PerUnit = prize3PerUnit;
        rd.winUnits1 = winUnits1;
        rd.winUnits2 = winUnits2;
        rd.winUnits3 = winUnits3;

        emit RoundSettled(
            roundId,
            winningNumber,
            prizePool,
            prize1PerUnit,
            prize2PerUnit,
            prize3PerUnit,
            winUnits1,
            winUnits2,
            winUnits3
        );
    }

    // ─── Claim ──────────────────────────────────────────────────────────

    function claim(uint256 ticketId) external nonReentrant {
        TicketData storage ticket = tickets[ticketId];
        if (ticket.buyer == address(0)) revert InvalidRound();
        if (ticket.buyer != msg.sender) revert NotTicketOwner();
        if (ticket.claimed) revert AlreadyClaimed();

        RoundData storage rd = _rounds[ticket.roundId];
        if (rd.status != RoundStatus.Settled) revert RoundNotSettled();
        _requireClaimOpen(ticket.roundId);

        uint8 tier = Lotto3DPrizeMath.highestTier(ticket.number, rd.winningNumber);
        if (tier == 0) revert NoPrize();

        uint256 amount;
        if (tier == 1) amount = rd.prize1PerUnit;
        else if (tier == 2) amount = rd.prize2PerUnit;
        else amount = rd.prize3PerUnit;

        if (amount == 0) revert NoPrize();

        ticket.claimed = true;
        treasury.payRoundClaim(ticket.roundId, msg.sender, amount);

        emit PrizeClaimed(ticketId, ticket.roundId, msg.sender, tier, amount);
    }

    /// @notice Batch claim multiple tickets.
    function batchClaim(uint256[] calldata ticketIds) external nonReentrant {
        if (ticketIds.length == 0) revert ZeroAmount();
        if (ticketIds.length > MAX_TICKETS_PER_ADDRESS) revert MaxTicketsReached();

        uint40[] memory roundIds = new uint40[](ticketIds.length);
        uint256[] memory amounts = new uint256[](ticketIds.length);
        uint256 roundClaimCount;
        for (uint256 i = 0; i < ticketIds.length; i++) {
            (uint40 roundId, uint256 amount) = _claimInternal(ticketIds[i]);
            if (amount == 0) continue;
            roundIds[roundClaimCount] = roundId;
            amounts[roundClaimCount] = amount;
            roundClaimCount++;
        }

        if (roundClaimCount > 0) {
            assembly ("memory-safe") {
                mstore(roundIds, roundClaimCount)
                mstore(amounts, roundClaimCount)
            }
            treasury.payRoundClaims(roundIds, msg.sender, amounts);
        }
    }

    function _claimInternal(uint256 ticketId) internal returns (uint40 roundId, uint256 amount) {
        TicketData storage ticket = tickets[ticketId];
        if (ticket.buyer == address(0)) revert InvalidRound();
        if (ticket.buyer != msg.sender) revert NotTicketOwner();
        if (ticket.claimed) revert AlreadyClaimed();

        RoundData storage rd = _rounds[ticket.roundId];
        if (rd.status != RoundStatus.Settled) revert RoundNotSettled();
        _requireClaimOpen(ticket.roundId);
        roundId = ticket.roundId;

        uint8 tier = Lotto3DPrizeMath.highestTier(ticket.number, rd.winningNumber);
        if (tier == 0) return (roundId, 0);

        if (tier == 1) amount = rd.prize1PerUnit;
        else if (tier == 2) amount = rd.prize2PerUnit;
        else amount = rd.prize3PerUnit;

        if (amount == 0) return (roundId, 0);

        ticket.claimed = true;

        emit PrizeClaimed(ticketId, ticket.roundId, msg.sender, tier, amount);
    }

    // ─── Cancel & Refund ────────────────────────────────────────────────

    function cancelRound(uint40 roundId) external onlyRole(ADMIN_ROLE) {
        _cancelRound(roundId);
    }

    function cancelTimedOutRound(uint40 roundId) external {
        if (!hasRole(VRF_ROLE, msg.sender) && !hasRole(KEEPER_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, VRF_ROLE);
        }
        RoundData storage rd = _rounds[roundId];
        if (!rd.exists) revert InvalidRound();
        if (block.timestamp <= rd.config.drawDeadline) revert SalesNotClosed();
        _cancelRound(roundId);
    }

    function _cancelRound(uint40 roundId) internal {
        RoundData storage rd = _rounds[roundId];
        if (!rd.exists) revert InvalidRound();
        if (rd.status == RoundStatus.Settled) revert RoundAlreadySettled();
        if (rd.status == RoundStatus.Cancelled) revert RoundAlreadyCancelled();

        rd.status = RoundStatus.Cancelled;

        emit RoundCancelled(roundId);
    }

    function refundTicket(uint256 ticketId) external nonReentrant {
        TicketData storage ticket = tickets[ticketId];
        if (ticket.buyer == address(0)) revert InvalidRound();
        if (ticket.refunded) revert AlreadyRefunded();

        RoundData storage rd = _rounds[ticket.roundId];
        if (rd.status != RoundStatus.Cancelled) revert RoundNotCancelled();

        ticket.refunded = true;
        treasury.payRefund(ticket.buyer, ticketPrice);

        emit TicketRefunded(ticketId, ticket.roundId, ticket.buyer, ticketPrice);
    }

    // ─── View ───────────────────────────────────────────────────────────

    function getRound(uint40 roundId) external view returns (RoundData memory) {
        return _rounds[roundId];
    }

    function isRoundSettled(uint40 roundId) external view returns (bool) {
        return _rounds[roundId].status == RoundStatus.Settled;
    }

    function expireRoundClaims(uint40 roundId) external returns (uint256 recycledAmount) {
        if (!liabilityAccountingEnabled[roundId]) revert RoundNotSettled();
        recycledAmount = treasury.expireRoundClaims(roundId);
        emit RoundClaimsExpired(roundId, recycledAmount);
    }

    // ─── Internal Helpers ───────────────────────────────────────────────

    function _computeTier2PairOvercount(
        uint40 roundId,
        uint16 winningNumber,
        uint256 /* winUnits1 */
    )
        internal
        view
        returns (uint256 totalOvercount)
    {
        (uint16 wKey01, uint16 wKey02, uint16 wKey12) = Lotto3DPrizeMath.pairKeys(winningNumber);

        uint16[6] memory perms = Lotto3DPrizeMath.allPermutations(winningNumber);
        uint256 permCount = Lotto3DPrizeMath.uniquePermCount(winningNumber);

        for (uint256 i = 0; i < permCount; i++) {
            uint16 perm = perms[i];
            if (perm == winningNumber) continue;

            uint256 units = exactUnits[roundId][perm];
            if (units == 0) continue;

            (uint16 pKey01, uint16 pKey02, uint16 pKey12) = Lotto3DPrizeMath.pairKeys(perm);
            uint256 shared = 0;
            if (pKey01 == wKey01) shared++;
            if (pKey02 == wKey02) shared++;
            if (pKey12 == wKey12) shared++;

            totalOvercount += units * shared;
        }
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function setClaimPeriod(uint64 newPeriod) external onlyRole(ADMIN_ROLE) whenPaused {
        if (newPeriod < 1 days || newPeriod > 365 days) revert ClaimPeriodOutOfRange();
        uint64 previous = _effectiveClaimPeriod();
        claimPeriod = newPeriod;
        emit ClaimPeriodUpdated(previous, newPeriod);
    }

    function _effectiveClaimPeriod() internal view returns (uint64) {
        return claimPeriod == 0 ? DEFAULT_CLAIM_PERIOD : claimPeriod;
    }

    function _roundClaimPeriod(uint40 roundId) internal view returns (uint64) {
        uint64 snapshot = roundClaimPeriodSnapshot[roundId];
        return snapshot == 0 ? DEFAULT_CLAIM_PERIOD : snapshot;
    }

    function _requireClaimOpen(uint40 roundId) internal view {
        if (liabilityAccountingEnabled[roundId] && block.timestamp > roundClaimDeadline[roundId]) {
            revert PrizeClaimExpired(roundId);
        }
    }

    function _authorizeUpgrade(address) internal override onlyRole(ADMIN_ROLE) {}
}
