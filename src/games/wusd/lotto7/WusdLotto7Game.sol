// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {IUnifiedLedgerV2} from "../../../wusd/IUnifiedLedgerV2.sol";
import {IGameModuleV3} from "../../../protocol/IGameModuleV3.sol";
import {IGameModuleV4} from "../../../protocol/IGameModuleV4.sol";
import {IRevenueAllocationTreasury} from "../../../protocol/IRevenueAllocationTreasury.sol";
import {ILotto7Game} from "../../lotto7/interfaces/ILotto7Game.sol";
import {ILotto7Treasury} from "../../lotto7/interfaces/ILotto7Treasury.sol";
import {LottoPrizeMath} from "../../libraries/LottoPrizeMath.sol";
import {IWusdLotto7Treasury} from "./IWusdLotto7Treasury.sol";

/// @title WusdLotto7Game
/// @notice 使用统一 WUSD 内部余额的 7 位数字乐透状态机。
/// @dev 不识别充值资产；玩家主动调用 buy 时由已登记游戏在同一交易中扣除 WUSD。
contract WusdLotto7Game is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    ILotto7Game,
    IGameModuleV3,
    IGameModuleV4
{
    // ─── Roles ──────────────────────────────────────────────────────────
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant GAME_ROLE = keccak256("GAME_ROLE"); // 授予 Lotto7VRFAdapter

    // ─── Constants ──────────────────────────────────────────────────────
    uint32 public constant MAX_NUMBER = 9_999_999;
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_BATCH_SIZE = 100;

    // ─── Errors ─────────────────────────────────────────────────────────
    error ZeroAddress();
    error ZeroAmount();
    error InvalidParam();
    error ExceedsRoundLimit();
    error ExceedsMultiplierLimit();
    error RoundNotOpen();
    error InvalidNumber(uint32 num);
    error InvalidMultiplier();
    error RoundNotResolved(uint256 roundId);
    error AlreadyClaimed();
    error NoPrize();
    error EmptyPurchase();
    error InvalidTicketIndex();
    error LengthMismatch();
    error BadState();
    error DrawDeadlineNotReached();
    error RoundNotCancelled(uint256 roundId);
    error NoRefund();
    error RefundAlreadyClaimed();
    error OnlyLedger();
    error PurchaseAmountMismatch();
    error UnsupportedBeneficiary();
    error WrongRound();
    error LegacyPurchasesAreDisabled();
    error PrizeClaimExpired(uint256 roundId);
    error RevenueAlreadyActive();
    error InvalidRevenueAllocation();

    // ─── Economy config（当前生效值，新轮次开始时被快照进 Round.economy） ──
    uint256 public ticketPrice;
    uint256 public roundDuration;
    uint256 public betWindow;

    uint256 public maxPerUserPerRound;
    uint32 public maxMultiplier;
    uint32 public maxTotalMultiplierPerUserPerRound;

    uint256 public allocPrizeBps;
    uint256 public allocOpsBps;
    uint256 public floatTier1Bps;
    uint256 public floatTier2Bps;
    uint256 public floatTier3Bps;
    uint256 public fixedTier4;
    uint256 public fixedTier5;
    uint256 public capTier1;
    uint256 public capTier2;
    uint256 public capTier3;
    uint256 public circuitBreakerBps;

    // ─── State ──────────────────────────────────────────────────────────
    IUnifiedLedgerV2 public ledger;
    ILotto7Treasury public treasury;

    uint256 public currentRoundId;

    mapping(uint256 => Round) private _rounds;

    mapping(uint256 => mapping(address => uint256)) public userBoughtCount;
    mapping(uint256 => mapping(address => uint256)) public userTotalMultiplier;
    mapping(uint256 => mapping(address => uint32[])) public userTickets;
    mapping(uint256 => mapping(address => uint32[])) public userMultipliers;
    mapping(uint256 => mapping(address => mapping(uint256 => bool))) public isClaimed;

    mapping(uint256 => mapping(uint32 => uint256)) public cnt7;
    mapping(uint256 => mapping(uint32 => uint256)) public cnt6;
    mapping(uint256 => mapping(uint32 => uint256)) public cnt5;

    mapping(uint256 => mapping(uint32 => uint256)) public slide4;
    mapping(uint256 => mapping(uint32 => uint256)) public slide3;

    /// @dev UUPS storage：只在既有状态变量末尾追加，保持升级存储布局兼容。
    mapping(uint256 => mapping(address => bool)) public refundClaimed;
    uint256 public purchaseReceiptNonce;
    bool public legacyPurchasesDisabled;
    uint64 public claimPeriod;
    mapping(uint256 => uint64) public roundClaimDeadline;
    mapping(uint256 => bool) public sharedCarryAccountingEnabled;
    mapping(uint256 => uint64) public roundClaimPeriodSnapshot;
    bool public revenueAllocationEnabled;

    event LedgerPurchase(
        bytes32 indexed receiptId, uint256 indexed roundId, address indexed payer, address beneficiary, uint256 amount
    );
    event LegacyPurchasesPermanentlyDisabled();
    event RoundClaimWindowOpened(uint256 indexed roundId, uint256 claimDeadline, uint256 winnerLiability);
    event ClaimPeriodUpdated(uint256 previousPeriod, uint256 newPeriod);

    // ─── Initializer ────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin_, IUnifiedLedgerV2 ledger_, ILotto7Treasury treasury_, uint256 firstRoundStart_)
        public
        initializer
    {
        if (admin_ == address(0) || address(ledger_) == address(0) || address(treasury_) == address(0)) {
            revert ZeroAddress();
        }

        __AccessControl_init();
        __Pausable_init();

        ledger = ledger_;
        treasury = treasury_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);

        ticketPrice = 1e6;
        roundDuration = 10 minutes;
        betWindow = 7 minutes;

        maxPerUserPerRound = 10;
        maxMultiplier = 999;
        maxTotalMultiplierPerUserPerRound = 200;

        allocPrizeBps = 8000;
        allocOpsBps = 1500;
        floatTier1Bps = 5000;
        floatTier2Bps = 3000;
        floatTier3Bps = 2000;
        fixedTier4 = 100e6;
        fixedTier5 = 5e6;
        capTier1 = 10_000_000e6;
        capTier2 = 1_000_000e6;
        capTier3 = 10_000e6;
        circuitBreakerBps = 5000;
        claimPeriod = 90 days;

        currentRoundId = 1;
        _initRound(1, _alignRoundStart(firstRoundStart_));
    }

    // ─── 1. Buy Tickets ──────────────────────────────────────────────────

    function protocolImplementationHash() external view returns (bytes32) {
        return ERC1967Utils.getImplementation().codehash;
    }

    function initializeRevenueV4() external reinitializer(2) onlyRole(ADMIN_ROLE) {
        if (_rounds[currentRoundId].sales != 0) revert RevenueAlreadyActive();
        IWusdLotto7Treasury(address(treasury)).snapshotRoundAllocation(currentRoundId);
        revenueAllocationEnabled = true;
    }

    function buy(uint32[] calldata numbers, uint32[] calldata multipliers) external nonReentrant whenNotPaused {
        if (legacyPurchasesDisabled) revert LegacyPurchasesAreDisabled();
        uint256 rId = currentRoundId;
        uint256 cost = _recordPurchase(msg.sender, rId, numbers, multipliers);

        // 玩家主动调用 buy，可信游戏在同一笔交易中完成 WUSD 扣款，无需预先授权。
        ledger.directOperatorTransfer(msg.sender, address(treasury), cost);
    }

    function quotePurchase(address, address beneficiary, bytes calldata purchaseData)
        external
        view
        returns (uint256 amount)
    {
        (uint256 roundId, uint32[] memory numbers, uint32[] memory multipliers) =
            abi.decode(purchaseData, (uint256, uint32[], uint32[]));
        (, amount) = _validatePurchase(beneficiary, roundId, numbers, multipliers);
    }

    function purchaseFromLedger(address payer, address beneficiary, uint256 amount, bytes calldata purchaseData)
        external
        nonReentrant
        whenNotPaused
        returns (bytes32 receiptId)
    {
        if (msg.sender != address(ledger)) revert OnlyLedger();
        if (payer != beneficiary) revert UnsupportedBeneficiary();

        (uint256 roundId, uint32[] memory numbers, uint32[] memory multipliers) =
            abi.decode(purchaseData, (uint256, uint32[], uint32[]));
        uint256 expectedAmount = _recordPurchase(beneficiary, roundId, numbers, multipliers);
        if (amount != expectedAmount) revert PurchaseAmountMismatch();

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
    ) external nonReentrant whenNotPaused returns (bytes32 receiptId, uint32 allocationVersion, uint16 partnerBps) {
        if (msg.sender != address(ledger)) revert OnlyLedger();
        if (payer != beneficiary) revert UnsupportedBeneficiary();

        (uint256 roundId, uint32[] memory numbers, uint32[] memory multipliers) =
            abi.decode(purchaseData, (uint256, uint32[], uint32[]));
        IRevenueAllocationTreasury.RoundRevenueAllocation memory allocation_ = _requireRevenueAllocation(roundId);
        uint256 expectedAmount = _recordPurchase(beneficiary, roundId, numbers, multipliers);
        if (amount != expectedAmount) revert PurchaseAmountMismatch();

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

    function _requireRevenueAllocation(uint256 roundId)
        internal
        view
        returns (IRevenueAllocationTreasury.RoundRevenueAllocation memory allocation_)
    {
        if (!revenueAllocationEnabled) revert InvalidRevenueAllocation();
        allocation_ = IWusdLotto7Treasury(address(treasury)).roundRevenueAllocation(roundId);
        if (!allocation_.snapshotted) revert InvalidRevenueAllocation();
    }

    function _recordPurchase(address buyer, uint256 roundId, uint32[] memory numbers, uint32[] memory multipliers)
        internal
        returns (uint256 cost)
    {
        (uint256 totalUnits, uint256 quotedCost) = _validatePurchase(buyer, roundId, numbers, multipliers);
        Round storage r = _rounds[roundId];

        for (uint256 i = 0; i < numbers.length;) {
            uint32 num = numbers[i];
            uint32 mul = multipliers[i];

            userTickets[roundId][buyer].push(num);
            userMultipliers[roundId][buyer].push(mul);

            cnt7[roundId][num] += mul;
            cnt6[roundId][LottoPrizeMath.prefix6(num)] += mul;
            cnt5[roundId][LottoPrizeMath.prefix5(num)] += mul;

            slide4[roundId][uint32(num / 1000)] += mul;
            slide4[roundId][uint32((num / 100) % 10_000)] += mul;
            slide4[roundId][uint32((num / 10) % 10_000)] += mul;
            slide4[roundId][uint32(num % 10_000)] += mul;

            slide3[roundId][uint32(num / 10_000)] += mul;
            slide3[roundId][uint32((num / 1000) % 1000)] += mul;
            slide3[roundId][uint32((num / 100) % 1000)] += mul;
            slide3[roundId][uint32((num / 10) % 1000)] += mul;
            slide3[roundId][uint32(num % 1000)] += mul;

            unchecked {
                ++i;
            }
        }

        userBoughtCount[roundId][buyer] += numbers.length;
        userTotalMultiplier[roundId][buyer] += totalUnits;
        r.sales += quotedCost;
        emit TicketBought(roundId, buyer, numbers, multipliers);
        return quotedCost;
    }

    function _validatePurchase(address buyer, uint256 roundId, uint32[] memory numbers, uint32[] memory multipliers)
        internal
        view
        returns (uint256 totalUnits, uint256 cost)
    {
        uint256 len = numbers.length;
        if (roundId != currentRoundId) revert WrongRound();
        if (len == 0) revert EmptyPurchase();
        if (len != multipliers.length) revert LengthMismatch();
        if (len > MAX_BATCH_SIZE) revert ExceedsRoundLimit();

        Round storage r = _rounds[roundId];
        if (block.timestamp < r.startTime || block.timestamp >= r.betCloseTime) revert RoundNotOpen();
        if (userBoughtCount[roundId][buyer] + len > r.economy.maxPerUserPerRound) revert ExceedsRoundLimit();

        for (uint256 i = 0; i < len;) {
            uint32 num = numbers[i];
            uint32 mul = multipliers[i];
            if (num > MAX_NUMBER) revert InvalidNumber(num);
            if (mul == 0 || mul > r.economy.maxMultiplier) revert InvalidMultiplier();
            totalUnits += mul;
            unchecked {
                ++i;
            }
        }

        if (userTotalMultiplier[roundId][buyer] + totalUnits > r.economy.maxTotalMultiplierPerUserPerRound) {
            revert ExceedsMultiplierLimit();
        }
        cost = totalUnits * r.economy.ticketPrice;
    }

    // ─── 2. Settlement（仅 Lotto7VRFAdapter 可调用） ─────────────────────

    /// @inheritdoc ILotto7Game
    function settleDraw(uint256 roundId, uint32 winningNumber) external onlyRole(GAME_ROLE) nonReentrant {
        Round storage r = _rounds[roundId];
        if (r.status != RoundStatus.Open && r.status != RoundStatus.BetClosed) revert BadState();
        if (winningNumber > MAX_NUMBER) revert InvalidNumber(winningNumber);

        r.winningNumber = winningNumber;
        r.status = RoundStatus.Resolved;

        if (r.sales > 0) {
            treasury.collectSales(roundId, r.sales);
        }
        uint256 prizePool = treasury.settleRoundPrize(roundId);
        r.prizePool = prizePool;

        // ---- Tier 1-3：前缀命中，逐级排除已被更高等级计入的份数 ----
        uint256 c7 = cnt7[roundId][winningNumber];
        uint256 c6 = cnt6[roundId][LottoPrizeMath.prefix6(winningNumber)];
        uint256 c5 = cnt5[roundId][LottoPrizeMath.prefix5(winningNumber)];

        r.winUnits1 = c7;
        r.winUnits2 = c6 > c7 ? c6 - c7 : 0;
        r.winUnits3 = c5 > c6 ? c5 - c6 : 0;

        // ---- Tier 4/5：滑动窗口保守上界估算（用于熔断判定，非实际派彩来源） ----
        uint256 w4Est = _countSlide4Hits(roundId, winningNumber);
        uint256 w5Est = _countSlide3Hits(roundId, winningNumber);

        _calculatePayouts(roundId, w4Est, w5Est);

        if (roundId == currentRoundId) {
            currentRoundId++;
            _initRound(currentRoundId, _alignRoundStart(block.timestamp));
        }

        emit RoundResolved(roundId, winningNumber, prizePool);
    }

    // ─── 2b. VRF Liveness：超时只能取消退款，不能重新抽奖 ───────────────

    /// @notice `endTime` 是“尚未成功申请 VRF”的硬截止时间。只有 VRF Adapter 能调用，
    ///         Adapter 会先在自身状态中确认该轮从未生成 requestId。已经成功申请的随机数
    ///         不能取消或重抽，只能等待原 callback 并用同一个结果重试结算。
    function cancelTimedOutRound(uint256 roundId) external onlyRole(GAME_ROLE) {
        Round storage r = _rounds[roundId];
        if (r.status != RoundStatus.Open && r.status != RoundStatus.BetClosed) revert BadState();
        if (block.timestamp < r.endTime) revert DrawDeadlineNotReached();

        r.status = RoundStatus.Cancelled;

        if (roundId == currentRoundId) {
            currentRoundId++;
            _initRound(currentRoundId, _alignRoundStart(block.timestamp));
        }

        emit RoundCancelled(roundId, block.timestamp);
    }

    /// @notice 玩家主动领取已取消轮次的完整票款。按购票时快照票价与总 multiplier 计算，
    ///         不循环遍历彩票，gas 成本恒定；即使协议处于 pause 状态仍可退款退出。
    function claimRefund(uint256 roundId) external nonReentrant {
        Round storage r = _rounds[roundId];
        if (r.status != RoundStatus.Cancelled) revert RoundNotCancelled(roundId);
        if (refundClaimed[roundId][msg.sender]) revert RefundAlreadyClaimed();

        uint256 units = userTotalMultiplier[roundId][msg.sender];
        if (units == 0) revert NoRefund();

        uint256 amount = units * r.economy.ticketPrice;
        refundClaimed[roundId][msg.sender] = true;
        treasury.payRefund(msg.sender, amount);

        emit RefundClaimed(roundId, msg.sender, amount);
    }

    function _countSlide4Hits(uint256 rId, uint32 win) internal view returns (uint256 total) {
        uint32[4] memory keys =
            [uint32(win / 1000), uint32((win / 100) % 10_000), uint32((win / 10) % 10_000), uint32(win % 10_000)];

        for (uint256 i = 0; i < 4;) {
            bool seen;
            for (uint256 j = 0; j < i;) {
                if (keys[j] == keys[i]) {
                    seen = true;
                    break;
                }
                unchecked {
                    ++j;
                }
            }
            if (!seen) {
                total += slide4[rId][keys[i]];
            }
            unchecked {
                ++i;
            }
        }
    }

    function _countSlide3Hits(uint256 rId, uint32 win) internal view returns (uint256 total) {
        uint32[5] memory keys = [
            uint32(win / 10_000),
            uint32((win / 1000) % 1000),
            uint32((win / 100) % 1000),
            uint32((win / 10) % 1000),
            uint32(win % 1000)
        ];

        for (uint256 i = 0; i < 5;) {
            bool seen;
            for (uint256 j = 0; j < i;) {
                if (keys[j] == keys[i]) {
                    seen = true;
                    break;
                }
                unchecked {
                    ++j;
                }
            }
            if (!seen) {
                total += slide3[rId][keys[i]];
            }
            unchecked {
                ++i;
            }
        }
    }

    function _calculatePayouts(uint256 rId, uint256 w4Est, uint256 w5Est) internal {
        Round storage r = _rounds[rId];

        uint256 fixedTotal = w4Est * r.economy.fixedTier4 + w5Est * r.economy.fixedTier5;
        uint256 circuitCap = (r.prizePool * r.economy.circuitBreakerBps) / BPS;

        if (fixedTotal > circuitCap && fixedTotal > 0) {
            r.payout4 = (circuitCap * r.economy.fixedTier4) / fixedTotal;
            r.payout5 = (circuitCap * r.economy.fixedTier5) / fixedTotal;
        } else {
            r.payout4 = r.economy.fixedTier4;
            r.payout5 = r.economy.fixedTier5;
        }

        uint256 fixedLiability = w4Est * r.payout4 + w5Est * r.payout5;
        uint256 floatPool = r.prizePool - fixedLiability;

        IWusdLotto7Treasury extendedTreasury = IWusdLotto7Treasury(address(treasury));
        (uint256 available1, uint256 available2, uint256 available3,) = extendedTreasury.previewRoundPools(
            floatPool, r.economy.floatTier1Bps, r.economy.floatTier2Bps, r.economy.floatTier3Bps
        );

        uint256 tier1Liability;
        uint256 tier2Liability;
        uint256 tier3Liability;
        (r.payout1, tier1Liability) = _calcTierFloat(r.winUnits1, available1, r.economy.capTier1);
        (r.payout2, tier2Liability) = _calcTierFloat(r.winUnits2, available2, r.economy.capTier2);
        (r.payout3, tier3Liability) = _calcTierFloat(r.winUnits3, available3, r.economy.capTier3);

        uint256 claimDeadlineValue = block.timestamp + _claimPeriodForRound(rId);
        if (claimDeadlineValue > type(uint64).max) revert InvalidParam();
        uint64 claimDeadline = uint64(claimDeadlineValue);
        uint256 winnerLiability = fixedLiability + tier1Liability + tier2Liability + tier3Liability;

        extendedTreasury.finalizeRoundAccounting(
            IWusdLotto7Treasury.RoundAccounting({
                roundId: rId,
                claimDeadline: claimDeadline,
                floatPool: floatPool,
                fixedLiability: fixedLiability,
                tier1Liability: tier1Liability,
                tier2Liability: tier2Liability,
                tier3Liability: tier3Liability,
                tier1Bps: r.economy.floatTier1Bps,
                tier2Bps: r.economy.floatTier2Bps,
                tier3Bps: r.economy.floatTier3Bps
            })
        );

        roundClaimDeadline[rId] = claimDeadline;
        sharedCarryAccountingEnabled[rId] = true;
        emit RoundClaimWindowOpened(rId, claimDeadline, winnerLiability);
    }

    function _calcTierFloat(uint256 winnerUnits, uint256 available, uint256 cap)
        internal
        pure
        returns (uint256 payout, uint256 liability)
    {
        if (winnerUnits > 0) {
            uint256 perUnit = available / winnerUnits;
            payout = perUnit > cap ? cap : perUnit;
            liability = payout * winnerUnits;
        }
    }

    // ─── 3. Claim Prize ──────────────────────────────────────────────────

    function claim(uint256 roundId, uint256 ticketIdx) external nonReentrant {
        Round storage r = _rounds[roundId];
        if (r.status != RoundStatus.Resolved) revert RoundNotResolved(roundId);
        if (sharedCarryAccountingEnabled[roundId] && block.timestamp > roundClaimDeadline[roundId]) {
            revert PrizeClaimExpired(roundId);
        }
        if (isClaimed[roundId][msg.sender][ticketIdx]) revert AlreadyClaimed();

        uint32[] storage ticketNums = userTickets[roundId][msg.sender];
        if (ticketIdx >= ticketNums.length) revert InvalidTicketIndex();

        uint32 myNum = ticketNums[ticketIdx];
        uint32 mul = userMultipliers[roundId][msg.sender][ticketIdx];

        (uint8 tier, uint256 basePayout) = _getTierPayout(myNum, r);
        if (basePayout == 0) revert NoPrize();

        uint256 amount = basePayout * mul;
        isClaimed[roundId][msg.sender][ticketIdx] = true;

        uint256 recycled = _calcRecyclableFixed(myNum, r.winningNumber, mul, r);
        if (sharedCarryAccountingEnabled[roundId]) {
            if (recycled > 0) {
                IWusdLotto7Treasury(address(treasury)).recycleRoundLiability(roundId, recycled);
                emit FixedPrizeRecycled(roundId, msg.sender, ticketIdx, recycled);
            }
            IWusdLotto7Treasury(address(treasury)).payRoundClaim(roundId, msg.sender, amount);
        } else {
            if (recycled > 0) {
                (uint256 j1, uint256 j2, uint256 j3) = treasury.getJackpots();
                ILotto7TreasuryJackpotSetter(address(treasury)).setJackpots(j1 + recycled, j2, j3);
                emit FixedPrizeRecycled(roundId, msg.sender, ticketIdx, recycled);
            }
            treasury.payClaim(msg.sender, amount);
        }
        emit PrizeClaimed(roundId, msg.sender, ticketIdx, tier, amount);
    }

    function _getTierPayout(uint32 myNum, Round storage r) internal view returns (uint8 tier, uint256 basePayout) {
        tier = LottoPrizeMath.highestTier(myNum, r.winningNumber);
        if (tier == 1) basePayout = r.payout1;
        else if (tier == 2) basePayout = r.payout2;
        else if (tier == 3) basePayout = r.payout3;
        else if (tier == 4) basePayout = r.payout4;
        else if (tier == 5) basePayout = r.payout5;
    }

    function _calcRecyclableFixed(uint32 myNum, uint32 winNum, uint32 mul, Round storage r)
        internal
        view
        returns (uint256)
    {
        uint8 tier = LottoPrizeMath.highestTier(myNum, winNum);
        uint256 slide4Matches = _countSlide4Matches(myNum, winNum);
        uint256 slide3Matches = _countSlide3Matches(myNum, winNum);
        uint256 recycled;

        if (tier <= 3) {
            recycled = slide4Matches * r.payout4 + slide3Matches * r.payout5;
        } else if (tier == 4) {
            if (slide4Matches > 1) recycled = (slide4Matches - 1) * r.payout4;
            recycled += slide3Matches * r.payout5;
        } else if (tier == 5 && slide3Matches > 1) {
            recycled = (slide3Matches - 1) * r.payout5;
        }
        return recycled * mul;
    }

    function _countSlide4Matches(uint32 myNum, uint32 winNum) internal pure returns (uint256 matches_) {
        uint32[4] memory a = [
            uint32(myNum / 1000), uint32((myNum / 100) % 10_000), uint32((myNum / 10) % 10_000), uint32(myNum % 10_000)
        ];
        uint32[4] memory b = [
            uint32(winNum / 1000),
            uint32((winNum / 100) % 10_000),
            uint32((winNum / 10) % 10_000),
            uint32(winNum % 10_000)
        ];

        for (uint256 i = 0; i < 4;) {
            for (uint256 j = 0; j < 4;) {
                if (a[i] == b[j]) {
                    matches_++;
                    break;
                }
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    function _countSlide3Matches(uint32 myNum, uint32 winNum) internal pure returns (uint256 matches_) {
        uint32[5] memory a = [
            uint32(myNum / 10_000),
            uint32((myNum / 1000) % 1000),
            uint32((myNum / 100) % 1000),
            uint32((myNum / 10) % 1000),
            uint32(myNum % 1000)
        ];
        uint32[5] memory b = [
            uint32(winNum / 10_000),
            uint32((winNum / 1000) % 1000),
            uint32((winNum / 100) % 1000),
            uint32((winNum / 10) % 1000),
            uint32(winNum % 1000)
        ];

        for (uint256 i = 0; i < 5;) {
            for (uint256 j = 0; j < 5;) {
                if (a[i] == b[j]) {
                    matches_++;
                    break;
                }
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    function expireRoundClaims(uint256 roundId) external returns (uint256 recycledAmount) {
        if (!sharedCarryAccountingEnabled[roundId]) revert RoundNotResolved(roundId);
        recycledAmount = IWusdLotto7Treasury(address(treasury)).expireRoundClaims(roundId);
    }

    // ─── 4. Admin — Economy Params（要求 whenPaused，防止轮次进行中改规则） ──

    function setTicketPrice(uint256 _price) external onlyRole(ADMIN_ROLE) whenPaused {
        if (_price == 0) revert InvalidParam();
        ticketPrice = _price;
    }

    function setRoundTiming(uint256 _duration, uint256 _betWindow) external onlyRole(ADMIN_ROLE) whenPaused {
        if (_duration == 0 || _betWindow == 0 || _betWindow >= _duration) revert InvalidParam();
        roundDuration = _duration;
        betWindow = _betWindow;
    }

    function setMaxPerUser(uint256 _max) external onlyRole(ADMIN_ROLE) whenPaused {
        if (_max == 0) revert InvalidParam();
        maxPerUserPerRound = _max;
    }

    function setMaxMultiplier(uint32 _max) external onlyRole(ADMIN_ROLE) whenPaused {
        if (_max == 0) revert InvalidParam();
        maxMultiplier = _max;
    }

    function setMaxTotalMultiplierPerUserPerRound(uint32 _max) external onlyRole(ADMIN_ROLE) whenPaused {
        if (_max == 0) revert InvalidParam();
        maxTotalMultiplierPerUserPerRound = _max;
    }

    function setAllocBps(uint256 _prize, uint256 _ops) external onlyRole(ADMIN_ROLE) whenPaused {
        if (_prize + _ops != BPS) revert InvalidParam();
        allocPrizeBps = _prize;
        allocOpsBps = _ops;
    }

    function setFloatBps(uint256 _t1, uint256 _t2, uint256 _t3) external onlyRole(ADMIN_ROLE) whenPaused {
        if (_t1 + _t2 + _t3 != BPS) revert InvalidParam();
        floatTier1Bps = _t1;
        floatTier2Bps = _t2;
        floatTier3Bps = _t3;
    }

    function setFixedPrizes(uint256 _tier4, uint256 _tier5) external onlyRole(ADMIN_ROLE) whenPaused {
        fixedTier4 = _tier4;
        fixedTier5 = _tier5;
    }

    function setCaps(uint256 _cap1, uint256 _cap2, uint256 _cap3) external onlyRole(ADMIN_ROLE) whenPaused {
        capTier1 = _cap1;
        capTier2 = _cap2;
        capTier3 = _cap3;
    }

    function setCircuitBreaker(uint256 _bps) external onlyRole(ADMIN_ROLE) whenPaused {
        if (_bps > BPS) revert InvalidParam();
        circuitBreakerBps = _bps;
    }

    function setClaimPeriod(uint64 newClaimPeriod) external onlyRole(ADMIN_ROLE) whenPaused {
        if (newClaimPeriod == 0) revert InvalidParam();
        uint256 previousPeriod = _effectiveClaimPeriod();
        claimPeriod = newClaimPeriod;
        emit ClaimPeriodUpdated(previousPeriod, newClaimPeriod);
    }

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

    function _authorizeUpgrade(address) internal override onlyRole(ADMIN_ROLE) {}

    // ─── 5. Views ───────────────────────────────────────────────────────

    function getRound(uint256 roundId) external view returns (Round memory) {
        return _rounds[roundId];
    }

    function getUserTickets(uint256 roundId, address user) external view returns (uint32[] memory) {
        return userTickets[roundId][user];
    }

    function getUserMultipliers(uint256 roundId, address user) external view returns (uint32[] memory) {
        return userMultipliers[roundId][user];
    }

    function checkTicket(uint256 roundId, address user, uint256 ticketIdx)
        external
        view
        returns (uint8 tier, uint256 amount, bool claimed, uint32 multiplier)
    {
        Round storage r = _rounds[roundId];
        uint32[] storage ticketNums = userTickets[roundId][user];
        if (ticketIdx >= ticketNums.length) return (0, 0, false, 0);

        claimed = isClaimed[roundId][user][ticketIdx];
        if (r.status != RoundStatus.Resolved) return (0, 0, claimed, 0);

        multiplier = userMultipliers[roundId][user][ticketIdx];
        uint256 basePayout;
        (tier, basePayout) = _getTierPayout(ticketNums[ticketIdx], r);
        amount = basePayout * multiplier;
    }

    function isBettingOpen() external view returns (bool) {
        Round storage r = _rounds[currentRoundId];
        return block.timestamp >= r.startTime && block.timestamp < r.betCloseTime;
    }

    function isClaimOpen(uint256 roundId) external view returns (bool) {
        if (!sharedCarryAccountingEnabled[roundId]) return _rounds[roundId].status == RoundStatus.Resolved;
        return block.timestamp <= roundClaimDeadline[roundId];
    }

    // ─── Internal ───────────────────────────────────────────────────────

    /// @dev 所有轮次固定在 UTC/Unix 时间的 roundDuration 边界开始。
    ///      VRF 或 Keeper 延迟不会再把后续轮次漂移到任意秒数；若本期结算时
    ///      已错过一个边界，则等待下一个完整边界开始，而不是压缩下注窗口。
    function _alignRoundStart(uint256 timestamp) internal view returns (uint256) {
        uint256 remainder = timestamp % roundDuration;
        return remainder == 0 ? timestamp : timestamp + (roundDuration - remainder);
    }

    function _effectiveClaimPeriod() internal view returns (uint256) {
        return claimPeriod == 0 ? 90 days : claimPeriod;
    }

    function _claimPeriodForRound(uint256 roundId) internal view returns (uint256) {
        uint64 snapshot = roundClaimPeriodSnapshot[roundId];
        return snapshot == 0 ? _effectiveClaimPeriod() : snapshot;
    }

    function _initRound(uint256 rId, uint256 start) internal {
        Round storage r = _rounds[rId];

        r.startTime = start;
        r.betCloseTime = start + betWindow;
        r.endTime = start + roundDuration;
        r.status = RoundStatus.Open;
        roundClaimPeriodSnapshot[rId] = claimPeriod == 0 ? uint64(90 days) : claimPeriod;

        r.economy = EconomySnapshot({
            ticketPrice: ticketPrice,
            maxPerUserPerRound: maxPerUserPerRound,
            maxMultiplier: maxMultiplier,
            maxTotalMultiplierPerUserPerRound: maxTotalMultiplierPerUserPerRound,
            allocPrizeBps: allocPrizeBps,
            allocOpsBps: allocOpsBps,
            floatTier1Bps: floatTier1Bps,
            floatTier2Bps: floatTier2Bps,
            floatTier3Bps: floatTier3Bps,
            fixedTier4: fixedTier4,
            fixedTier5: fixedTier5,
            capTier1: capTier1,
            capTier2: capTier2,
            capTier3: capTier3,
            circuitBreakerBps: circuitBreakerBps
        });

        if (revenueAllocationEnabled) {
            IWusdLotto7Treasury(address(treasury)).snapshotRoundAllocation(rId);
        }

        emit RoundStarted(rId, r.startTime, r.betCloseTime, r.endTime);
    }
}

/// @dev Lotto7Treasury 的 setJackpots 不属于 ILotto7Treasury 公开接口，Game 合约通过
///      这个最小化的兄弟接口调用，仅声明所需的这一个函数。原样移植，未作改动。
interface ILotto7TreasuryJackpotSetter {
    function setJackpots(uint256 j1, uint256 j2, uint256 j3) external;
}
