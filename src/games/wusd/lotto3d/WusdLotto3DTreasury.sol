// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IUnifiedLedgerV2} from "../../../wusd/IUnifiedLedgerV2.sol";
import {IProtocolRevenueRouter} from "../../../protocol/IProtocolRevenueRouter.sol";
import {IRevenueAllocationTreasury} from "../../../protocol/IRevenueAllocationTreasury.sol";
import {RevenueAllocationLib} from "../../../protocol/RevenueAllocationLib.sol";
import {ILotto3DTreasury} from "../../lotto3d/interfaces/ILotto3DTreasury.sol";
import {IWusdLotto3DTreasury} from "./IWusdLotto3DTreasury.sol";

/// @title WusdLotto3DTreasury
contract WusdLotto3DTreasury is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    IWusdLotto3DTreasury
{
    // --- Roles ----------------------------------------------------------
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant GAME_ROLE = keccak256("GAME_ROLE");
    bytes32 public constant OPS_ROLE = keccak256("OPS_ROLE");
    bytes32 public constant REVENUE_SETTLER_ROLE = keccak256("REVENUE_SETTLER_ROLE");

    // --- Constants ------------------------------------------------------
    uint256 public constant PRIZE_BPS = 5000; // 50% to current prize pool
    uint256 public constant ACCUMULATE_BPS = 3000; // 30% to accumulated pool
    uint256 public constant OPS_BPS = 2000; // 20% to ops
    uint256 public constant RELEASE_BPS = 3000; // release 30% of accumulated pool
    uint256 public constant BPS_BASE = 10000;

    // --- Errors ---------------------------------------------------------
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance();
    error AlreadyCollected();
    error RoundAlreadyFinalized();
    error RoundNotSettled();
    error ClaimWindowClosed();
    error ClaimWindowOpen();
    error LengthMismatch();
    error LegacyAccountingNotReconciled();
    error LegacyAccountingAlreadyReconciled();
    error RevenueNotConfigured();
    error RoundAllocationAlreadySnapshotted();
    error RoundAllocationNotSnapshotted();
    error PartnerBatchAlreadyProcessed();
    error InvalidPartnerBatch();

    // --- State ----------------------------------------------------------
    IUnifiedLedgerV2 public ledger;

    uint256 public accumulatedPool;
    uint256 public opsAccrued;
    uint256 public pendingPrize;
    uint256 public refundReserve;
    uint256 public unclaimedPrize;

    mapping(uint40 => bool) public salesCollected;
    mapping(uint40 => uint256) public roundPrizePool;
    mapping(uint40 => bool) public roundAccountingFinalized;
    mapping(uint40 => uint64) public roundClaimDeadline;
    mapping(uint40 => uint256) public roundOutstandingLiability;
    mapping(uint40 => bool) public roundClaimsExpired;
    uint256 public pendingRoundPrize;
    uint256 public activeWinnerLiability;
    bool public legacyAccountingReconciled;
    mapping(uint40 => bool) public roundPrizePrepared;
    /// @dev V4 revenue storage additions. Never insert fields above this line.
    IProtocolRevenueRouter public revenueRouter;
    address public datRevenueVault;
    address public partnerPayoutSafe;
    address public opsRecipient;
    uint256 public partnerReserveAccrued;
    uint256 public datDistributed;
    mapping(uint40 roundId => uint256 amount) public roundBasePrize;
    mapping(uint256 roundId => IRevenueAllocationTreasury.RoundRevenueAllocation allocation) private
        _roundRevenueAllocations;
    mapping(uint256 roundId => bool finalized) public revenueFinalized;
    mapping(bytes32 batchId => bool processed) public partnerBatchProcessed;

    // --- Events ---------------------------------------------------------
    event SalesCollected(
        uint40 indexed roundId, uint256 totalSales, uint256 prizeAmount, uint256 accumulateAmount, uint256 opsAmount
    );
    event RoundPrizeSettled(uint40 indexed roundId, uint256 prizePool, uint256 released, bool isReleaseRound);
    event ClaimPaid(address indexed to, uint256 amount);
    event RefundPaid(address indexed to, uint256 amount);
    event OpsClaimed(address indexed to, uint256 amount);
    event AccumulatedPoolSeeded(address indexed from, uint256 amount);
    event RoundAccountingFinalized(
        uint40 indexed roundId, uint64 claimDeadline, uint256 winnerLiability, uint256 recycled
    );
    event RoundClaimsExpired(uint40 indexed roundId, uint256 recycledAmount);
    event LegacyAccountingReconciled(uint256 previousUnclaimedPrize, uint256 verifiedUnclaimedPrize, uint256 recycled);
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

    function initialize(address admin_, IUnifiedLedgerV2 ledger_, address ops_) public initializer {
        if (admin_ == address(0) || address(ledger_) == address(0) || ops_ == address(0)) {
            revert ZeroAddress();
        }

        __AccessControl_init();
        __Pausable_init();

        ledger = ledger_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
        _grantRole(OPS_ROLE, ops_);
        legacyAccountingReconciled = true;
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
        onlyRole(GAME_ROLE)
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

    // --- Game Interface -------------------------------------------------

    /// @inheritdoc ILotto3DTreasury
    function collectSales(uint40 roundId, uint256 totalSales) external onlyRole(GAME_ROLE) whenNotPaused nonReentrant {
        if (totalSales == 0) revert ZeroAmount();
        if (salesCollected[roundId]) revert AlreadyCollected();
        IRevenueAllocationTreasury.RoundRevenueAllocation memory allocation_ = _roundRevenueAllocations[roundId];
        if (!allocation_.snapshotted) {
            if (address(revenueRouter) != address(0)) revert RoundAllocationNotSnapshotted();
            salesCollected[roundId] = true;
            uint256 legacyPrizeAmount = totalSales * PRIZE_BPS / BPS_BASE;
            uint256 legacyAccumulateAmount = totalSales * ACCUMULATE_BPS / BPS_BASE;
            uint256 legacyOpsAmount = totalSales - legacyPrizeAmount - legacyAccumulateAmount;
            pendingPrize += legacyPrizeAmount;
            roundBasePrize[roundId] = legacyPrizeAmount;
            accumulatedPool += legacyAccumulateAmount;
            opsAccrued += legacyOpsAmount;
            _requireSolvent();
            emit SalesCollected(roundId, totalSales, legacyPrizeAmount, legacyAccumulateAmount, legacyOpsAmount);
            return;
        }

        salesCollected[roundId] = true;
        revenueFinalized[roundId] = true;

        (uint256 totalPrizeAmount, uint256 datAmount, uint256 partnerAmount, uint256 opsAmount) =
            RevenueAllocationLib.split(totalSales, allocation_.prizeBps, allocation_.datBps, allocation_.partnerBps);
        uint256 prizeAmount = totalPrizeAmount * 6250 / BPS_BASE;
        uint256 accumulateAmount = totalPrizeAmount - prizeAmount;

        pendingPrize += prizeAmount;
        roundBasePrize[roundId] = prizeAmount;
        accumulatedPool += accumulateAmount;
        opsAccrued += opsAmount;
        partnerReserveAccrued += partnerAmount;
        if (datAmount > 0) {
            datDistributed += datAmount;
            ledger.operatorTransfer(address(this), datRevenueVault, datAmount);
        }

        _requireSolvent();

        emit SalesCollected(roundId, totalSales, prizeAmount, accumulateAmount, opsAmount);
        bytes32 sourceKey =
            keccak256(abi.encode(block.chainid, address(this), keccak256("LOTTO3D"), roundId, allocation_.version));
        emit RoundRevenueFinalized(
            sourceKey, roundId, allocation_.version, totalSales, totalPrizeAmount, datAmount, partnerAmount, opsAmount
        );
    }

    /// @inheritdoc ILotto3DTreasury
    function settleRoundPrize(uint40 roundId, bool isReleaseRound)
        external
        onlyRole(GAME_ROLE)
        whenNotPaused
        returns (uint256 prizePool)
    {
        uint256 released = 0;

        if (isReleaseRound && accumulatedPool > 0) {
            released = (accumulatedPool * RELEASE_BPS) / BPS_BASE;
            accumulatedPool -= released;
        }

        uint256 basePrize = roundBasePrize[roundId];
        prizePool = basePrize + released;
        pendingPrize -= basePrize;
        roundBasePrize[roundId] = 0;

        roundPrizePool[roundId] = prizePool;
        roundPrizePrepared[roundId] = true;
        pendingRoundPrize += prizePool;

        emit RoundPrizeSettled(roundId, prizePool, released, isReleaseRound);
    }

    function finalizeRoundAccounting(uint40 roundId, uint64 claimDeadline, uint256 winnerLiability)
        external
        onlyRole(GAME_ROLE)
        whenNotPaused
    {
        if (!legacyAccountingReconciled) revert LegacyAccountingNotReconciled();
        if (roundAccountingFinalized[roundId]) revert RoundAlreadyFinalized();
        if (!roundPrizePrepared[roundId]) revert RoundNotSettled();
        uint256 prizePool = roundPrizePool[roundId];
        if (claimDeadline <= block.timestamp) revert ClaimWindowClosed();
        if (winnerLiability > prizePool) revert InsufficientBalance();

        roundAccountingFinalized[roundId] = true;
        roundClaimDeadline[roundId] = claimDeadline;
        roundOutstandingLiability[roundId] = winnerLiability;
        pendingRoundPrize -= prizePool;
        activeWinnerLiability += winnerLiability;
        uint256 recycled = prizePool - winnerLiability;
        accumulatedPool += recycled;

        _requireSolvent();
        emit RoundAccountingFinalized(roundId, claimDeadline, winnerLiability, recycled);
    }

    function payRoundClaim(uint40 roundId, address to, uint256 amount)
        external
        onlyRole(GAME_ROLE)
        whenNotPaused
        nonReentrant
    {
        _consumeRoundLiability(roundId, amount);
        if (to == address(0)) revert ZeroAddress();
        ledger.operatorTransfer(address(this), to, amount);
        emit ClaimPaid(to, amount);
    }

    function payRoundClaims(uint40[] calldata roundIds, address to, uint256[] calldata amounts)
        external
        onlyRole(GAME_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        if (roundIds.length == 0 || roundIds.length != amounts.length) revert LengthMismatch();

        uint256 totalAmount;
        for (uint256 i = 0; i < roundIds.length; ++i) {
            _consumeRoundLiability(roundIds[i], amounts[i]);
            totalAmount += amounts[i];
        }
        ledger.operatorTransfer(address(this), to, totalAmount);
        emit ClaimPaid(to, totalAmount);
    }

    function expireRoundClaims(uint40 roundId) external nonReentrant returns (uint256 recycledAmount) {
        if (!roundAccountingFinalized[roundId]) revert RoundNotSettled();
        if (roundClaimsExpired[roundId]) revert ClaimWindowClosed();
        if (block.timestamp <= roundClaimDeadline[roundId]) revert ClaimWindowOpen();

        recycledAmount = roundOutstandingLiability[roundId];
        roundOutstandingLiability[roundId] = 0;
        roundClaimsExpired[roundId] = true;
        activeWinnerLiability -= recycledAmount;
        accumulatedPool += recycledAmount;
        emit RoundClaimsExpired(roundId, recycledAmount);
    }

    function _consumeRoundLiability(uint40 roundId, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        if (!roundAccountingFinalized[roundId]) revert RoundNotSettled();
        if (roundClaimsExpired[roundId] || block.timestamp > roundClaimDeadline[roundId]) revert ClaimWindowClosed();
        uint256 outstanding = roundOutstandingLiability[roundId];
        if (amount > outstanding || amount > ledger.balanceOf(address(this))) revert InsufficientBalance();
        roundOutstandingLiability[roundId] = outstanding - amount;
        activeWinnerLiability -= amount;
    }

    /// @inheritdoc ILotto3DTreasury
    function payClaim(address to, uint256 amount) external onlyRole(GAME_ROLE) whenNotPaused nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > unclaimedPrize || amount > ledger.balanceOf(address(this))) revert InsufficientBalance();
        unclaimedPrize -= amount;

        ledger.operatorTransfer(address(this), to, amount);

        emit ClaimPaid(to, amount);
    }

    /// @inheritdoc ILotto3DTreasury
    /// @dev Batch claims intentionally aggregate only the ledger transfer. The game
    ///      still validates and marks every ticket independently.
    function payClaimBatch(address to, uint256 amount) external onlyRole(GAME_ROLE) whenNotPaused nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > unclaimedPrize || amount > ledger.balanceOf(address(this))) revert InsufficientBalance();
        unclaimedPrize -= amount;

        ledger.operatorTransfer(address(this), to, amount);

        emit ClaimPaid(to, amount);
    }

    /// @inheritdoc ILotto3DTreasury
    function payRefund(address to, uint256 amount) external onlyRole(GAME_ROLE) whenNotPaused nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > refundReserve || amount > ledger.balanceOf(address(this))) revert InsufficientBalance();
        refundReserve -= amount;

        ledger.operatorTransfer(address(this), to, amount);

        emit RefundPaid(to, amount);
    }

    /// @notice Reserve funds for a cancelled round's refunds.
    function reserveForRefund(uint256 amount) external onlyRole(GAME_ROLE) whenNotPaused {
        refundReserve += amount;
        _requireSolvent();
    }

    // --- Admin ----------------------------------------------------------

    /// @notice Seed the accumulated pool (e.g. initial launch fund).
    function seedAccumulatedPool(uint256 amount) external onlyRole(ADMIN_ROLE) whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();

        ledger.operatorTransfer(msg.sender, address(this), amount);
        accumulatedPool += amount;

        _requireSolvent();

        emit AccumulatedPoolSeeded(msg.sender, amount);
    }

    /// @notice Claim accrued ops revenue.
    function claimOps() external onlyRole(OPS_ROLE) whenNotPaused nonReentrant {
        uint256 amount = opsAccrued;
        if (amount == 0) revert ZeroAmount();

        uint256 available = ledger.balanceOf(address(this));
        uint256 reserved = pendingPrize + pendingRoundPrize + accumulatedPool + refundReserve + unclaimedPrize
            + activeWinnerLiability + partnerReserveAccrued;
        uint256 claimable = available > reserved ? available - reserved : 0;
        if (amount > claimable) revert InsufficientBalance();

        opsAccrued = 0;
        ledger.operatorTransfer(address(this), msg.sender, amount);

        emit OpsClaimed(msg.sender, amount);
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

    function reconcileLegacyAccounting(uint256 verifiedUnclaimedPrize) external onlyRole(ADMIN_ROLE) {
        if (legacyAccountingReconciled) revert LegacyAccountingAlreadyReconciled();
        uint256 previous = unclaimedPrize;
        if (verifiedUnclaimedPrize > previous) revert InsufficientBalance();
        uint256 recycled = previous - verifiedUnclaimedPrize;
        unclaimedPrize = verifiedUnclaimedPrize;
        accumulatedPool += recycled;
        legacyAccountingReconciled = true;
        _requireSolvent();
        emit LegacyAccountingReconciled(previous, verifiedUnclaimedPrize, recycled);
    }

    function totalLiabilities() public view returns (uint256) {
        return pendingPrize + pendingRoundPrize + accumulatedPool + opsAccrued + refundReserve + unclaimedPrize
            + activeWinnerLiability + partnerReserveAccrued;
    }

    function _requireSolvent() internal view {
        if (ledger.balanceOf(address(this)) < totalLiabilities()) revert InsufficientBalance();
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function _authorizeUpgrade(address) internal override onlyRole(ADMIN_ROLE) {}
}
