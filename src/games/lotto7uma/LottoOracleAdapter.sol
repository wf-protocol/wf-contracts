// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {ILottoRounds} from "./interfaces/ILottoRounds.sol";
import {IOptimisticOracleV3} from "./interfaces/IOptimisticOracleV3.sol";
import {LottoPrizeMath} from "../libraries/LottoPrizeMath.sol";

/// @dev 原样移植自 smart-contract-pd-main/src/LottoOracleAdapter.sol，逻辑未作改动。
///      本合约只负责 UMA Optimistic Oracle V3 的断言/仲裁交互，不持有、不挪动任何
///      用户资金（保证金 bond 用的是独立的 `defaultCurrency`，由 depositBond 存入
///      本合约自身，与 LedgerContract 账本完全无关），因此不受本次"接入
///      LedgerContract、取代 GlobalVault"改造影响。
contract LottoOracleAdapter is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant ASSERTION_MANAGER_ROLE = keccak256("ASSERTION_MANAGER_ROLE");

    enum RequestStatus {
        None,
        Pending,
        ResolutionPending,
        Disputed,
        Abandoned,
        Resolved,
        DisputePending
    }

    struct DrawRequest {
        uint40 roundId;
        uint32 winningNumber;
        bytes32 sourceBundleHash;
        bytes32 normalizedDataHash;
        bytes32 assertionId;
        uint64 assertedAt;
        address asserter;
        bool resolvedTruthfully;
        RequestStatus status;
    }

    error ZeroAddress();
    error ZeroAmount();
    error InvalidAssertionId();
    error InvalidNumber();
    error InvalidHash();
    error InvalidSummary();
    error UnauthorizedCallbackCaller();
    error RequestNotPending();
    error ResolutionNotPending();
    error InsufficientBondBalance();
    error InsufficientUnencumberedBond();
    error RequestNotAbandonable();
    error InvalidRound();
    error ActiveBondLocks();

    IOptimisticOracleV3 public optimisticOracleV3;
    ILottoRounds public rounds;
    IERC20 public defaultCurrency;
    uint256 public defaultBond;
    uint64 public assertionLiveness;
    bytes32 public identifier;

    mapping(bytes32 assertionId => DrawRequest request) private _drawRequests;
    mapping(bytes32 assertionId => uint256 bond) private _lockedBonds;
    uint256 public lockedBond;
    mapping(bytes32 assertionId => address oracle) public assertionOracle;

    event UmaConfigUpdated(
        address indexed optimisticOracleV3,
        address indexed defaultCurrency,
        uint256 defaultBond,
        uint64 assertionLiveness,
        bytes32 identifier
    );
    event BondDeposited(address indexed from, uint256 amount);
    event BondWithdrawn(address indexed to, uint256 amount);
    event DrawAssertionRequested(
        uint40 indexed roundId,
        bytes32 indexed assertionId,
        address indexed asserter,
        uint32 winningNumber,
        bytes32 sourceBundleHash,
        bytes32 normalizedDataHash
    );
    event DrawAssertionResolved(uint40 indexed roundId, bytes32 indexed assertionId, bool assertedTruthfully);
    event DrawAssertionDisputed(uint40 indexed roundId, bytes32 indexed assertionId);
    event DrawAssertionAbandoned(uint40 indexed roundId, bytes32 indexed assertionId, address indexed caller);
    event DrawAssertionResolutionDeferred(uint40 indexed roundId, bytes32 indexed assertionId, bool assertedTruthfully);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin_,
        address assertionManager_,
        ILottoRounds rounds_,
        IOptimisticOracleV3 optimisticOracleV3_,
        IERC20 defaultCurrency_,
        uint256 defaultBond_,
        uint64 assertionLiveness_
    ) public initializer {
        if (
            admin_ == address(0) || assertionManager_ == address(0) || address(rounds_) == address(0)
                || address(optimisticOracleV3_) == address(0) || address(defaultCurrency_) == address(0)
        ) {
            revert ZeroAddress();
        }

        __AccessControl_init();
        __Pausable_init();

        rounds = rounds_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
        _grantRole(ASSERTION_MANAGER_ROLE, assertionManager_);

        _setUmaConfig(
            optimisticOracleV3_,
            defaultCurrency_,
            defaultBond_,
            assertionLiveness_,
            optimisticOracleV3_.defaultIdentifier()
        );
    }

    function assertDraw(
        uint40 roundId,
        uint32 winningNumber,
        bytes32 sourceBundleHash,
        bytes32 normalizedDataHash,
        string calldata normalizedDataUriOrSummary
    ) external onlyRole(ASSERTION_MANAGER_ROLE) whenNotPaused returns (bytes32 assertionId) {
        if (!LottoPrizeMath.isValidNumber(winningNumber)) {
            revert InvalidNumber();
        }
        if (sourceBundleHash == bytes32(0) || normalizedDataHash == bytes32(0)) {
            revert InvalidHash();
        }
        if (bytes(normalizedDataUriOrSummary).length == 0) {
            revert InvalidSummary();
        }
        uint256 assertionBond = requiredBond();
        // UMA escrows the bond out of this contract during assertTruth, so the
        // current token balance is already the unencumbered balance.
        if (defaultCurrency.balanceOf(address(this)) < assertionBond) {
            revert InsufficientBondBalance();
        }

        string memory claim =
            buildClaim(roundId, winningNumber, sourceBundleHash, normalizedDataHash, normalizedDataUriOrSummary);

        ILottoRounds.RoundData memory roundData = rounds.getRound(roundId);
        if (!roundData.exists) {
            revert InvalidRound();
        }

        assertionId = optimisticOracleV3.assertTruth(
            bytes(claim),
            address(this),
            address(this),
            address(0),
            roundData.config.assertionLiveness,
            defaultCurrency,
            assertionBond,
            identifier,
            bytes32(0)
        );

        _drawRequests[assertionId] = DrawRequest({
            roundId: roundId,
            winningNumber: winningNumber,
            sourceBundleHash: sourceBundleHash,
            normalizedDataHash: normalizedDataHash,
            assertionId: assertionId,
            assertedAt: uint64(block.timestamp),
            asserter: msg.sender,
            resolvedTruthfully: false,
            status: RequestStatus.Pending
        });
        _lockedBonds[assertionId] = assertionBond;
        assertionOracle[assertionId] = address(optimisticOracleV3);
        lockedBond += assertionBond;

        rounds.markDrawAssertionPending(roundId, assertionId, sourceBundleHash, winningNumber, normalizedDataHash);

        emit DrawAssertionRequested(
            roundId, assertionId, msg.sender, winningNumber, sourceBundleHash, normalizedDataHash
        );
    }

    function settleAssertion(bytes32 assertionId) external whenNotPaused returns (bool) {
        if (assertionId == bytes32(0)) {
            revert InvalidAssertionId();
        }
        address oracle = assertionOracle[assertionId];
        if (oracle == address(0)) revert InvalidAssertionId();
        return IOptimisticOracleV3(oracle).settleAndGetAssertionResult(assertionId);
    }

    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external {
        if (msg.sender != assertionOracle[assertionId]) {
            revert UnauthorizedCallbackCaller();
        }

        DrawRequest storage request = _drawRequests[assertionId];
        if (request.status == RequestStatus.Abandoned) {
            request.resolvedTruthfully = assertedTruthfully;
            _releaseBondLock(assertionId);
            return;
        }
        if (
            request.status != RequestStatus.Pending && request.status != RequestStatus.ResolutionPending
                && request.status != RequestStatus.DisputePending
        ) {
            return;
        }
        request.resolvedTruthfully = assertedTruthfully;
        _attemptFinalize(assertionId, request);
    }

    function assertionDisputedCallback(bytes32 assertionId) external {
        if (msg.sender != assertionOracle[assertionId]) {
            revert UnauthorizedCallbackCaller();
        }

        DrawRequest storage request = _drawRequests[assertionId];
        if (request.status != RequestStatus.Pending) {
            return;
        }

        request.status = RequestStatus.DisputePending;
        emit DrawAssertionDisputed(request.roundId, assertionId);
    }

    function finalizeAssertionOutcome(bytes32 assertionId) external whenNotPaused {
        DrawRequest storage request = _drawRequests[assertionId];
        if (request.status != RequestStatus.ResolutionPending) {
            revert ResolutionNotPending();
        }
        _attemptFinalize(assertionId, request);
    }

    function abandonAssertion(bytes32 assertionId) external onlyRole(ADMIN_ROLE) whenNotPaused {
        DrawRequest storage request = _drawRequests[assertionId];
        ILottoRounds.RoundData memory roundData = rounds.getRound(request.roundId);
        if (
            (request.status != RequestStatus.Pending
                    && request.status != RequestStatus.ResolutionPending
                    && request.status != RequestStatus.DisputePending) || !roundData.cancelled
        ) {
            revert RequestNotAbandonable();
        }

        request.status = RequestStatus.Abandoned;
        request.resolvedTruthfully = false;
        _releaseBondLock(assertionId);

        emit DrawAssertionAbandoned(request.roundId, assertionId, msg.sender);
    }

    function setUmaConfig(
        IOptimisticOracleV3 optimisticOracleV3_,
        IERC20 defaultCurrency_,
        uint256 defaultBond_,
        uint64 assertionLiveness_,
        bytes32 identifier_
    ) external onlyRole(ADMIN_ROLE) {
        if (lockedBond != 0) revert ActiveBondLocks();
        _setUmaConfig(optimisticOracleV3_, defaultCurrency_, defaultBond_, assertionLiveness_, identifier_);
    }

    function depositBond(uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) {
            revert ZeroAmount();
        }
        defaultCurrency.safeTransferFrom(msg.sender, address(this), amount);
        emit BondDeposited(msg.sender, amount);
    }

    function withdrawBond(address to, uint256 amount) external onlyRole(ADMIN_ROLE) whenNotPaused nonReentrant {
        if (to == address(0)) {
            revert ZeroAddress();
        }
        if (amount == 0) {
            revert ZeroAmount();
        }
        uint256 balance = defaultCurrency.balanceOf(address(this));
        if (lockedBond > balance || amount > balance - lockedBond) {
            revert InsufficientUnencumberedBond();
        }
        defaultCurrency.safeTransfer(to, amount);
        emit BondWithdrawn(to, amount);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function _authorizeUpgrade(address) internal override onlyRole(ADMIN_ROLE) {}

    function getDrawRequest(bytes32 assertionId) external view returns (DrawRequest memory) {
        return _drawRequests[assertionId];
    }

    function lockedBondFor(bytes32 assertionId) external view returns (uint256) {
        return _lockedBonds[assertionId];
    }

    function minimumBond() public view returns (uint256) {
        return optimisticOracleV3.getMinimumBond(defaultCurrency);
    }

    function requiredBond() public view returns (uint256) {
        uint256 protocolMinimum = minimumBond();
        return defaultBond > protocolMinimum ? defaultBond : protocolMinimum;
    }

    function availableBond() external view returns (uint256) {
        return defaultCurrency.balanceOf(address(this));
    }

    function getRoundDrawStatus(uint40 roundId) external view returns (ILottoRounds.DrawStatus) {
        return rounds.roundDrawStatus(roundId);
    }

    function buildClaim(
        uint40 roundId,
        uint32 winningNumber,
        bytes32 sourceBundleHash,
        bytes32 normalizedDataHash,
        string memory normalizedDataUriOrSummary
    ) public pure returns (string memory) {
        if (!LottoPrizeMath.isValidNumber(winningNumber)) {
            revert InvalidNumber();
        }

        return string.concat(
            "Lotto round ",
            Strings.toString(roundId),
            " should resolve to winning number ",
            _formatWinningNumber(winningNumber),
            ". Normalized source records used for this assertion: ",
            normalizedDataUriOrSummary,
            ". sourceBundleHash=",
            Strings.toHexString(uint256(sourceBundleHash), 32),
            ". normalizedDataHash=",
            Strings.toHexString(uint256(normalizedDataHash), 32)
        );
    }

    function _setUmaConfig(
        IOptimisticOracleV3 optimisticOracleV3_,
        IERC20 defaultCurrency_,
        uint256 defaultBond_,
        uint64 assertionLiveness_,
        bytes32 identifier_
    ) internal {
        if (address(optimisticOracleV3_) == address(0) || address(defaultCurrency_) == address(0)) {
            revert ZeroAddress();
        }

        if (
            address(optimisticOracleV3) != address(0)
                && (address(optimisticOracleV3) != address(optimisticOracleV3_)
                    || address(defaultCurrency) != address(defaultCurrency_))
        ) {
            defaultCurrency.forceApprove(address(optimisticOracleV3), 0);
        }

        optimisticOracleV3 = optimisticOracleV3_;
        defaultCurrency = defaultCurrency_;
        defaultBond = defaultBond_;
        assertionLiveness = assertionLiveness_;
        identifier = identifier_;

        defaultCurrency_.forceApprove(address(optimisticOracleV3_), type(uint256).max);

        emit UmaConfigUpdated(
            address(optimisticOracleV3_), address(defaultCurrency_), defaultBond_, assertionLiveness_, identifier_
        );
    }

    function _attemptFinalize(bytes32 assertionId, DrawRequest storage request) internal {
        if (request.resolvedTruthfully) {
            request.status = RequestStatus.Resolved;
            try rounds.submitDraw(request.roundId, request.winningNumber, request.sourceBundleHash) {
                _releaseBondLock(assertionId);
                emit DrawAssertionResolved(request.roundId, assertionId, true);
            } catch {
                request.status = RequestStatus.ResolutionPending;
                emit DrawAssertionResolutionDeferred(request.roundId, assertionId, true);
            }
            return;
        }

        request.status = RequestStatus.Disputed;
        try rounds.markDrawAssertionDisputed(request.roundId, assertionId) {
            _releaseBondLock(assertionId);
            emit DrawAssertionDisputed(request.roundId, assertionId);
        } catch {
            request.status = RequestStatus.ResolutionPending;
            emit DrawAssertionResolutionDeferred(request.roundId, assertionId, false);
        }
    }

    function _formatWinningNumber(uint32 winningNumber) internal pure returns (string memory) {
        bytes memory output = new bytes(7);
        uint32 remaining = winningNumber;
        for (uint256 i = 0; i < 7; ++i) {
            output[6 - i] = bytes1(uint8(48 + (remaining % 10)));
            remaining /= 10;
        }
        return string(output);
    }

    function _releaseBondLock(bytes32 assertionId) internal {
        uint256 bond = _lockedBonds[assertionId];
        if (bond == 0) return;
        _lockedBonds[assertionId] = 0;
        lockedBond = lockedBond >= bond ? lockedBond - bond : 0;
    }
}
