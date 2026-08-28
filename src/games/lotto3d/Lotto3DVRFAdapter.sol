// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {ILotto3DGame} from "./interfaces/ILotto3DGame.sol";
import {IVRFCoordinatorV2Plus} from "./interfaces/IVRFCoordinatorV2.sol";

/// @title Lotto3DVRFAdapter
/// @notice Chainlink VRF v2+ integration for 3D lottery draw.
contract Lotto3DVRFAdapter is Initializable, UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable {
    // --- Roles ----------------------------------------------------------
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    // --- Errors ---------------------------------------------------------
    error ZeroAddress();
    error InvalidRound();
    error RequestAlreadyPending();
    error RequestNotFound();
    error UnauthorizedCallback();
    error VRFRequestFailed();
    error DrawNotReady();
    error RequestWindowExpired();
    error RandomnessNotFulfilled();
    error DrawAlreadyFinalized();
    error ActiveRequests();
    error ResponseDeadlineNotReached(uint256 responseDeadline);
    error InvalidResponseTimeout();

    // --- Structs --------------------------------------------------------
    struct VRFConfig {
        address vrfCoordinator;
        bytes32 keyHash;
        uint256 subscriptionId;
        uint16 requestConfirmations;
        uint32 callbackGasLimit;
    }

    struct PendingRequest {
        uint40 roundId;
        bool exists;
    }

    // --- State ----------------------------------------------------------
    ILotto3DGame public game;
    VRFConfig public vrfConfig;

    mapping(uint256 requestId => PendingRequest) public pendingRequests;
    mapping(uint40 roundId => bool) public roundRequested;
    mapping(uint40 roundId => uint256 requestId) public requestIdByRound;
    mapping(uint40 roundId => bool fulfilled) public randomnessFulfilled;
    mapping(uint40 roundId => uint16 winningNumber) public storedWinningNumber;
    mapping(uint40 roundId => bool finalized) public drawFinalized;
    uint256 public pendingRequestCount;
    mapping(uint40 roundId => uint64 requestedAt) public requestedAt;
    uint64 public responseTimeout;

    uint64 public constant DEFAULT_RESPONSE_TIMEOUT = 1 hours;
    uint64 public constant MIN_RESPONSE_TIMEOUT = 15 minutes;
    uint64 public constant MAX_RESPONSE_TIMEOUT = 1 days;

    // --- Events ---------------------------------------------------------
    event DrawRequested(uint40 indexed roundId, uint256 indexed requestId);
    event DrawFulfilled(uint40 indexed roundId, uint256 indexed requestId, uint16 winningNumber);
    event RandomnessStored(uint40 indexed roundId, uint256 indexed requestId, uint16 winningNumber);
    event DrawFinalized(uint40 indexed roundId, uint16 winningNumber);
    event UnknownFulfillmentIgnored(uint256 indexed requestId);
    event InvalidFulfillmentIgnored(uint256 indexed requestId);
    event TimedOutRequestCancelled(uint40 indexed roundId, uint256 indexed requestId, uint256 responseDeadline);
    event ResponseTimeoutUpdated(uint64 timeoutSeconds);
    event VRFConfigUpdated(address vrfCoordinator, bytes32 keyHash, uint256 subscriptionId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin_, ILotto3DGame game_, VRFConfig calldata vrfConfig_) public initializer {
        if (admin_ == address(0) || address(game_) == address(0) || vrfConfig_.vrfCoordinator == address(0)) {
            revert ZeroAddress();
        }

        __AccessControl_init();
        __Pausable_init();

        game = game_;
        vrfConfig = vrfConfig_;
        responseTimeout = DEFAULT_RESPONSE_TIMEOUT;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
    }

    // --- Request Draw ---------------------------------------------------

    function requestDraw(uint40 roundId) external onlyRole(KEEPER_ROLE) whenNotPaused returns (uint256 requestId) {
        if (roundId == 0) revert InvalidRound();
        if (roundRequested[roundId]) revert RequestAlreadyPending();

        ILotto3DGame.RoundData memory round = game.getRound(roundId);
        if (
            !round.exists
                || (round.status != ILotto3DGame.RoundStatus.Open
                    && round.status != ILotto3DGame.RoundStatus.SalesClosed)
                || block.timestamp <= round.config.salesCloseTime
        ) revert DrawNotReady();
        if (block.timestamp > round.config.drawDeadline) revert RequestWindowExpired();

        roundRequested[roundId] = true;
        requestId = _requestRandomWords();

        requestIdByRound[roundId] = requestId;
        requestedAt[roundId] = uint64(block.timestamp);
        pendingRequests[requestId] = PendingRequest({roundId: roundId, exists: true});
        pendingRequestCount++;

        emit DrawRequested(roundId, requestId);
    }

    // --- VRF Callback ---------------------------------------------------

    function rawFulfillRandomWords(uint256 requestId, uint256[] memory randomWords) external {
        if (msg.sender != vrfConfig.vrfCoordinator) revert UnauthorizedCallback();

        PendingRequest storage req = pendingRequests[requestId];
        if (!req.exists) {
            emit UnknownFulfillmentIgnored(requestId);
            return;
        }
        if (randomWords.length == 0) {
            emit InvalidFulfillmentIgnored(requestId);
            return;
        }

        uint40 roundId = req.roundId;
        delete pendingRequests[requestId];
        pendingRequestCount--;

        if (drawFinalized[roundId]) {
            emit UnknownFulfillmentIgnored(requestId);
            return;
        }

        uint16 winningNumber = uint16(randomWords[0] % 1000);
        randomnessFulfilled[roundId] = true;
        storedWinningNumber[roundId] = winningNumber;
        emit RandomnessStored(roundId, requestId, winningNumber);
    }

    function finalizeDraw(uint40 roundId) external whenNotPaused {
        if (!randomnessFulfilled[roundId]) revert RandomnessNotFulfilled();
        if (drawFinalized[roundId]) revert DrawAlreadyFinalized();

        uint16 winningNumber = storedWinningNumber[roundId];
        drawFinalized[roundId] = true;
        game.settleDraw(roundId, winningNumber);

        emit DrawFulfilled(roundId, requestIdByRound[roundId], winningNumber);
        emit DrawFinalized(roundId, winningNumber);
    }

    function cancelTimedOutRequest(uint40 roundId) external {
        uint256 requestId = requestIdByRound[roundId];
        PendingRequest storage request = pendingRequests[requestId];
        if (!request.exists || request.roundId != roundId) revert RequestNotFound();
        if (randomnessFulfilled[roundId]) revert DrawAlreadyFinalized();

        ILotto3DGame.RoundData memory round = game.getRound(roundId);
        uint256 requestedDeadline = uint256(requestedAt[roundId]) + effectiveResponseTimeout();
        uint256 roundDeadline = uint256(round.config.drawDeadline) + effectiveResponseTimeout();
        uint256 responseDeadline = requestedDeadline > roundDeadline ? requestedDeadline : roundDeadline;
        if (block.timestamp <= responseDeadline) revert ResponseDeadlineNotReached(responseDeadline);

        delete pendingRequests[requestId];
        if (pendingRequestCount > 0) pendingRequestCount--;
        drawFinalized[roundId] = true;
        game.cancelTimedOutRound(roundId);
        emit TimedOutRequestCancelled(roundId, requestId, responseDeadline);
    }

    // --- Admin ----------------------------------------------------------

    function setVRFConfig(VRFConfig calldata vrfConfig_) external onlyRole(ADMIN_ROLE) {
        if (vrfConfig_.vrfCoordinator == address(0)) revert ZeroAddress();
        if (pendingRequestCount != 0) revert ActiveRequests();
        vrfConfig = vrfConfig_;
        emit VRFConfigUpdated(vrfConfig_.vrfCoordinator, vrfConfig_.keyHash, vrfConfig_.subscriptionId);
    }

    function setGame(ILotto3DGame game_) external onlyRole(ADMIN_ROLE) {
        if (address(game_) == address(0)) revert ZeroAddress();
        if (pendingRequestCount != 0) revert ActiveRequests();
        game = game_;
    }

    function setResponseTimeout(uint64 timeoutSeconds) external onlyRole(ADMIN_ROLE) {
        if (pendingRequestCount != 0) revert ActiveRequests();
        if (timeoutSeconds < MIN_RESPONSE_TIMEOUT || timeoutSeconds > MAX_RESPONSE_TIMEOUT) {
            revert InvalidResponseTimeout();
        }
        responseTimeout = timeoutSeconds;
        emit ResponseTimeoutUpdated(timeoutSeconds);
    }

    function effectiveResponseTimeout() public view returns (uint64) {
        return responseTimeout == 0 ? DEFAULT_RESPONSE_TIMEOUT : responseTimeout;
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function _authorizeUpgrade(address) internal override onlyRole(ADMIN_ROLE) {}

    // --- Internal VRF ---------------------------------------------------

    function _requestRandomWords() internal returns (uint256 requestId) {
        // The subscription is funded with native POL on Polygon. An empty
        // extraArgs payload selects LINK payment in VRF v2.5, which leaves a
        // request pending when the subscription has no LINK balance.
        bytes4 extraArgsV1Tag = bytes4(keccak256("VRF ExtraArgsV1"));
        IVRFCoordinatorV2Plus.RandomWordsRequest memory req = IVRFCoordinatorV2Plus.RandomWordsRequest({
            keyHash: vrfConfig.keyHash,
            subId: vrfConfig.subscriptionId,
            requestConfirmations: vrfConfig.requestConfirmations,
            callbackGasLimit: vrfConfig.callbackGasLimit,
            numWords: 1,
            extraArgs: abi.encodeWithSelector(extraArgsV1Tag, true)
        });
        requestId = IVRFCoordinatorV2Plus(vrfConfig.vrfCoordinator).requestRandomWords(req);
    }
}
