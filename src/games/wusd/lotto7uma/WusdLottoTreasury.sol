// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IUnifiedLedgerV2} from "../../../wusd/IUnifiedLedgerV2.sol";
import {IProtocolRevenueRouter} from "../../../protocol/IProtocolRevenueRouter.sol";
import {IRevenueAllocationTreasury} from "../../../protocol/IRevenueAllocationTreasury.sol";
import {RevenueAllocationLib} from "../../../protocol/RevenueAllocationLib.sol";
import {ILottoTreasury} from "../../lotto7uma/interfaces/ILottoTreasury.sol";
import {IWusdLottoUmaRevenueTreasury} from "./IWusdLottoUmaRevenueTreasury.sol";

/// @title WusdLottoTreasury
/// @notice Manages the World Lotto carry pool, reserves, revenue, and prize payouts.
/// @dev The ledger administrator must register the treasury and rounds contracts.
///      Fund sources must approve the appropriate contract before transferring WUSD.
///
/// Carry model:
/// - A single `carryPool` accumulates all unawarded floating-tier prize money.
/// - Each settlement, `LottoSettlement` splits the pool into per-tier
///   allocations (50/30/20), computes payouts, and applies the next carryPool.
/// - The settlement contract enforces the payout formula from on-chain ticket
///   counters; this treasury enforces liability accounting and overflow rules.
contract WusdLottoTreasury is
    Initializable,
    AccessControlUpgradeable,
    ILottoTreasury,
    IWusdLottoUmaRevenueTreasury,
    PausableUpgradeable,
    ReentrancyGuard,
    UUPSUpgradeable
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");
    bytes32 public constant ROUNDS_ROLE = keccak256("ROUNDS_ROLE");
    bytes32 public constant OPS_ROLE = keccak256("OPS_ROLE");
    bytes32 public constant DIVIDEND_ROLE = keccak256("DIVIDEND_ROLE");
    bytes32 public constant FUND_ROLE = keccak256("FUND_ROLE");
    bytes32 public constant REVENUE_SETTLER_ROLE = keccak256("REVENUE_SETTLER_ROLE");

    uint256 public constant OVERFLOW_THRESHOLD = 500_000_000 * 1e6; // 500M U (assuming 6 decimals)
    uint256 public constant OVERFLOW_BPS = 5000; // 50%
    uint256 public constant OPS_BPS = 1500; // 15%
    uint256 public constant DIVIDEND_BPS = 500; // 5%

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance();
    error RoundAlreadyReserved();
    error RoundNotReserved();
    error ClaimWindowClosed();
    error ClaimWindowOpen();
    error RevenueNotConfigured();
    error RoundAllocationAlreadySnapshotted();
    error RoundAllocationNotSnapshotted();
    error RevenueAlreadyFinalized();
    error PartnerBatchAlreadyProcessed();
    error InvalidPartnerBatch();

    IUnifiedLedgerV2 public ledger;
    uint256 public tokenUnit;

    uint256 public reserveBalance;
    uint256 public claimsPaid;

    /// @notice Unified carry pool - all unawarded floating-tier prize money.
    uint256 public carryPool;

    /// @notice Maximum carry pool size. Excess is redirected to fund. 0 = no cap.
    uint256 public carryCap;

    /// @notice Accrued but unclaimed revenue for ops, dividend, and fund.
    uint256 public opsAccrued;
    uint256 public dividendAccrued;
    uint256 public fundAccrued;
    /// @dev UUPS storage additions must remain after every legacy field.
    uint256 public prizeReserve;
    /// @notice Ticket sales locked for full refunds until settlement.
    uint256 public refundReserve;
    mapping(uint40 roundId => uint256 amount) public roundPrizeLiability;
    mapping(uint40 roundId => uint64 deadline) public roundPrizeDeadline;
    mapping(uint40 roundId => bool expired) public roundPrizeExpired;
    mapping(uint40 roundId => bool reserved) public roundPrizeReserved;
    uint256 public activeRoundPrizeLiability;
    /// @dev V4 revenue storage additions. Never insert fields above this line.
    IProtocolRevenueRouter public revenueRouter;
    address public datRevenueVault;
    address public partnerPayoutSafe;
    address public opsRecipient;
    uint256 public partnerReserveAccrued;
    uint256 public datDistributed;
    mapping(uint256 roundId => IRevenueAllocationTreasury.RoundRevenueAllocation allocation) private
        _roundRevenueAllocations;
    mapping(uint256 roundId => bool finalized) public revenueFinalized;
    mapping(bytes32 batchId => bool processed) public partnerBatchProcessed;

    event ReserveDeposited(address indexed from, uint256 amount);
    event ReserveWithdrawn(address indexed to, uint256 amount);
    event CarryPoolSeeded(address indexed from, uint256 amount);
    event CarryApplied(uint256 carryApplied, uint256 overflowToFund);
    event RevenueCollected(uint256 totalSales, uint256 opsAmount, uint256 dividendAmount);
    event OpsClaimed(address indexed to, uint256 amount);
    event DividendClaimed(address indexed to, uint256 amount);
    event FundClaimed(address indexed to, uint256 amount);
    event ClaimPaid(address indexed to, uint256 amount);
    event RefundPaid(address indexed to, uint256 amount);
    event FixedPrizeRecycled(uint256 amount);
    event PrizeReserveUpdated(uint256 amount, uint256 newReserve);
    event RefundReserveUpdated(int256 delta, uint256 newReserve);
    event RoundPrizesReserved(uint40 indexed roundId, uint64 claimDeadline, uint256 amount);
    event RoundPrizeClaimed(uint40 indexed roundId, address indexed to, uint256 paid, uint256 recycled);
    event RoundPrizesExpired(uint40 indexed roundId, uint256 recycledAmount);
    event RoundAllocationSnapshotted(
        uint256 indexed roundId,
        uint32 indexed version,
        uint16 prizeBps,
        uint16 datBps,
        uint16 partnerBps,
        uint16 opsBps
    );
    event RoundRevenueFinalized(
        bytes32 indexed sourceKey,
        uint256 indexed roundId,
        uint32 indexed allocationVersion,
        uint256 finalNetSales,
        uint256 prizeAmount,
        uint256 datAmount,
        uint256 partnerAmount,
        uint256 opsAmount
    );
    event PartnerReserveSettled(
        bytes32 indexed batchId,
        bytes32 indexed attributionRoot,
        uint256 partnerPayable,
        uint256 wfFallback,
        uint256 reserveRemaining
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin_,
        IUnifiedLedgerV2 ledger_,
        uint256 tokenUnit_,
        address ops_,
        address dividend_,
        address fund_
    ) public initializer {
        if (
            admin_ == address(0) || address(ledger_) == address(0) || ops_ == address(0) || dividend_ == address(0)
                || fund_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (tokenUnit_ == 0) {
            revert ZeroAmount();
        }

        __AccessControl_init();
        __Pausable_init();

        ledger = ledger_;
        tokenUnit = tokenUnit_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
        _grantRole(OPS_ROLE, ops_);
        _grantRole(DIVIDEND_ROLE, dividend_);
        _grantRole(FUND_ROLE, fund_);
    }

    function syncLedgerAllowance() external onlyRole(ADMIN_ROLE) {
        ledger.approveOperator(address(this), type(uint256).max);
    }

    function initializeRevenue(
        IProtocolRevenueRouter router_,
        address datVault_,
        address partnerPayoutSafe_,
        address opsRecipient_,
        address revenueSettler_
    ) external reinitializer(2) onlyRole(ADMIN_ROLE) {
        if (
            address(router_) == address(0) || address(router_).code.length == 0 || datVault_ == address(0)
                || datVault_.code.length == 0 || partnerPayoutSafe_ == address(0) || opsRecipient_ == address(0)
                || revenueSettler_ == address(0)
        ) revert ZeroAddress();
        revenueRouter = router_;
        datRevenueVault = datVault_;
        partnerPayoutSafe = partnerPayoutSafe_;
        opsRecipient = opsRecipient_;
        _grantRole(REVENUE_SETTLER_ROLE, revenueSettler_);
    }

    function snapshotRoundAllocation(uint256 roundId)
        external
        onlyRole(ROUNDS_ROLE)
        returns (IRevenueAllocationTreasury.RoundRevenueAllocation memory snapshot)
    {
        if (address(revenueRouter) == address(0)) revert RevenueNotConfigured();
        if (_roundRevenueAllocations[roundId].snapshotted) revert RoundAllocationAlreadySnapshotted();
        IProtocolRevenueRouter.RevenueAllocation memory active = revenueRouter.activeAllocation();
        snapshot = IRevenueAllocationTreasury.RoundRevenueAllocation({
            prizeBps: active.prizeBps,
            datBps: active.datBps,
            partnerBps: active.partnerBps,
            opsBps: active.opsBps,
            version: active.version,
            snapshotted: true
        });
        _roundRevenueAllocations[roundId] = snapshot;
        emit RoundAllocationSnapshotted(
            roundId, active.version, active.prizeBps, active.datBps, active.partnerBps, active.opsBps
        );
    }

    function roundRevenueAllocation(uint256 roundId)
        external
        view
        returns (IRevenueAllocationTreasury.RoundRevenueAllocation memory)
    {
        return _roundRevenueAllocations[roundId];
    }

    function previewRoundPrize(uint256 roundId, uint256 totalSales) public view returns (uint256 prizeAmount) {
        IRevenueAllocationTreasury.RoundRevenueAllocation memory allocation_ = _roundRevenueAllocations[roundId];
        if (!allocation_.snapshotted) revert RoundAllocationNotSnapshotted();
        (prizeAmount,,,) =
            RevenueAllocationLib.split(totalSales, allocation_.prizeBps, allocation_.datBps, allocation_.partnerBps);
    }

    function finalizeRoundRevenue(uint256 roundId, uint256 totalSales)
        external
        onlyRole(SETTLEMENT_ROLE)
        whenNotPaused
        nonReentrant
        returns (uint256 prizeAmount)
    {
        if (revenueFinalized[roundId]) revert RevenueAlreadyFinalized();
        IRevenueAllocationTreasury.RoundRevenueAllocation memory allocation_ = _roundRevenueAllocations[roundId];
        if (!allocation_.snapshotted) revert RoundAllocationNotSnapshotted();

        revenueFinalized[roundId] = true;
        (uint256 calculatedPrize, uint256 datAmount, uint256 partnerAmount, uint256 opsAmount) =
            RevenueAllocationLib.split(totalSales, allocation_.prizeBps, allocation_.datBps, allocation_.partnerBps);
        prizeAmount = calculatedPrize;
        opsAccrued += opsAmount;
        partnerReserveAccrued += partnerAmount;
        if (datAmount > 0) {
            datDistributed += datAmount;
            ledger.operatorTransfer(address(this), datRevenueVault, datAmount);
        }
        _requireSolvent();

        bytes32 sourceKey =
            keccak256(abi.encode(block.chainid, address(this), keccak256("LOTTO7_UMA"), roundId, allocation_.version));
        emit RoundRevenueFinalized(
            sourceKey, roundId, allocation_.version, totalSales, prizeAmount, datAmount, partnerAmount, opsAmount
        );
    }

    /// @dev The caller must approve this treasury as a ledger operator first.
    function depositReserve(uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) {
            revert ZeroAmount();
        }

        ledger.operatorTransfer(msg.sender, address(this), amount);
        reserveBalance += amount;
        _requireSolvent();

        emit ReserveDeposited(msg.sender, amount);
    }

    /// @notice Inject funds directly into the carry pool (prize pool).
    ///         Used for initial seeding (e.g. a 2M WUSD launch fund).
    function seedCarryPool(uint256 amount) external onlyRole(ADMIN_ROLE) whenNotPaused nonReentrant {
        if (amount == 0) {
            revert ZeroAmount();
        }

        ledger.operatorTransfer(msg.sender, address(this), amount);
        carryPool += amount;
        _requireSolvent();

        emit CarryPoolSeeded(msg.sender, amount);
    }

    function withdrawReserve(address to, uint256 amount) external onlyRole(ADMIN_ROLE) whenNotPaused nonReentrant {
        if (to == address(0)) {
            revert ZeroAddress();
        }
        if (amount == 0) {
            revert ZeroAmount();
        }
        if (amount > reserveBalance || amount > ledger.balanceOf(address(this))) {
            revert InsufficientBalance();
        }

        reserveBalance -= amount;
        _requireSolventAfterTransfer(amount);
        ledger.operatorTransfer(address(this), to, amount);

        emit ReserveWithdrawn(to, amount);
    }

    /// @notice Set the maximum carry pool size. Excess overflows to fund.
    function setCarryCap(uint256 cap) external onlyRole(ADMIN_ROLE) {
        carryCap = cap;
    }

    function collectRevenue(uint256 totalSales) external whenNotPaused nonReentrant {
        if (!hasRole(ROUNDS_ROLE, msg.sender) && !hasRole(SETTLEMENT_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, ROUNDS_ROLE);
        }
        uint256 opsAmount = (totalSales * OPS_BPS) / 10000;
        uint256 divAmount = (totalSales * DIVIDEND_BPS) / 10000;

        opsAccrued += opsAmount;
        dividendAccrued += divAmount;
        _requireSolvent();

        emit RevenueCollected(totalSales, opsAmount, divAmount);
    }

    /// @notice Returns the current unified carry pool balance.
    function currentCarryPool() external view returns (uint256) {
        return carryPool;
    }

    function reserveRefunds(uint256 amount) external onlyRole(ROUNDS_ROLE) whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        refundReserve += amount;
        _requireSolvent();
        emit RefundReserveUpdated(int256(amount), refundReserve);
    }

    function releaseRefundsForSettlement(uint256 amount) external onlyRole(SETTLEMENT_ROLE) whenNotPaused {
        if (amount == 0) return;
        if (amount > refundReserve) revert InsufficientBalance();
        refundReserve -= amount;
        emit RefundReserveUpdated(-int256(amount), refundReserve);
    }

    function reservePrizes(uint256 amount) external onlyRole(SETTLEMENT_ROLE) whenNotPaused {
        if (amount == 0) return;
        prizeReserve += amount;
        _requireSolvent();
        emit PrizeReserveUpdated(amount, prizeReserve);
    }

    function reserveRoundPrizes(uint40 roundId, uint64 claimDeadline, uint256 amount)
        external
        onlyRole(SETTLEMENT_ROLE)
        whenNotPaused
    {
        if (roundPrizeReserved[roundId]) revert RoundAlreadyReserved();
        if (claimDeadline <= block.timestamp) revert ClaimWindowClosed();

        roundPrizeReserved[roundId] = true;
        roundPrizeDeadline[roundId] = claimDeadline;
        roundPrizeLiability[roundId] = amount;
        activeRoundPrizeLiability += amount;
        prizeReserve += amount;
        _requireSolvent();

        emit RoundPrizesReserved(roundId, claimDeadline, amount);
        emit PrizeReserveUpdated(amount, prizeReserve);
    }

    /// @notice Apply the carry calculated by the on-chain settlement contract.
    /// @param carryProposed The total carry pool calculated for the next round.
    /// @return carryApplied The actual carry after cap and overflow rules.
    /// @return overflowToFund The amount redirected to fund due to cap/overflow.
    function applySettlementCarry(uint256 carryProposed)
        external
        onlyRole(SETTLEMENT_ROLE)
        whenNotPaused
        nonReentrant
        returns (uint256 carryApplied, uint256 overflowToFund)
    {
        uint256 capOverflow = 0;

        // 1. Apply carry cap
        if (carryCap > 0 && carryProposed > carryCap) {
            capOverflow = carryProposed - carryCap;
            carryProposed = carryCap;
        }

        uint256 globalOverflow = 0;

        // 2. Apply 500M threshold overflow rule
        //    If the pool already exceeds the threshold and is growing,
        //    redirect OVERFLOW_BPS% of the net increase to fund.
        if (carryPool > OVERFLOW_THRESHOLD && carryProposed > carryPool) {
            uint256 netRollover = carryProposed - carryPool;
            globalOverflow = (netRollover * OVERFLOW_BPS) / 10000;
            carryApplied = carryProposed - globalOverflow;
        } else {
            carryApplied = carryProposed;
        }

        overflowToFund = capOverflow + globalOverflow;

        // Effects before interactions (CEI pattern)
        carryPool = carryApplied;

        emit CarryApplied(carryApplied, overflowToFund);

        // Accrue fund overflow (recipients claim via claimFund)
        if (overflowToFund > 0) {
            fundAccrued += overflowToFund;
        }
        _requireSolvent();
    }

    function recycleToCarryPool(uint256 amount) external onlyRole(SETTLEMENT_ROLE) whenNotPaused nonReentrant {
        if (amount == 0) {
            return;
        }
        if (amount > prizeReserve) revert InsufficientBalance();
        prizeReserve -= amount;
        carryPool += amount;
        emit FixedPrizeRecycled(amount);
    }

    function payClaim(address to, uint256 amount) external onlyRole(SETTLEMENT_ROLE) whenNotPaused nonReentrant {
        if (to == address(0)) {
            revert ZeroAddress();
        }
        if (amount == 0) {
            revert ZeroAmount();
        }
        if (amount > prizeReserve || amount > ledger.balanceOf(address(this))) {
            revert InsufficientBalance();
        }

        prizeReserve -= amount;
        ledger.operatorTransfer(address(this), to, amount);
        claimsPaid += amount;

        emit ClaimPaid(to, amount);
    }

    function payRoundClaim(uint40 roundId, address to, uint256 amount, uint256 recycledAmount)
        external
        onlyRole(SETTLEMENT_ROLE)
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (!roundPrizeReserved[roundId]) revert RoundNotReserved();
        if (roundPrizeExpired[roundId] || block.timestamp > roundPrizeDeadline[roundId]) {
            revert ClaimWindowClosed();
        }

        uint256 consumed = amount + recycledAmount;
        uint256 outstanding = roundPrizeLiability[roundId];
        if (consumed > outstanding || consumed > prizeReserve || amount > ledger.balanceOf(address(this))) {
            revert InsufficientBalance();
        }

        roundPrizeLiability[roundId] = outstanding - consumed;
        activeRoundPrizeLiability -= consumed;
        prizeReserve -= consumed;
        carryPool += recycledAmount;
        ledger.operatorTransfer(address(this), to, amount);
        claimsPaid += amount;

        emit RoundPrizeClaimed(roundId, to, amount, recycledAmount);
        emit ClaimPaid(to, amount);
        if (recycledAmount > 0) emit FixedPrizeRecycled(recycledAmount);
    }

    function expireRoundPrizes(uint40 roundId) external nonReentrant returns (uint256 recycledAmount) {
        if (!roundPrizeReserved[roundId]) revert RoundNotReserved();
        if (roundPrizeExpired[roundId]) revert ClaimWindowClosed();
        if (block.timestamp <= roundPrizeDeadline[roundId]) revert ClaimWindowOpen();

        recycledAmount = roundPrizeLiability[roundId];
        roundPrizeLiability[roundId] = 0;
        roundPrizeExpired[roundId] = true;
        activeRoundPrizeLiability -= recycledAmount;
        prizeReserve -= recycledAmount;
        carryPool += recycledAmount;

        emit RoundPrizesExpired(roundId, recycledAmount);
        if (recycledAmount > 0) emit FixedPrizeRecycled(recycledAmount);
    }

    function payRefund(address to, uint256 amount) external onlyRole(ROUNDS_ROLE) nonReentrant {
        if (to == address(0)) {
            revert ZeroAddress();
        }
        if (amount == 0) {
            revert ZeroAmount();
        }
        if (amount > refundReserve || amount > ledger.balanceOf(address(this))) {
            revert InsufficientBalance();
        }

        refundReserve -= amount;
        ledger.operatorTransfer(address(this), to, amount);

        emit RefundReserveUpdated(-int256(amount), refundReserve);
        emit RefundPaid(to, amount);
    }

    // --- Revenue Claims ------------------------------------------------

    /// @notice Claim accrued ops revenue. Only OPS_ROLE holders can call.
    function claimOps() external onlyRole(OPS_ROLE) whenNotPaused nonReentrant {
        uint256 amount = opsAccrued;
        if (amount == 0) revert ZeroAmount();
        if (amount > _claimableRevenue()) revert InsufficientBalance();

        opsAccrued = 0;
        ledger.operatorTransfer(address(this), msg.sender, amount);
        emit OpsClaimed(msg.sender, amount);
    }

    /// @notice Claim accrued dividend revenue. Only DIVIDEND_ROLE holders can call.
    function claimDividend() external onlyRole(DIVIDEND_ROLE) whenNotPaused nonReentrant {
        uint256 amount = dividendAccrued;
        if (amount == 0) revert ZeroAmount();
        if (amount > _claimableRevenue()) revert InsufficientBalance();

        dividendAccrued = 0;
        ledger.operatorTransfer(address(this), msg.sender, amount);
        emit DividendClaimed(msg.sender, amount);
    }

    /// @notice Claim accrued fund overflow. Only FUND_ROLE holders can call.
    function claimFund() external onlyRole(FUND_ROLE) whenNotPaused nonReentrant {
        uint256 amount = fundAccrued;
        if (amount == 0) revert ZeroAmount();
        if (amount > _claimableRevenue()) revert InsufficientBalance();

        fundAccrued = 0;
        ledger.operatorTransfer(address(this), msg.sender, amount);
        emit FundClaimed(msg.sender, amount);
    }

    function settlePartnerReserve(bytes32 batchId, bytes32 attributionRoot, uint256 partnerPayable, uint256 wfFallback)
        external
        onlyRole(REVENUE_SETTLER_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (batchId == bytes32(0) || attributionRoot == bytes32(0)) revert InvalidPartnerBatch();
        if (partnerBatchProcessed[batchId]) revert PartnerBatchAlreadyProcessed();
        uint256 total = partnerPayable + wfFallback;
        if (total == 0 || total > partnerReserveAccrued) revert InvalidPartnerBatch();

        partnerBatchProcessed[batchId] = true;
        partnerReserveAccrued -= total;
        if (partnerPayable > 0) ledger.operatorTransfer(address(this), partnerPayoutSafe, partnerPayable);
        if (wfFallback > 0) ledger.operatorTransfer(address(this), opsRecipient, wfFallback);

        _requireSolvent();
        emit PartnerReserveSettled(batchId, attributionRoot, partnerPayable, wfFallback, partnerReserveAccrued);
    }

    function _claimableRevenue() internal view returns (uint256) {
        uint256 available = ledger.balanceOf(address(this));
        if (available < totalLiabilities()) return 0;
        uint256 reserved = reserveBalance + refundReserve + carryPool + prizeReserve;
        return available > reserved ? available - reserved : 0;
    }

    function totalLiabilities() public view returns (uint256) {
        return reserveBalance + refundReserve + carryPool + prizeReserve + opsAccrued + dividendAccrued + fundAccrued
            + partnerReserveAccrued;
    }

    function surplusBalance() external view returns (uint256) {
        uint256 available = ledger.balanceOf(address(this));
        uint256 liabilities = totalLiabilities();
        return available > liabilities ? available - liabilities : 0;
    }

    function _requireSolvent() internal view {
        if (ledger.balanceOf(address(this)) < totalLiabilities()) revert InsufficientBalance();
    }

    function _requireSolventAfterTransfer(uint256 amount) internal view {
        uint256 available = ledger.balanceOf(address(this));
        if (amount > available || available - amount < totalLiabilities()) revert InsufficientBalance();
    }

    function _authorizeUpgrade(address) internal override onlyRole(ADMIN_ROLE) {}
}
