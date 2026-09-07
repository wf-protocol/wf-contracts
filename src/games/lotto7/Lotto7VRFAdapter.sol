// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {ILotto7Game} from "./interfaces/ILotto7Game.sol";
import {IVRFCoordinatorV2Plus} from "./interfaces/IVRFCoordinatorV2Plus.sol";

/// @title Lotto7VRFAdapter
/// @notice Chainlink VRF v2+ 集成层：callback 只保存随机数，结算使用同一结果独立重试。
contract Lotto7VRFAdapter is Initializable, UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable {
    // ─── Roles ──────────────────────────────────────────────────────────
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    // ─── Errors ─────────────────────────────────────────────────────────
    error ZeroAddress();
    error InvalidRound();
    error RequestAlreadyPending();
    error UnauthorizedCallback();
    error RandomnessNotFulfilled();
    error DrawAlreadyFinalized();
    error ExistingRandomnessRequest();
    error DrawNotReady();
    error RequestWindowExpired();
    error NoExistingRandomnessRequest();
    error NonEmptyRound();
    error RandomnessAlreadyFulfilled();
    error InvalidResponseTimeout();
    error ResponseDeadlineNotReached(uint256 responseDeadline);
    error ActiveRequests();

    // ─── Structs ────────────────────────────────────────────────────────
    struct VRFConfig {
        address vrfCoordinator;
        bytes32 keyHash;
        uint256 subscriptionId;
        uint16 requestConfirmations;
        uint32 callbackGasLimit;
    }

    struct PendingRequest {
        uint256 roundId;
        bool exists;
    }

    // ─── State ──────────────────────────────────────────────────────────
    ILotto7Game public game;
    VRFConfig public vrfConfig;

    mapping(uint256 requestId => PendingRequest) public pendingRequests;
    mapping(uint256 roundId => bool) public roundRequested;
    /// @dev UUPS storage：追加请求时间与 requestId，供监控和事故排查，不允许据此重抽。
    mapping(uint256 roundId => uint256 timestamp) public requestedAt;
    mapping(uint256 roundId => uint256 requestId) public requestIdByRound;
    mapping(uint256 roundId => bool fulfilled) public randomnessFulfilled;
    mapping(uint256 roundId => uint32 winningNumber) public storedWinningNumber;
    mapping(uint256 roundId => bool finalized) public drawFinalized;
    /// @dev 必须追加在已有状态之后以保持 UUPS 存储布局。旧代理升级后该值为 0，
    ///      `effectiveEmptyRoundResponseTimeout` 会使用 20 分钟安全默认值。
    uint64 public emptyRoundResponseTimeout;
    uint256 public pendingRequestCount;
    mapping(uint256 requestId => address coordinator) public requestCoordinator;

    uint64 public constant DEFAULT_EMPTY_ROUND_RESPONSE_TIMEOUT = 20 minutes;
    uint64 public constant MIN_EMPTY_ROUND_RESPONSE_TIMEOUT = 5 minutes;
    uint64 public constant MAX_EMPTY_ROUND_RESPONSE_TIMEOUT = 1 days;

    // ─── Events ─────────────────────────────────────────────────────────
    event DrawRequested(uint256 indexed roundId, uint256 indexed requestId);
    event RandomnessStored(uint256 indexed roundId, uint256 indexed requestId, uint32 winningNumber);
    event DrawFinalized(uint256 indexed roundId, uint32 winningNumber);
    event UnknownFulfillmentIgnored(uint256 indexed requestId);
    event InvalidFulfillmentIgnored(uint256 indexed requestId);
    event TimedOutRoundCancelled(uint256 indexed roundId);
    event EmptyRequestedRoundCancelled(uint256 indexed roundId, uint256 indexed requestId);
    event RequestedRoundCancelledAfterVrfTimeout(
        uint256 indexed roundId, uint256 indexed requestId, uint256 responseDeadline
    );
    event CancelledRoundFulfillmentIgnored(uint256 indexed roundId, uint256 indexed requestId);
    event VRFConfigUpdated(address vrfCoordinator, bytes32 keyHash, uint256 subscriptionId);
    event EmptyRoundResponseTimeoutUpdated(uint64 timeoutSeconds);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin_, ILotto7Game game_, VRFConfig calldata vrfConfig_) public initializer {
        if (admin_ == address(0) || address(game_) == address(0) || vrfConfig_.vrfCoordinator == address(0)) {
            revert ZeroAddress();
        }

        __AccessControl_init();
        __Pausable_init();

        game = game_;
        vrfConfig = vrfConfig_;
        emptyRoundResponseTimeout = DEFAULT_EMPTY_ROUND_RESPONSE_TIMEOUT;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
    }

    // ─── Request Draw ───────────────────────────────────────────────────

    function requestDraw(uint256 roundId) external onlyRole(KEEPER_ROLE) whenNotPaused returns (uint256 requestId) {
        if (roundId == 0) revert InvalidRound();
        if (roundRequested[roundId]) revert RequestAlreadyPending();

        ILotto7Game.Round memory round = game.getRound(roundId);
        if (
            (round.status != ILotto7Game.RoundStatus.Open && round.status != ILotto7Game.RoundStatus.BetClosed)
                || block.timestamp < round.betCloseTime
        ) revert DrawNotReady();
        if (block.timestamp >= round.endTime) revert RequestWindowExpired();

        roundRequested[roundId] = true;
        requestId = _requestRandomWords();

        requestedAt[roundId] = block.timestamp;
        requestIdByRound[roundId] = requestId;
        pendingRequests[requestId] = PendingRequest({roundId: roundId, exists: true});
        requestCoordinator[requestId] = vrfConfig.vrfCoordinator;
        pendingRequestCount++;

        emit DrawRequested(roundId, requestId);
    }

    // ─── VRF Callback ───────────────────────────────────────────────────

    function rawFulfillRandomWords(uint256 requestId, uint256[] memory randomWords) external {
        address expectedCoordinator = requestCoordinator[requestId];
        if (expectedCoordinator == address(0)) expectedCoordinator = vrfConfig.vrfCoordinator;
        if (msg.sender != expectedCoordinator) revert UnauthorizedCallback();

        PendingRequest storage req = pendingRequests[requestId];
        // Chainlink 明确要求 fulfillment 不能 revert。未知/重复回调只记录并返回，
        // 避免 Coordinator 永久放弃该次 fulfillment。
        if (!req.exists) {
            emit UnknownFulfillmentIgnored(requestId);
            return;
        }
        if (randomWords.length == 0) {
            emit InvalidFulfillmentIgnored(requestId);
            return;
        }

        uint256 roundId = req.roundId;
        delete pendingRequests[requestId];
        if (pendingRequestCount > 0) pendingRequestCount--;
        if (drawFinalized[roundId]) {
            emit CancelledRoundFulfillmentIgnored(roundId, requestId);
            return;
        }
        uint32 winningNumber = uint32(randomWords[0] % 10_000_000);
        randomnessFulfilled[roundId] = true;
        storedWinningNumber[roundId] = winningNumber;

        emit RandomnessStored(roundId, requestId, winningNumber);
    }

    /// @notice 使用已经由 Coordinator 写入的唯一随机数结算。任何人可调用，若 Game/Treasury
    ///         临时暂停或结算依赖失败，整笔交易回滚，稍后可使用同一 winningNumber 重试。
    function finalizeDraw(uint256 roundId) external whenNotPaused {
        if (!randomnessFulfilled[roundId]) revert RandomnessNotFulfilled();
        if (drawFinalized[roundId]) revert DrawAlreadyFinalized();

        uint32 winningNumber = storedWinningNumber[roundId];
        drawFinalized[roundId] = true;
        game.settleDraw(roundId, winningNumber);

        emit DrawFinalized(roundId, winningNumber);
    }

    /// @notice 只有从未生成 VRF requestId 的轮次才能在 endTime 后取消退款。已请求轮次即使
    ///         callback 很慢也不能取消或重抽，防止任何人丢弃不利随机数。
    function cancelUnrequestedTimedOutRound(uint256 roundId) external {
        if (roundRequested[roundId]) revert ExistingRandomnessRequest();
        game.cancelTimedOutRound(roundId);
        emit TimedOutRoundCancelled(roundId);
    }

    /// @notice A requested round may only time out into cancellation and full
    ///         refunds. It can never request replacement randomness. The fixed,
    ///         public deadline prevents an operator from choosing among random
    ///         outcomes; a late callback is ignored after cancellation.
    function cancelRequestedTimedOutRound(uint256 roundId) public {
        if (!roundRequested[roundId]) revert NoExistingRandomnessRequest();
        if (randomnessFulfilled[roundId]) revert RandomnessAlreadyFulfilled();

        uint256 responseDeadline = requestedAt[roundId] + effectiveEmptyRoundResponseTimeout();
        if (block.timestamp < responseDeadline) revert ResponseDeadlineNotReached(responseDeadline);

        drawFinalized[roundId] = true;
        uint256 requestId = requestIdByRound[roundId];
        if (pendingRequests[requestId].exists) {
            delete pendingRequests[requestId];
            if (pendingRequestCount > 0) pendingRequestCount--;
        }
        game.cancelTimedOutRound(roundId);
        emit RequestedRoundCancelledAfterVrfTimeout(roundId, requestIdByRound[roundId], responseDeadline);
    }

    /// @notice Backwards-compatible alias retained for existing automation.
    function cancelEmptyRequestedTimedOutRound(uint256 roundId) external {
        cancelRequestedTimedOutRound(roundId);
        emit EmptyRequestedRoundCancelled(roundId, requestIdByRound[roundId]);
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function setVRFConfig(VRFConfig calldata vrfConfig_) external onlyRole(ADMIN_ROLE) {
        if (vrfConfig_.vrfCoordinator == address(0)) revert ZeroAddress();
        if (pendingRequestCount != 0) revert ActiveRequests();
        vrfConfig = vrfConfig_;
        emit VRFConfigUpdated(vrfConfig_.vrfCoordinator, vrfConfig_.keyHash, vrfConfig_.subscriptionId);
    }

    function setEmptyRoundResponseTimeout(uint64 timeoutSeconds) external onlyRole(ADMIN_ROLE) {
        if (pendingRequestCount != 0) revert ActiveRequests();
        if (timeoutSeconds < MIN_EMPTY_ROUND_RESPONSE_TIMEOUT || timeoutSeconds > MAX_EMPTY_ROUND_RESPONSE_TIMEOUT) {
            revert InvalidResponseTimeout();
        }
        emptyRoundResponseTimeout = timeoutSeconds;
        emit EmptyRoundResponseTimeoutUpdated(timeoutSeconds);
    }

    /// @notice 兼容已经部署的 UUPS proxy：新增槽位初始值为 0 时仍返回安全默认值。
    function effectiveEmptyRoundResponseTimeout() public view returns (uint256) {
        uint64 configured = emptyRoundResponseTimeout;
        return configured == 0 ? DEFAULT_EMPTY_ROUND_RESPONSE_TIMEOUT : configured;
    }

    function setGame(ILotto7Game game_) external onlyRole(ADMIN_ROLE) {
        if (address(game_) == address(0)) revert ZeroAddress();
        if (pendingRequestCount != 0) revert ActiveRequests();
        game = game_;
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function _authorizeUpgrade(address) internal override onlyRole(ADMIN_ROLE) {}

    // ─── Internal VRF ───────────────────────────────────────────────────

    function _requestRandomWords() internal returns (uint256 requestId) {
        bytes4 extraArgsV1Tag = bytes4(keccak256("VRF ExtraArgsV1"));
        IVRFCoordinatorV2Plus.RandomWordsRequest memory req = IVRFCoordinatorV2Plus.RandomWordsRequest({
            keyHash: vrfConfig.keyHash,
            subId: vrfConfig.subscriptionId,
            requestConfirmations: vrfConfig.requestConfirmations,
            callbackGasLimit: vrfConfig.callbackGasLimit,
            numWords: 1,
            // Subscription 使用原生 POL 注资，因此必须显式选择 native payment。
            // 空 bytes 会被 Coordinator 解释为 nativePayment=false（LINK 付款）。
            extraArgs: abi.encodeWithSelector(extraArgsV1Tag, true)
        });
        requestId = IVRFCoordinatorV2Plus(vrfConfig.vrfCoordinator).requestRandomWords(req);
    }
}
