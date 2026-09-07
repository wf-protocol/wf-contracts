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
import {ILotto7Treasury} from "../../lotto7/interfaces/ILotto7Treasury.sol";
import {IWusdLotto7Treasury} from "./IWusdLotto7Treasury.sol";

/// @title WusdLotto7Treasury
/// @notice 使用 WUSD 管理 Lotto7 奖池、运营收入和派彩。
contract WusdLotto7Treasury is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    IWusdLotto7Treasury
{
    // ─── Roles ──────────────────────────────────────────────────────────
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant GAME_ROLE = keccak256("GAME_ROLE");
    bytes32 public constant OPS_ROLE = keccak256("OPS_ROLE");
    bytes32 public constant DIVIDEND_ROLE = keccak256("DIVIDEND_ROLE");
    bytes32 public constant REVENUE_SETTLER_ROLE = keccak256("REVENUE_SETTLER_ROLE");

    // ─── Constants（对应 规则.md 第9节：80% 奖金池 / 15% 运维 / 5% 分红） ──
    uint256 public constant PRIZE_BPS = 8000;
    uint256 public constant OPS_BPS = 1500;
    uint256 public constant DIVIDEND_BPS = 500;
    uint256 public constant BPS_BASE = 10_000;

    // ─── Errors ─────────────────────────────────────────────────────────
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance();
    error AlreadyCollected();
    error InvalidTier();
    error InvalidBps();
    error InvalidRoundAccounting();
    error RoundAlreadySettled();
    error RoundNotSettled();
    error RoundAlreadyFinalized();
    error ClaimWindowClosed();
    error ClaimWindowOpen();
    error LegacyAccountingNotReconciled();
    error LegacyAccountingAlreadyReconciled();
    error RevenueNotConfigured();
    error RoundAllocationAlreadySnapshotted();
    error RoundAllocationNotSnapshotted();
    error PartnerCollectionAlreadyProcessed();
    error InvalidPartnerCollection();
    error OnlyPartnerPayoutSafe();

    // ─── State ──────────────────────────────────────────────────────────
    IUnifiedLedgerV2 public ledger;

    uint256 public pendingPrize;
    uint256 public opsAccrued;
    uint256 public dividendAccrued;

    uint256 public jackpot1;
    uint256 public jackpot2;
    uint256 public jackpot3;

    uint256 public unclaimedPrize;

    mapping(uint256 => bool) public salesCollected;

    /// @dev UUPS storage additions must remain after every legacy field.
    uint256 public override sharedCarryPool;
    uint256 public activeWinnerLiability;
    mapping(uint256 => uint256) public roundPrizePool;
    mapping(uint256 => bool) public roundSettled;
    mapping(uint256 => bool) public roundAccountingFinalized;

    struct RoundLiabilityState {
        uint64 claimDeadline;
        uint256 fixedLiability;
        uint256 tier1Liability;
        uint256 tier2Liability;
        uint256 tier3Liability;
        uint256 outstanding;
        uint256 paid;
        uint256 recycled;
        bool expired;
    }

    mapping(uint256 => RoundLiabilityState) public roundLiabilities;
    bool public legacyAccountingReconciled;
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

    // ─── Events ─────────────────────────────────────────────────────────
    event SalesCollected(
        uint256 indexed roundId, uint256 totalSales, uint256 prizeAmount, uint256 opsAmount, uint256 dividendAmount
    );
    event ClaimPaid(address indexed to, uint256 amount);
    event RefundPaid(address indexed to, uint256 amount);
    event OpsClaimed(address indexed to, uint256 amount);
    event DividendClaimed(address indexed to, uint256 amount);
    event JackpotInjected(uint8 indexed tier, uint256 amount, address indexed sender);
    event JackpotUpdated(uint8 indexed tier, uint256 newAmount);
    event SharedCarryInjected(address indexed sender, uint256 amount);
    event RoundAccountingFinalized(
        uint256 indexed roundId,
        uint256 claimDeadline,
        uint256 winnerLiability,
        uint256 nextJackpot1,
        uint256 nextJackpot2,
        uint256 nextJackpot3,
        uint256 sharedCarryRemainder
    );
    event RoundLiabilityPaid(uint256 indexed roundId, address indexed to, uint256 amount, uint256 outstanding);
    event RoundLiabilityRecycled(uint256 indexed roundId, uint256 amount, uint256 outstanding);
    event RoundClaimsExpired(uint256 indexed roundId, uint256 recycledAmount);
    event LegacyAccountingReconciled(
        uint256 previousUnclaimedPrize, uint256 verifiedUnclaimedPrize, uint256 initialSharedCarry
    );
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

    function initialize(address admin_, IUnifiedLedgerV2 ledger_, address ops_, address dividend_) public initializer {
        if (admin_ == address(0) || address(ledger_) == address(0) || ops_ == address(0) || dividend_ == address(0)) {
            revert ZeroAddress();
        }

        __AccessControl_init();
        __Pausable_init();

        ledger = ledger_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
        _grantRole(OPS_ROLE, ops_);
        _grantRole(DIVIDEND_ROLE, dividend_);
        legacyAccountingReconciled = true;
    }

    /// @notice 在代理部署完成后，为 Treasury 自有 WUSD 建立支出额度。
    /// @dev 不可放在代理构造期的 initializer 中；构造期跨合约调用的 msg.sender 是部署者。
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

    // ─── Game Interface（仅 GAME_ROLE，即 WusdLotto7Game 合约可调用） ─────────

    /// @inheritdoc ILotto7Treasury
    function collectSales(uint256 roundId, uint256 totalSales) external onlyRole(GAME_ROLE) whenNotPaused nonReentrant {
        if (totalSales == 0) revert ZeroAmount();
        if (salesCollected[roundId]) revert AlreadyCollected();
        IRevenueAllocationTreasury.RoundRevenueAllocation memory allocation_ = _roundRevenueAllocations[roundId];
        if (!allocation_.snapshotted) {
            if (address(revenueRouter) != address(0)) revert RoundAllocationNotSnapshotted();
            salesCollected[roundId] = true;
            uint256 legacyPrizeAmount = totalSales * PRIZE_BPS / BPS_BASE;
            uint256 legacyOpsAmount = totalSales * OPS_BPS / BPS_BASE;
            uint256 legacyDividendAmount = totalSales - legacyPrizeAmount - legacyOpsAmount;
            pendingPrize += legacyPrizeAmount;
            opsAccrued += legacyOpsAmount;
            dividendAccrued += legacyDividendAmount;
            emit SalesCollected(roundId, totalSales, legacyPrizeAmount, legacyOpsAmount, legacyDividendAmount);
            return;
        }

        salesCollected[roundId] = true;
        revenueFinalized[roundId] = true;

        (uint256 prizeAmount, uint256 datAmount, uint256 partnerAmount, uint256 opsAmount) =
            RevenueAllocationLib.split(totalSales, allocation_.prizeBps, allocation_.datBps, allocation_.partnerBps);

        pendingPrize += prizeAmount;
        opsAccrued += opsAmount;
        partnerReserveAccrued += partnerAmount;
        if (datAmount > 0) {
            datDistributed += datAmount;
            ledger.operatorTransfer(address(this), datRevenueVault, datAmount);
        }

        _requireSolvent();

        emit SalesCollected(roundId, totalSales, prizeAmount, opsAmount, partnerAmount);
        bytes32 sourceKey =
            keccak256(abi.encode(block.chainid, address(this), keccak256("LOTTO7"), roundId, allocation_.version));
        emit RoundRevenueFinalized(
            sourceKey, roundId, allocation_.version, totalSales, prizeAmount, datAmount, partnerAmount, opsAmount
        );
    }

    /// @inheritdoc ILotto7Treasury
    function settleRoundPrize(uint256 roundId) external onlyRole(GAME_ROLE) whenNotPaused returns (uint256 prizePool) {
        if (roundSettled[roundId]) revert RoundAlreadySettled();

        prizePool = pendingPrize;
        pendingPrize = 0;
        roundPrizePool[roundId] = prizePool;
        roundSettled[roundId] = true;
    }

    /// @inheritdoc ILotto7Treasury
    function payClaim(address to, uint256 amount) external onlyRole(GAME_ROLE) whenNotPaused nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > ledger.balanceOf(address(this))) revert InsufficientBalance();

        if (unclaimedPrize >= amount) {
            unclaimedPrize -= amount;
        }

        // 单次 operatorTransfer 取代原版的 decreaseBalance+increaseBalance 两步调用：
        // LedgerContract 保证 from 减少量与 to 增加量严格相等（零和），不需要本合约
        // 自行维持这个不变量。
        ledger.operatorTransfer(address(this), to, amount);

        emit ClaimPaid(to, amount);
    }

    /// @inheritdoc ILotto7Treasury
    /// @dev 退款必须在事故暂停期间仍然可用。只有 GAME_ROLE 能调用，且 Game 会在调用前
    ///      原子地标记用户已退款，因此不依赖 Treasury 自己维护轮次状态。
    function payRefund(address to, uint256 amount) external onlyRole(GAME_ROLE) nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > ledger.balanceOf(address(this))) revert InsufficientBalance();

        ledger.operatorTransfer(address(this), to, amount);
        emit RefundPaid(to, amount);
    }

    /// @notice Game 合约在结算浮动奖时调用，更新滚存奖池余额（不发生实际转账，仅记账）。
    function setJackpots(uint256 j1, uint256 j2, uint256 j3) external onlyRole(GAME_ROLE) whenNotPaused {
        jackpot1 = j1;
        jackpot2 = j2;
        jackpot3 = j3;
        emit JackpotUpdated(1, j1);
        emit JackpotUpdated(2, j2);
        emit JackpotUpdated(3, j3);
    }

    function previewRoundPools(uint256 floatPool, uint256 tier1Bps, uint256 tier2Bps, uint256 tier3Bps)
        public
        view
        returns (uint256 tier1Available, uint256 tier2Available, uint256 tier3Available, uint256 sharedDust)
    {
        if (tier1Bps + tier2Bps + tier3Bps != BPS_BASE) revert InvalidBps();

        uint256 distributable = sharedCarryPool + floatPool;
        uint256 tier1Added = (distributable * tier1Bps) / BPS_BASE;
        uint256 tier2Added = (distributable * tier2Bps) / BPS_BASE;
        uint256 tier3Added = (distributable * tier3Bps) / BPS_BASE;

        tier1Available = jackpot1 + tier1Added;
        tier2Available = jackpot2 + tier2Added;
        tier3Available = jackpot3 + tier3Added;
        sharedDust = distributable - tier1Added - tier2Added - tier3Added;
    }

    function finalizeRoundAccounting(RoundAccounting calldata accounting) external onlyRole(GAME_ROLE) whenNotPaused {
        if (!legacyAccountingReconciled) revert LegacyAccountingNotReconciled();
        if (!roundSettled[accounting.roundId]) revert RoundNotSettled();
        if (roundAccountingFinalized[accounting.roundId]) revert RoundAlreadyFinalized();
        if (accounting.claimDeadline <= block.timestamp) revert ClaimWindowClosed();
        if (accounting.floatPool + accounting.fixedLiability != roundPrizePool[accounting.roundId]) {
            revert InvalidRoundAccounting();
        }

        (uint256 available1, uint256 available2, uint256 available3, uint256 sharedDust) =
            previewRoundPools(accounting.floatPool, accounting.tier1Bps, accounting.tier2Bps, accounting.tier3Bps);
        if (
            accounting.tier1Liability > available1 || accounting.tier2Liability > available2
                || accounting.tier3Liability > available3
        ) revert InvalidRoundAccounting();

        uint256 recyclable = sharedDust + (available1 - accounting.tier1Liability)
            + (available2 - accounting.tier2Liability) + (available3 - accounting.tier3Liability);
        uint256 nextJackpot1 = (recyclable * accounting.tier1Bps) / BPS_BASE;
        uint256 nextJackpot2 = (recyclable * accounting.tier2Bps) / BPS_BASE;
        uint256 nextJackpot3 = (recyclable * accounting.tier3Bps) / BPS_BASE;

        jackpot1 = nextJackpot1;
        jackpot2 = nextJackpot2;
        jackpot3 = nextJackpot3;
        sharedCarryPool = recyclable - nextJackpot1 - nextJackpot2 - nextJackpot3;

        uint256 winnerLiability = accounting.fixedLiability + accounting.tier1Liability + accounting.tier2Liability
            + accounting.tier3Liability;
        roundLiabilities[accounting.roundId] = RoundLiabilityState({
            claimDeadline: accounting.claimDeadline,
            fixedLiability: accounting.fixedLiability,
            tier1Liability: accounting.tier1Liability,
            tier2Liability: accounting.tier2Liability,
            tier3Liability: accounting.tier3Liability,
            outstanding: winnerLiability,
            paid: 0,
            recycled: 0,
            expired: false
        });
        activeWinnerLiability += winnerLiability;
        roundAccountingFinalized[accounting.roundId] = true;

        _requireSolvent();
        emit JackpotUpdated(1, nextJackpot1);
        emit JackpotUpdated(2, nextJackpot2);
        emit JackpotUpdated(3, nextJackpot3);
        emit RoundAccountingFinalized(
            accounting.roundId,
            accounting.claimDeadline,
            winnerLiability,
            nextJackpot1,
            nextJackpot2,
            nextJackpot3,
            sharedCarryPool
        );
    }

    function payRoundClaim(uint256 roundId, address to, uint256 amount)
        external
        onlyRole(GAME_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        RoundLiabilityState storage liability = roundLiabilities[roundId];
        if (!roundAccountingFinalized[roundId]) revert RoundNotSettled();
        if (liability.expired || block.timestamp > liability.claimDeadline) revert ClaimWindowClosed();
        if (amount > liability.outstanding || amount > ledger.balanceOf(address(this))) {
            revert InsufficientBalance();
        }

        liability.outstanding -= amount;
        liability.paid += amount;
        activeWinnerLiability -= amount;
        ledger.operatorTransfer(address(this), to, amount);

        emit ClaimPaid(to, amount);
        emit RoundLiabilityPaid(roundId, to, amount, liability.outstanding);
    }

    function recycleRoundLiability(uint256 roundId, uint256 amount) external onlyRole(GAME_ROLE) whenNotPaused {
        if (amount == 0) return;

        RoundLiabilityState storage liability = roundLiabilities[roundId];
        if (!roundAccountingFinalized[roundId]) revert RoundNotSettled();
        if (liability.expired || block.timestamp > liability.claimDeadline) revert ClaimWindowClosed();
        if (amount > liability.outstanding) revert InsufficientBalance();

        liability.outstanding -= amount;
        liability.recycled += amount;
        activeWinnerLiability -= amount;
        sharedCarryPool += amount;

        emit RoundLiabilityRecycled(roundId, amount, liability.outstanding);
    }

    function expireRoundClaims(uint256 roundId) external nonReentrant returns (uint256 recycledAmount) {
        RoundLiabilityState storage liability = roundLiabilities[roundId];
        if (!roundAccountingFinalized[roundId]) revert RoundNotSettled();
        if (liability.expired) revert ClaimWindowClosed();
        if (block.timestamp <= liability.claimDeadline) revert ClaimWindowOpen();

        recycledAmount = liability.outstanding;
        liability.outstanding = 0;
        liability.recycled += recycledAmount;
        liability.expired = true;
        activeWinnerLiability -= recycledAmount;
        sharedCarryPool += recycledAmount;

        emit RoundClaimsExpired(roundId, recycledAmount);
    }

    // ─── Public Interface ───────────────────────────────────────────────

    /// @inheritdoc ILotto7Treasury
    /// @dev 调用前 msg.sender 必须已对本合约执行
    ///      `ledger.approveOperator(address(lotto7Treasury), amount)`，
    ///      否则本函数内部的 operatorTransfer 会以 ExceedsOperatorAllowance revert。
    function injectJackpot(uint8 tier, uint256 amount) external nonReentrant whenNotPaused {
        if (tier < 1 || tier > 3) revert InvalidTier();
        if (amount == 0) revert ZeroAmount();

        ledger.operatorTransfer(msg.sender, address(this), amount);

        if (tier == 1) jackpot1 += amount;
        else if (tier == 2) jackpot2 += amount;
        else jackpot3 += amount;

        _requireSolvent();
        emit JackpotInjected(tier, amount, msg.sender);
    }

    function injectSharedCarry(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        ledger.operatorTransfer(msg.sender, address(this), amount);
        sharedCarryPool += amount;

        _requireSolvent();
        emit SharedCarryInjected(msg.sender, amount);
    }

    /// @notice One-time migration for a V2 proxy whose `unclaimedPrize` mixed
    /// legacy winner obligations with amounts already represented by jackpots.
    function reconcileLegacyAccounting(uint256 verifiedUnclaimedPrize, uint256 initialSharedCarry)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (legacyAccountingReconciled) revert LegacyAccountingAlreadyReconciled();
        uint256 previousUnclaimedPrize = unclaimedPrize;
        if (verifiedUnclaimedPrize > previousUnclaimedPrize) revert InvalidRoundAccounting();

        unclaimedPrize = verifiedUnclaimedPrize;
        sharedCarryPool = initialSharedCarry;
        legacyAccountingReconciled = true;
        _requireSolvent();

        emit LegacyAccountingReconciled(previousUnclaimedPrize, verifiedUnclaimedPrize, initialSharedCarry);
    }

    /// @inheritdoc ILotto7Treasury
    function getJackpots() external view returns (uint256 j1, uint256 j2, uint256 j3) {
        return (jackpot1, jackpot2, jackpot3);
    }

    // ─── Ops / Dividend Withdrawal ──────────────────────────────────────

    /// @inheritdoc ILotto7Treasury
    function claimOps() external onlyRole(OPS_ROLE) whenNotPaused nonReentrant {
        uint256 amount = opsAccrued;
        if (amount == 0) revert ZeroAmount();

        _assertWithinClaimable(amount);

        opsAccrued = 0;
        ledger.operatorTransfer(address(this), msg.sender, amount);

        emit OpsClaimed(msg.sender, amount);
    }

    /// @inheritdoc ILotto7Treasury
    function claimDividend() external onlyRole(DIVIDEND_ROLE) whenNotPaused nonReentrant {
        uint256 amount = dividendAccrued;
        if (amount == 0) revert ZeroAmount();

        _assertWithinClaimable(amount);

        dividendAccrued = 0;
        ledger.operatorTransfer(address(this), msg.sender, amount);

        emit DividendClaimed(msg.sender, amount);
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
        ledger.operatorTransfer(address(this), msg.sender, amount);

        _requireSolvent();
        emit PartnerReserveClaimed(collectionId, accountingRoot, amount, partnerReserveAccrued);
    }

    /// @dev 确保运维/分红提取不会挤占用户待领奖金与滚存奖池资金。
    function _assertWithinClaimable(uint256 amount) internal view {
        uint256 available = ledger.balanceOf(address(this));
        uint256 reserved = pendingPrize + unclaimedPrize + activeWinnerLiability + jackpot1 + jackpot2 + jackpot3
            + sharedCarryPool + partnerReserveAccrued;
        uint256 claimable = available > reserved ? available - reserved : 0;
        if (amount > claimable) revert InsufficientBalance();
    }

    function totalLiabilities() public view returns (uint256) {
        return pendingPrize + unclaimedPrize + activeWinnerLiability + jackpot1 + jackpot2 + jackpot3 + sharedCarryPool
            + opsAccrued + dividendAccrued + partnerReserveAccrued;
    }

    function surplusBalance() external view returns (uint256) {
        uint256 available = ledger.balanceOf(address(this));
        uint256 liabilities = totalLiabilities();
        return available > liabilities ? available - liabilities : 0;
    }

    function _requireSolvent() internal view {
        if (ledger.balanceOf(address(this)) < totalLiabilities()) revert InsufficientBalance();
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function _authorizeUpgrade(address) internal override onlyRole(ADMIN_ROLE) {}
}
