// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IProtocolFundingReceiver} from "../../../protocol/IProtocolFundingReceiver.sol";

import {IUnifiedLedgerV4} from "../../../wusd/IUnifiedLedgerV4.sol";
import {IProtocolRevenueRouter} from "../../../protocol/IProtocolRevenueRouter.sol";
import {IRevenueAllocationTreasury} from "../../../protocol/IRevenueAllocationTreasury.sol";
import {RevenueAllocationLib} from "../../../protocol/RevenueAllocationLib.sol";
import {ILottoTreasury} from "../../lotto7uma/interfaces/ILottoTreasury.sol";
import {IWusdLottoUmaRevenueTreasury} from "./IWusdLottoUmaRevenueTreasury.sol";

/// @title World Lotto treasury
/// @notice WUSD prize, refund, reserve, carry and finalized revenue accounting.
contract WusdLottoTreasury is
    Initializable,
    AccessControlUpgradeable,
    IProtocolFundingReceiver,
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
    bytes32 public constant FUND_ROLE = keccak256("FUND_ROLE");
    bytes32 public constant REVENUE_SETTLER_ROLE = keccak256("REVENUE_SETTLER_ROLE");

    uint256 public constant OVERFLOW_THRESHOLD = 500_000_000 * 1e6; // 500M U (assuming 6 decimals)
    uint256 public constant OVERFLOW_BPS = 5000; // 50%

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
    error PartnerCollectionAlreadyProcessed();
    error InvalidPartnerCollection();
    error OnlyPartnerPayoutSafe();

    IUnifiedLedgerV4 public ledger;
    uint256 public tokenUnit;

    uint256 public reserveBalance;
    uint256 public claimsPaid;

    /// @notice Unified carry pool — all unawarded floating-tier prize money.
    uint256 public carryPool;

    /// @notice Maximum carry pool size. Excess is redirected to fund. 0 = no cap.
    uint256 public carryCap;

    /// @notice Accrued but unclaimed revenue for ops and carry overflow fund.
    uint256 public opsAccrued;
    uint256 public fundAccrued;
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
    event OpsClaimed(address indexed to, uint256 amount);
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
    event PartnerReserveClaimed(
        bytes32 indexed collectionId, bytes32 indexed accountingRoot, uint256 amount, uint256 reserveRemaining
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin_, IUnifiedLedgerV4 ledger_, uint256 tokenUnit_, address ops_, address fund_)
        public
        initializer
    {
        if (admin_ == address(0) || address(ledger_) == address(0) || ops_ == address(0) || fund_ == address(0)) {
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
        _grantRole(FUND_ROLE, fund_);
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
            ledger.protocolTransfer(datRevenueVault, datAmount);
        }
        _requireSolvent();

        bytes32 sourceKey =
            keccak256(abi.encode(block.chainid, address(this), keccak256("LOTTO7_UMA"), roundId, allocation_.version));
        emit RoundRevenueFinalized(
            sourceKey, roundId, allocation_.version, totalSales, prizeAmount, datAmount, partnerAmount, opsAmount
        );
    }

    /// @notice Funding kind 0 credits reserve; kind 1 seeds carry (admin only).
    function onProtocolFunding(address funder, uint256 amount, bytes calldata data)
        external
        whenNotPaused
        nonReentrant
    {
        require(msg.sender == address(ledger), "OnlyLedger");
        if (amount == 0) revert ZeroAmount();
        uint8 kind = abi.decode(data, (uint8));
        if (kind == 0) {
            reserveBalance += amount;
            emit ReserveDeposited(funder, amount);
        } else {
            require(kind == 1, "InvalidFundingData");
            if (!hasRole(ADMIN_ROLE, funder)) revert AccessControlUnauthorizedAccount(funder, ADMIN_ROLE);
            carryPool += amount;
            emit CarryPoolSeeded(funder, amount);
        }
        _requireSolvent();
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
        ledger.protocolTransfer(to, amount);

        emit ReserveWithdrawn(to, amount);
    }

    /// @notice Set the maximum carry pool size. Excess overflows to fund.
    function setCarryCap(uint256 cap) external onlyRole(ADMIN_ROLE) {
        carryCap = cap;
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
        ledger.protocolTransfer(to, amount);
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
        ledger.protocolTransfer(to, amount);

        emit RefundReserveUpdated(-int256(amount), refundReserve);
        emit RefundPaid(to, amount);
    }

    // ─── Revenue Claims ────────────────────────────────────────────────

    /// @notice Claim accrued ops revenue. Only OPS_ROLE holders can call.
    function claimOps() external onlyRole(OPS_ROLE) whenNotPaused nonReentrant {
        uint256 amount = opsAccrued;
        if (amount == 0) revert ZeroAmount();
        if (amount > _claimableRevenue()) revert InsufficientBalance();

        opsAccrued = 0;
        ledger.protocolTransfer(msg.sender, amount);
        emit OpsClaimed(msg.sender, amount);
    }

    /// @notice Claim accrued fund overflow. Only FUND_ROLE holders can call.
    function claimFund() external onlyRole(FUND_ROLE) whenNotPaused nonReentrant {
        uint256 amount = fundAccrued;
        if (amount == 0) revert ZeroAmount();
        if (amount > _claimableRevenue()) revert InsufficientBalance();

        fundAccrued = 0;
        ledger.protocolTransfer(msg.sender, amount);
        emit FundClaimed(msg.sender, amount);
    }

    function claimPartnerReserve(bytes32 collectionId, bytes32 accountingRoot, uint256 amount)
        external
        whenNotPaused
        nonReentrant
    {
        if (msg.sender != partnerPayoutSafe) revert OnlyPartnerPayoutSafe();
        if (collectionId == bytes32(0) || accountingRoot == bytes32(0) || amount == 0) {
            revert InvalidPartnerCollection();
        }
        if (partnerBatchProcessed[collectionId]) revert PartnerCollectionAlreadyProcessed();
        if (amount > partnerReserveAccrued) revert InvalidPartnerCollection();

        partnerBatchProcessed[collectionId] = true;
        partnerReserveAccrued -= amount;
        ledger.protocolTransfer(msg.sender, amount);

        _requireSolvent();
        emit PartnerReserveClaimed(collectionId, accountingRoot, amount, partnerReserveAccrued);
    }

    function _claimableRevenue() internal view returns (uint256) {
        uint256 available = ledger.balanceOf(address(this));
        if (available < totalLiabilities()) return 0;
        uint256 reserved = reserveBalance + refundReserve + carryPool + prizeReserve;
        return available > reserved ? available - reserved : 0;
    }

    function totalLiabilities() public view returns (uint256) {
        return
            reserveBalance + refundReserve + carryPool + prizeReserve + opsAccrued + fundAccrued + partnerReserveAccrued;
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
