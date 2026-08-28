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

/// @title WusdLottoRounds
/// @notice Manages World Lotto rounds, ticket sales, and on-chain counters.
/// @dev Direct purchases debit the caller through the WUSD ledger in the same transaction.
///
/// Trust model:
/// - ADMIN_ROLE can create rounds, close sales early, pause the contract, and
///   cancel rounds (before any sales). This is a privileged role that should be
///   held by a multisig or governance contract in production.
/// - ORACLE_ROLE is granted to the OracleAdapter contract, not an EOA.
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
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant BUYER_ROLE = keccak256("BUYER_ROLE");
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

    IUnifiedLedgerV2 public ledger;
    address public treasury;
    uint256 public ticketPrice;
    uint256 public nextTicketId;

    mapping(uint40 roundId => RoundData roundData) private _rounds;

    mapping(uint40 roundId => mapping(uint32 number => uint256 units)) public exact7Units;
    mapping(uint40 roundId => mapping(uint32 prefix6 => uint256 units)) public prefix6Units;
    mapping(uint40 roundId => mapping(uint32 prefix5 => uint256 units)) public prefix5Units;

    mapping(uint40 roundId => mapping(uint32 windowKey => uint256 units)) public slide4Units;
    mapping(uint40 roundId => mapping(uint32 windowKey => uint256 units)) public slide3Units;

    mapping(uint40 roundId => mapping(address user => uint256 count)) public ticketsPerRound;

    mapping(uint256 ticketId => TicketData) public tickets;
    uint256 public purchaseReceiptNonce;
    bool public legacyPurchasesDisabled;
    mapping(uint40 roundId => uint256[] ticketIds) private _roundTicketIds;
    bool public revenueAllocationEnabled;

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

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
    }

    function createRound(uint40 roundId, RoundConfig calldata config) external onlyRole(ADMIN_ROLE) {
        if (roundId == 0) {
            revert InvalidRound();
        }
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

        emit RoundCreated(roundId);
    }

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

        // Store ticket for potential refund and on-chain claim - ticket belongs to
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
    function refundTicket(uint256 ticketId) external whenNotPaused nonReentrant {
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
