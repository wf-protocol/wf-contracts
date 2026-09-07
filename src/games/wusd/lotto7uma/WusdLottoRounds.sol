// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {IUnifiedLedgerV2} from "../../../wusd/IUnifiedLedgerV2.sol";
import {IGameModuleV3} from "../../../protocol/IGameModuleV3.sol";
import {IGameModuleV4} from "../../../protocol/IGameModuleV4.sol";
import {IRevenueAllocationTreasury} from "../../../protocol/IRevenueAllocationTreasury.sol";
import {IWusdLottoUmaRevenueTreasury} from "./IWusdLottoUmaRevenueTreasury.sol";
import {ILottoRounds} from "../../lotto7uma/interfaces/ILottoRounds.sol";
import {ILottoTreasury} from "../../lotto7uma/interfaces/ILottoTreasury.sol";
import {LottoPrizeMath} from "../../libraries/LottoPrizeMath.sol";

/// @title WusdLottoRounds（UMA 结算版）
/// @notice 使用 WUSD 的 UMA 版轮次、售票和链上透明计数器。
///
///      玩家主动调用 `buy()`/`batchBuy()` 时使用 Ledger 的 directOperatorTransfer，
///      购票和扣账在同一交易内完成，不需要单独 approve。`buyFor`/`batchBuyFor`
///      属于第三方代买路径，仍要求 beneficiary 预先设置 operator allowance，避免
///      BUYER_ROLE 持有者在用户没有主动发起交易时扣除其余额。
///
///      本文件其余部分（轮次生命周期、售票统计、UMA 断言状态机）与
///      smart-contract-pd-main 版本完全一致，未作任何改动，见各函数原有注释。
///
/// TRUST MODEL（原版设计，未改动）：
/// - ADMIN_ROLE can close sales early, pause the contract, and cancel rounds.
///   KEEPER_ROLE can only create rounds using the same validated config path.
///   These are privileged roles that should be
///   held by a multisig or governance contract in production.
/// - ORACLE_ROLE is granted to the OracleAdapter contract, not an EOA.
///
/// WUSD ASSUMPTION：本合约只处理 6 位精度的内部记账单位，不识别底层充值资产。
contract WusdLottoRounds is
    Initializable,
    AccessControlUpgradeable,
    ILottoRounds,
    PausableUpgradeable,
    ReentrancyGuard,
    UUPSUpgradeable,
    IGameModuleV3,
    IGameModuleV4
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant BUYER_ROLE = keccak256("BUYER_ROLE");
    /// @notice 授予 LottoSettlement 合约，仅用于在链上直接结算的 claim() 流程里
    ///         标记某张彩票已经领取过奖金，防止重复领取。见 markTicketClaimed。
    bytes32 public constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");
    uint256 public constant MAX_BATCH_SIZE = 100;

    error ZeroAddress();
    error ZeroAmount();
    error InvalidRound();
    error RoundAlreadyExists();
    error InvalidConfig();
    error RoundNotOpen();
    error SalesAlreadyClosed();
    error RoundAlreadyCancelled();
    error RoundAlreadyDrawn();
    error RoundHasSales();
    error AlreadyRefunded();
    error RoundNotCancelled();
    error NotTicketOwner();
    error InvalidNumber();
    error InvalidMultiplier();
    error TicketAlreadyClaimed();
    error InvalidTicket();

    error DrawWindowExpired();
    error InvalidSourceBundleHash();
    error InvalidNormalizedDataHash();
    error InvalidAssertionId();
    error DrawAssertionPending();
    error DrawAssertionNotPending();
    error InvalidOracleAdapter();
    error InvalidAssertionForRound();
    error InvalidDrawPayload();
    error OnlyLedger();
    error PurchaseAmountMismatch();
    error BatchTooLarge();
    error LegacyPurchasesAreDisabled();
    error RevenueAlreadyActive();
    error InvalidRevenueAllocation();
    error RoundOrderingNotInitialized();
    error InvalidRoundOrder();

    IUnifiedLedgerV2 public ledger;
    address public treasury;
    uint256 public ticketPrice;
    uint256 public nextTicketId;

    mapping(uint40 roundId => RoundData roundData) private _rounds;

    mapping(uint40 roundId => mapping(uint32 number => uint256 units)) public exact7Units;
    mapping(uint40 roundId => mapping(uint32 prefix6 => uint256 units)) public prefix6Units;
    mapping(uint40 roundId => mapping(uint32 prefix5 => uint256 units)) public prefix5Units;

    /// @notice 四/五等奖滑动窗口聚合计数器（4 位连续窗口 / 3 位连续窗口）。
    /// @dev 移植自 lotto7-refactored/Lotto7Game.sol 的 slide4/slide3 模式，用于取代
    ///      原 Merkle 版本里由 SETTLER_ROLE 自行统计、链上完全不做验证的四五等奖份数。
    ///      写入方式与 VRF 版完全一致：每次购票时把该号码 4 个 4 位窗口 / 5 个 3 位
    ///      窗口分别累加，写入次数固定为常数（4 次 + 5 次），不随任何变量循环，
    ///      因此是 O(1) 操作，不存在 gas 随用户数增长的风险（已用 Foundry 实测验证）。
    mapping(uint40 roundId => mapping(uint32 windowKey => uint256 units)) public slide4Units;
    mapping(uint40 roundId => mapping(uint32 windowKey => uint256 units)) public slide3Units;

    mapping(uint40 roundId => mapping(address user => uint256 count)) public ticketsPerRound;

    // Ticket storage for refunds and (新增) 链上直接结算所需的号码/倍数信息。
    // 新增 number/multiplier/claimed 字段：取代旧版 Merkle 叶子（roundId,user,tier,
    // winningUnits,amount）里由 settler 自行生成、链上无法验证的"归属"数据——现在
    // 中奖等级和应付金额完全由链上根据 number 与开奖号码重新计算，见 LottoSettlement.claim。
    // 结构体定义在 ILottoRounds 接口里（TicketData），此处直接复用避免重复声明。
    mapping(uint256 ticketId => TicketData) public tickets;
    uint256 public purchaseReceiptNonce;
    bool public legacyPurchasesDisabled;
    mapping(uint40 roundId => uint256[] ticketIds) private _roundTicketIds;
    bool public revenueAllocationEnabled;
    uint40 public latestRoundId;
    mapping(uint40 roundId => uint40 previous) public previousRoundId;
    bool public roundOrderingEnabled;

    event RoundCreated(uint40 indexed roundId);
    event SalesClosed(uint40 indexed roundId);
    event DrawAssertionMarkedPending(
        uint40 indexed roundId,
        bytes32 indexed assertionId,
        address indexed adapter,
        uint32 winningNumberPreview,
        bytes32 sourceBundleHash,
        bytes32 normalizedDataHash
    );
    event DrawAssertionDisputed(uint40 indexed roundId, bytes32 indexed assertionId);
    event DrawAssertionClearedForRetry(uint40 indexed roundId, bytes32 indexed assertionId);
    event DrawSubmitted(uint40 indexed roundId, uint32 winningNumber, bytes32 indexed sourceBundleHash);
    event RoundCancelled(uint40 indexed roundId);
    event TicketRefunded(uint256 indexed ticketId, uint40 indexed roundId, address indexed buyer, uint256 amount);
    event LedgerPurchase(
        bytes32 indexed receiptId, uint40 indexed roundId, address indexed payer, address beneficiary, uint256 amount
    );
    event LegacyPurchasesPermanentlyDisabled();
    event RoundOrderingInitialized(uint40 indexed latestExistingRoundId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin_, IUnifiedLedgerV2 ledger_, address treasury_, uint256 ticketPrice_)
        public
        initializer
    {
        if (admin_ == address(0) || address(ledger_) == address(0) || treasury_ == address(0)) {
            revert ZeroAddress();
        }
        if (ticketPrice_ == 0) {
            revert ZeroAmount();
        }

        __AccessControl_init();
        __Pausable_init();

        ledger = ledger_;
        treasury = treasury_;
        ticketPrice = ticketPrice_;
        roundOrderingEnabled = true;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
    }

    function createRound(uint40 roundId, RoundConfig calldata config) external {
        if (!hasRole(ADMIN_ROLE, msg.sender) && !hasRole(KEEPER_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, ADMIN_ROLE);
        }
        if (!roundOrderingEnabled) revert RoundOrderingNotInitialized();
        if (roundId == 0) {
            revert InvalidRound();
        }
        if (roundId <= latestRoundId) revert InvalidRoundOrder();
        if (_rounds[roundId].exists) {
            revert RoundAlreadyExists();
        }
        if (
            config.salesOpenTime >= config.salesCloseTime || config.salesCloseTime >= config.drawDataDeadline
                || config.drawDataDeadline >= config.claimDeadline || config.maxMultiplierPerTicket == 0
                || config.maxMultiplierPerTicket > 999 || config.assertionLiveness == 0
        ) {
            revert InvalidConfig();
        }

        if (revenueAllocationEnabled) {
            IWusdLottoUmaRevenueTreasury(treasury).snapshotRoundAllocation(roundId);
        }

        RoundData storage roundData = _rounds[roundId];
        roundData.exists = true;
        roundData.config = config;
        previousRoundId[roundId] = latestRoundId;
        latestRoundId = roundId;

        emit RoundCreated(roundId);
    }

    function initializeRoundOrdering(uint40 latestExistingRoundId) external reinitializer(3) onlyRole(ADMIN_ROLE) {
        if (roundOrderingEnabled) revert InvalidRoundOrder();
        if (latestExistingRoundId != 0 && !_rounds[latestExistingRoundId].exists) revert InvalidRound();
        latestRoundId = latestExistingRoundId;
        roundOrderingEnabled = true;
        emit RoundOrderingInitialized(latestExistingRoundId);
    }

    /// @dev 普通购票由 msg.sender 主动发起，扣账与出票在同一交易中完成。
    function protocolImplementationHash() external view returns (bytes32) {
        return ERC1967Utils.getImplementation().codehash;
    }

    function initializeRevenueV4(uint40 firstRoundId) external reinitializer(2) onlyRole(ADMIN_ROLE) {
        RoundData storage roundData = _rounds[firstRoundId];
        if (!roundData.exists || roundData.totalSales != 0 || roundData.cancelled) revert RevenueAlreadyActive();
        IWusdLottoUmaRevenueTreasury(treasury).snapshotRoundAllocation(firstRoundId);
        revenueAllocationEnabled = true;
    }

    function buy(uint40 roundId, uint32 number, uint16 multiplier) external whenNotPaused nonReentrant {
        if (legacyPurchasesDisabled) revert LegacyPurchasesAreDisabled();
        uint256 paid = _buyFor(msg.sender, msg.sender, roundId, number, multiplier);
        ledger.directOperatorTransfer(msg.sender, treasury, paid);
        ILottoTreasury(treasury).reserveRefunds(paid);
    }

    function batchBuy(uint40 roundId, uint32[] calldata numbers, uint16[] calldata multipliers)
        external
        whenNotPaused
        nonReentrant
    {
        if (legacyPurchasesDisabled) revert LegacyPurchasesAreDisabled();
        if (numbers.length == 0 || numbers.length != multipliers.length) {
            revert InvalidConfig();
        }
        if (numbers.length > MAX_BATCH_SIZE) revert BatchTooLarge();

        uint256 totalPaid = 0;
        for (uint256 i = 0; i < numbers.length; i++) {
            totalPaid += _buyFor(msg.sender, msg.sender, roundId, numbers[i], multipliers[i]);
        }

        ledger.directOperatorTransfer(msg.sender, treasury, totalPaid);
        ILottoTreasury(treasury).reserveRefunds(totalPaid);
    }

    /// @notice Buy a ticket on behalf of `beneficiary`. The ticket is owned by
    ///         `beneficiary` and funds are deducted from their LedgerContract balance.
    /// @dev `beneficiary`（而非 msg.sender）必须已经对本合约执行 approveOperator，
    ///      因为 operatorTransfer 的 `from` 参数是 beneficiary：BUYER_ROLE 持有者
    ///      只是发起调用的中介，不能代替 beneficiary 完成授权这一步。
    function buyFor(address beneficiary, uint40 roundId, uint32 number, uint16 multiplier)
        external
        onlyRole(BUYER_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (legacyPurchasesDisabled) revert LegacyPurchasesAreDisabled();
        uint256 paid = _buyFor(beneficiary, beneficiary, roundId, number, multiplier);
        ledger.operatorTransfer(beneficiary, treasury, paid);
        ILottoTreasury(treasury).reserveRefunds(paid);
    }

    /// @notice Batch version of `buyFor`.
    function batchBuyFor(address beneficiary, uint40 roundId, uint32[] calldata numbers, uint16[] calldata multipliers)
        external
        onlyRole(BUYER_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (legacyPurchasesDisabled) revert LegacyPurchasesAreDisabled();
        if (numbers.length == 0 || numbers.length != multipliers.length) {
            revert InvalidConfig();
        }
        if (numbers.length > MAX_BATCH_SIZE) revert BatchTooLarge();

        uint256 totalPaid = 0;
        for (uint256 i = 0; i < numbers.length; i++) {
            totalPaid += _buyFor(beneficiary, beneficiary, roundId, numbers[i], multipliers[i]);
        }

        ledger.operatorTransfer(beneficiary, treasury, totalPaid);
        ILottoTreasury(treasury).reserveRefunds(totalPaid);
    }

    function quotePurchase(address, address beneficiary, bytes calldata purchaseData)
        external
        view
        returns (uint256 amount)
    {
        (uint40 roundId, uint32[] memory numbers, uint16[] memory multipliers) =
            abi.decode(purchaseData, (uint40, uint32[], uint16[]));
        amount = _quotePurchase(beneficiary, roundId, numbers, multipliers);
    }

    function purchaseFromLedger(address payer, address beneficiary, uint256 amount, bytes calldata purchaseData)
        external
        whenNotPaused
        nonReentrant
        returns (bytes32 receiptId)
    {
        if (msg.sender != address(ledger)) revert OnlyLedger();
        (uint40 roundId, uint32[] memory numbers, uint16[] memory multipliers) =
            abi.decode(purchaseData, (uint40, uint32[], uint16[]));
        if (numbers.length == 0 || numbers.length != multipliers.length) revert InvalidConfig();
        if (numbers.length > MAX_BATCH_SIZE) revert BatchTooLarge();

        uint256 expectedAmount;
        for (uint256 i = 0; i < numbers.length; i++) {
            expectedAmount += _buyFor(payer, beneficiary, roundId, numbers[i], multipliers[i]);
        }
        if (amount != expectedAmount) revert PurchaseAmountMismatch();
        ILottoTreasury(treasury).reserveRefunds(amount);

        uint256 receiptNonce = ++purchaseReceiptNonce;
        receiptId = keccak256(abi.encode(address(this), roundId, payer, beneficiary, amount, receiptNonce));
        emit LedgerPurchase(receiptId, roundId, payer, beneficiary, amount);
    }

    function purchaseFromLedgerV4(
        address payer,
        address beneficiary,
        uint256 amount,
        IGameModuleV4.PurchaseContext calldata context,
        bytes calldata purchaseData
    ) external whenNotPaused nonReentrant returns (bytes32 receiptId, uint32 allocationVersion, uint16 partnerBps) {
        if (msg.sender != address(ledger)) revert OnlyLedger();
        (uint40 roundId, uint32[] memory numbers, uint16[] memory multipliers) =
            abi.decode(purchaseData, (uint40, uint32[], uint16[]));
        IRevenueAllocationTreasury.RoundRevenueAllocation memory allocation_ = _requireRevenueAllocation(roundId);
        if (numbers.length == 0 || numbers.length != multipliers.length) revert InvalidConfig();
        if (numbers.length > MAX_BATCH_SIZE) revert BatchTooLarge();

        uint256 expectedAmount;
        for (uint256 i = 0; i < numbers.length; i++) {
            expectedAmount += _buyFor(payer, beneficiary, roundId, numbers[i], multipliers[i]);
        }
        if (amount != expectedAmount) revert PurchaseAmountMismatch();
        ILottoTreasury(treasury).reserveRefunds(amount);

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
        if (!revenueAllocationEnabled) revert InvalidRevenueAllocation();
        allocation_ = IWusdLottoUmaRevenueTreasury(treasury).roundRevenueAllocation(roundId);
        if (!allocation_.snapshotted) revert InvalidRevenueAllocation();
    }

    function _quotePurchase(address beneficiary, uint40 roundId, uint32[] memory numbers, uint16[] memory multipliers)
        internal
        view
        returns (uint256 amount)
    {
        if (numbers.length == 0 || numbers.length != multipliers.length) revert InvalidConfig();
        if (numbers.length > MAX_BATCH_SIZE) revert BatchTooLarge();

        for (uint256 i = 0; i < numbers.length; i++) {
            amount += _validateTicket(beneficiary, roundId, numbers[i], multipliers[i]);
        }
    }

    /// @dev Core purchase logic. `buyer` is the ticket owner (beneficiary),
    ///      `msg.sender` is the payer (may be the buyer themselves or a ledger).
    function _buyFor(address payer, address buyer, uint40 roundId, uint32 number, uint16 multiplier)
        internal
        returns (uint256 paid)
    {
        paid = _validateTicket(buyer, roundId, number, multiplier);
        RoundData storage roundData = _rounds[roundId];
        uint256 units = uint256(multiplier);
        uint32 sixPrefix = LottoPrizeMath.prefix6(number);
        uint32 fivePrefix = LottoPrizeMath.prefix5(number);

        unchecked {
            ++nextTicketId;
            ++ticketsPerRound[roundId][buyer];
        }

        // Store ticket for potential refund and on-chain claim — ticket belongs to
        // buyer, payer gets refund. number/multiplier 新增字段用于结算时链上直接
        // 重新计算中奖等级和金额（见 LottoSettlement.claim），不再依赖 settler 提供
        // 的 Merkle 叶子数据。
        tickets[nextTicketId] = TicketData({
            buyer: buyer,
            number: number,
            multiplier: multiplier,
            refunded: false,
            claimed: false,
            payer: payer,
            roundId: roundId,
            paid: paid
        });
        _roundTicketIds[roundId].push(nextTicketId);

        roundData.totalSales += paid;
        roundData.totalUnits += units;

        exact7Units[roundId][number] += units;
        prefix6Units[roundId][sixPrefix] += units;
        prefix5Units[roundId][fivePrefix] += units;

        // 四/五等奖滑动窗口计数器写入：4 个 4 位窗口 + 5 个 3 位窗口，固定次数，O(1)。
        // 与 Lotto7Game.sol 的写入方式逐位对应，保证 LottoPrizeMath.highestTier 的
        // 判定结果与这里累加的窗口 key 完全一致。
        slide4Units[roundId][uint32(number / 1000)] += units;
        slide4Units[roundId][uint32((number / 100) % 10_000)] += units;
        slide4Units[roundId][uint32((number / 10) % 10_000)] += units;
        slide4Units[roundId][uint32(number % 10_000)] += units;

        slide3Units[roundId][uint32(number / 10_000)] += units;
        slide3Units[roundId][uint32((number / 1000) % 1000)] += units;
        slide3Units[roundId][uint32((number / 100) % 1000)] += units;
        slide3Units[roundId][uint32((number / 10) % 1000)] += units;
        slide3Units[roundId][uint32(number % 1000)] += units;

        emit TicketPurchased(nextTicketId, roundId, buyer, number, multiplier, paid);
    }

    function _validateTicket(address buyer, uint40 roundId, uint32 number, uint16 multiplier)
        internal
        view
        returns (uint256 paid)
    {
        if (buyer == address(0)) revert ZeroAddress();

        RoundData storage roundData = _rounds[roundId];
        if (!roundData.exists || roundData.cancelled || roundData.salesClosed) revert RoundNotOpen();
        if (block.timestamp < roundData.config.salesOpenTime || block.timestamp > roundData.config.salesCloseTime) {
            revert RoundNotOpen();
        }
        if (roundData.drawStatus == DrawStatus.PendingAssertion || roundData.drawStatus == DrawStatus.Drawn) {
            revert RoundNotOpen();
        }
        if (!LottoPrizeMath.isValidNumber(number)) revert InvalidNumber();
        if (multiplier == 0 || multiplier > roundData.config.maxMultiplierPerTicket) revert InvalidMultiplier();
        paid = uint256(multiplier) * ticketPrice;
    }

    function closeSales(uint40 roundId) external {
        RoundData storage roundData = _rounds[roundId];
        if (!roundData.exists || roundData.cancelled) {
            revert InvalidRound();
        }
        if (roundData.salesClosed) {
            revert SalesAlreadyClosed();
        }
        if (!hasRole(ADMIN_ROLE, msg.sender) && block.timestamp <= roundData.config.salesCloseTime) {
            revert RoundNotOpen();
        }

        roundData.salesClosed = true;
        emit SalesClosed(roundId);
    }

    function markDrawAssertionPending(
        uint40 roundId,
        bytes32 assertionId,
        bytes32 sourceBundleHash,
        uint32 winningNumberPreview,
        bytes32 normalizedDataHash
    ) external onlyRole(ORACLE_ROLE) {
        RoundData storage roundData = _rounds[roundId];
        if (!roundData.exists || roundData.cancelled) {
            revert InvalidRound();
        }
        if (roundData.drawStatus == DrawStatus.Drawn) {
            revert RoundAlreadyDrawn();
        }
        if (roundData.drawStatus == DrawStatus.PendingAssertion) {
            revert DrawAssertionPending();
        }
        if (assertionId == bytes32(0)) {
            revert InvalidAssertionId();
        }
        if (sourceBundleHash == bytes32(0)) {
            revert InvalidSourceBundleHash();
        }
        if (normalizedDataHash == bytes32(0)) {
            revert InvalidNormalizedDataHash();
        }
        if (!LottoPrizeMath.isValidNumber(winningNumberPreview)) {
            revert InvalidNumber();
        }
        if (!roundData.salesClosed) {
            if (block.timestamp <= roundData.config.salesCloseTime) {
                revert RoundNotOpen();
            }
            roundData.salesClosed = true;
            emit SalesClosed(roundId);
        }
        // First assertion must be before drawDataDeadline.
        // Retries after dispute/abandon are allowed past the deadline to prevent
        // rounds with sold tickets from becoming permanently stuck.
        if (!roundData.hasHadAssertion && block.timestamp > roundData.config.drawDataDeadline) {
            revert DrawWindowExpired();
        }

        roundData.hasHadAssertion = true;
        roundData.drawStatus = DrawStatus.PendingAssertion;
        roundData.oracleAssertionId = assertionId;
        roundData.oracleAdapter = msg.sender;
        roundData.winningNumberPreview = winningNumberPreview;
        roundData.sourceBundleHash = sourceBundleHash;
        roundData.normalizedDataHash = normalizedDataHash;

        emit DrawAssertionMarkedPending(
            roundId, assertionId, msg.sender, winningNumberPreview, sourceBundleHash, normalizedDataHash
        );
    }

    function markDrawAssertionDisputed(uint40 roundId, bytes32 assertionId) external onlyRole(ORACLE_ROLE) {
        _clearPendingAssertion(roundId, assertionId, true);
    }

    function clearPendingAssertionForRetry(uint40 roundId, bytes32 assertionId) external onlyRole(ORACLE_ROLE) {
        _clearPendingAssertion(roundId, assertionId, false);
    }

    function _clearPendingAssertion(uint40 roundId, bytes32 assertionId, bool disputed) internal {
        RoundData storage roundData = _rounds[roundId];
        if (!roundData.exists || roundData.cancelled) {
            revert InvalidRound();
        }
        if (roundData.drawStatus != DrawStatus.PendingAssertion) {
            revert DrawAssertionNotPending();
        }
        if (roundData.oracleAssertionId != assertionId) {
            revert InvalidAssertionForRound();
        }
        if (roundData.oracleAdapter != msg.sender) {
            revert InvalidOracleAdapter();
        }

        roundData.drawStatus = DrawStatus.ReadyForRetry;
        roundData.oracleAdapter = address(0);
        roundData.oracleAssertionId = bytes32(0);
        roundData.winningNumberPreview = 0;
        roundData.sourceBundleHash = bytes32(0);
        roundData.normalizedDataHash = bytes32(0);

        if (disputed) {
            emit DrawAssertionDisputed(roundId, assertionId);
        } else {
            emit DrawAssertionClearedForRetry(roundId, assertionId);
        }
    }

    function submitDraw(uint40 roundId, uint32 winningNumber, bytes32 sourceBundleHash) external onlyRole(ORACLE_ROLE) {
        RoundData storage roundData = _rounds[roundId];
        if (!roundData.exists || roundData.cancelled) {
            revert InvalidRound();
        }
        if (roundData.drawStatus == DrawStatus.Drawn) {
            revert RoundAlreadyDrawn();
        }
        if (roundData.drawStatus != DrawStatus.PendingAssertion) {
            revert DrawAssertionNotPending();
        }
        if (roundData.oracleAdapter != msg.sender) {
            revert InvalidOracleAdapter();
        }
        if (!LottoPrizeMath.isValidNumber(winningNumber)) {
            revert InvalidNumber();
        }
        if (sourceBundleHash == bytes32(0)) {
            revert InvalidSourceBundleHash();
        }
        if (winningNumber != roundData.winningNumberPreview || sourceBundleHash != roundData.sourceBundleHash) {
            revert InvalidDrawPayload();
        }
        if (!roundData.salesClosed) {
            revert RoundNotOpen();
        }
        roundData.drawStatus = DrawStatus.Drawn;
        roundData.winningNumber = winningNumber;
        roundData.drawResolvedAt = uint64(block.timestamp);

        emit DrawSubmitted(roundId, winningNumber, sourceBundleHash);
    }

    function cancelRound(uint40 roundId) external onlyRole(ADMIN_ROLE) {
        RoundData storage roundData = _rounds[roundId];
        if (!roundData.exists) {
            revert InvalidRound();
        }
        if (roundData.cancelled) {
            revert RoundAlreadyCancelled();
        }
        if (roundData.drawStatus == DrawStatus.Drawn) {
            revert RoundAlreadyDrawn();
        }

        roundData.cancelled = true;
        roundData.drawStatus = DrawStatus.Cancelled;

        emit RoundCancelled(roundId);
    }

    /// @notice Refund a ticket from a cancelled round. Anyone can call for any ticket.
    function refundTicket(uint256 ticketId) external nonReentrant {
        TicketData storage ticket = tickets[ticketId];
        if (ticket.buyer == address(0)) {
            revert InvalidRound();
        }
        if (ticket.refunded) {
            revert AlreadyRefunded();
        }
        RoundData storage roundData = _rounds[ticket.roundId];
        if (!roundData.cancelled) {
            revert RoundNotCancelled();
        }

        ticket.refunded = true;
        ILottoTreasury(treasury).payRefund(ticket.payer, ticket.paid);

        emit TicketRefunded(ticketId, ticket.roundId, ticket.payer, ticket.paid);
    }

    /// @notice 标记某张彩票已领取过奖金。仅供 LottoSettlement.claim 调用，用于
    ///         防止同一张彩票被反复领奖。链上直接结算模式下，中奖归属和金额由
    ///         LottoSettlement 根据 tickets[ticketId].number 与开奖号码自行算出，
    ///         不再有 settler 报告的 winningUnits/leaf 数据，因此防重放要落在
    ///         "这张 ticketId 有没有领过"这个粒度上，而不是旧版的 tier 粒度。
    function markTicketClaimed(uint256 ticketId) external onlyRole(SETTLEMENT_ROLE) {
        TicketData storage ticket = tickets[ticketId];
        if (ticket.buyer == address(0)) {
            revert InvalidTicket();
        }
        if (ticket.claimed) {
            revert TicketAlreadyClaimed();
        }
        ticket.claimed = true;
    }

    function getTicket(uint256 ticketId) external view returns (TicketData memory) {
        return tickets[ticketId];
    }

    function roundTicketCount(uint40 roundId) external view returns (uint256) {
        return _roundTicketIds[roundId].length;
    }

    function roundTicketIdAt(uint40 roundId, uint256 index) external view returns (uint256) {
        return _roundTicketIds[roundId][index];
    }

    function _authorizeUpgrade(address) internal override onlyRole(ADMIN_ROLE) {}

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function disableLegacyPurchases() external onlyRole(ADMIN_ROLE) {
        if (legacyPurchasesDisabled) revert LegacyPurchasesAreDisabled();
        legacyPurchasesDisabled = true;
        emit LegacyPurchasesPermanentlyDisabled();
    }

    function roundWinningNumber(uint40 roundId) external view returns (uint32) {
        return _rounds[roundId].winningNumber;
    }

    function roundClaimDeadline(uint40 roundId) external view returns (uint64) {
        return _rounds[roundId].config.claimDeadline;
    }

    function roundTotalSales(uint40 roundId) external view returns (uint256) {
        return _rounds[roundId].totalSales;
    }

    function roundSourceBundleHash(uint40 roundId) external view returns (bytes32) {
        return _rounds[roundId].sourceBundleHash;
    }

    function roundNormalizedDataHash(uint40 roundId) external view returns (bytes32) {
        return _rounds[roundId].normalizedDataHash;
    }

    function roundOracleAssertionId(uint40 roundId) external view returns (bytes32) {
        return _rounds[roundId].oracleAssertionId;
    }

    function roundDrawStatus(uint40 roundId) external view returns (DrawStatus) {
        return _rounds[roundId].drawStatus;
    }

    function getRound(uint40 roundId) external view returns (RoundData memory) {
        return _rounds[roundId];
    }

    function isRoundDrawn(uint40 roundId) external view returns (bool) {
        RoundData storage roundData = _rounds[roundId];
        return roundData.exists && roundData.drawStatus == DrawStatus.Drawn && !roundData.cancelled;
    }
}
