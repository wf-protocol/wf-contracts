// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {IProtocolFundingReceiver} from "../protocol/IProtocolFundingReceiver.sol";
import {IUnifiedLedgerV4} from "./IUnifiedLedgerV4.sol";
import {IGameRegistry} from "../protocol/IGameRegistry.sol";
import {IGameModuleV4} from "../protocol/IGameModuleV4.sol";

/// @title UnifiedLedgerV4
/// @notice Purchase entry point that binds channel attribution to the Treasury's round allocation snapshot.
/// @dev Fresh deployment only. Storage is NOT compatible with previous Ledgers.
contract UnifiedLedgerV4 is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    EIP712Upgradeable,
    IUnifiedLedgerV4
{
    bytes32 public constant RESERVE_ROLE = keccak256("RESERVE_ROLE");
    bytes32 public constant PROTOCOL_ACCOUNT_ROLE = keccak256("PROTOCOL_ACCOUNT_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    uint8 public constant WUSD_DECIMALS = 6;
    IGameRegistry public override gameRegistry;
    mapping(address account => uint256 amount) private _balances;
    uint256 public override totalWusdLiability;
    mapping(address owner => uint256 nonce) public override purchaseNonces;

    event ReserveCredit(address indexed reserve, address indexed account, uint256 amount, uint256 newBalance);
    event ReserveDebit(address indexed reserve, address indexed account, uint256 amount, uint256 newBalance);
    event BalanceTransferred(address indexed from, address indexed to, uint256 amount);
    event ProtocolAccountFunded(address indexed funder, address indexed account, uint256 amount);
    event PurchaseNonceInvalidated(address indexed owner, uint256 previousNonce, uint256 newNonce);

    error ZeroAddress();
    error ZeroAmount();
    error InvalidRegistry();
    error InsufficientBalance();
    error InvalidTransfer();
    error InvalidPurchase();
    error PurchaseExpired();
    error InvalidPurchaseNonce();
    error InvalidPurchaseSignature();
    error GameNotActive();
    error PurchaseDataHashMismatch();
    error NotProtocolAccount();
    bytes32 public constant PURCHASE_REQUEST_V4_TYPEHASH = keccak256(
        "PurchaseRequestV4(address owner,address game,address beneficiary,uint256 amount,bytes32 purchaseDataHash,bytes32 wfOrderId,bytes32 partnerCode,uint256 nonce,uint48 deadline)"
    );

    mapping(bytes32 wfOrderId => bool used) public override usedWfOrderIds;

    event PurchaseExecutedV4(
        bytes32 indexed receiptId,
        address indexed owner,
        address indexed game,
        address beneficiary,
        address treasury,
        uint256 amount,
        bytes32 purchaseDataHash,
        bytes32 wfOrderId,
        bytes32 partnerCode,
        uint32 allocationVersion,
        uint16 partnerBps,
        uint256 nonce,
        address submitter
    );

    error InvalidAttribution();
    error WfOrderAlreadyUsed();

    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, IGameRegistry registry_) external initializer {
        if (admin == address(0)) revert ZeroAddress();
        if (address(registry_).code.length == 0) revert InvalidRegistry();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __EIP712_init("UnifiedLedger", "4");
        gameRegistry = registry_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function domainSeparatorV4() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function creditFromReserve(address account, uint256 amount)
        external
        override
        onlyRole(RESERVE_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (account == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        totalWusdLiability += amount;
        _balances[account] += amount;
        emit ReserveCredit(msg.sender, account, amount, _balances[account]);
    }

    /// @notice Withdrawals remain possible while purchases and deposits are paused.
    function debitToReserve(address account, uint256 amount) external override onlyRole(RESERVE_ROLE) nonReentrant {
        if (account == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (_balances[account] < amount) revert InsufficientBalance();
        _balances[account] -= amount;
        totalWusdLiability -= amount;
        emit ReserveDebit(msg.sender, account, amount, _balances[account]);
    }

    /// @notice Approved protocol accounts can spend only their own balance.
    function protocolTransfer(address recipient, uint256 amount)
        external
        override
        onlyRole(PROTOCOL_ACCOUNT_ROLE)
        whenNotPaused
        nonReentrant
    {
        _moveBalance(msg.sender, recipient, amount);
    }

    function fundProtocolAccount(address account, uint256 amount, bytes calldata data)
        external
        override
        whenNotPaused
        nonReentrant
    {
        if (!hasRole(PROTOCOL_ACCOUNT_ROLE, account) || account.code.length == 0) {
            revert NotProtocolAccount();
        }
        _moveBalance(msg.sender, account, amount);
        IProtocolFundingReceiver(account).onProtocolFunding(msg.sender, amount, data);
        emit ProtocolAccountFunded(msg.sender, account, amount);
    }

    function invalidatePurchaseNonce(uint256 newNonce) external override {
        uint256 previous = purchaseNonces[msg.sender];
        if (newNonce <= previous) revert InvalidPurchaseNonce();
        purchaseNonces[msg.sender] = newNonce;
        emit PurchaseNonceInvalidated(msg.sender, previous, newNonce);
    }

    function _moveBalance(address from, address to, uint256 amount) internal {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        if (from == to) revert InvalidTransfer();
        if (amount == 0) revert ZeroAmount();
        if (_balances[from] < amount) revert InsufficientBalance();
        _balances[from] -= amount;
        _balances[to] += amount;
        emit BalanceTransferred(from, to, amount);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    function hashPurchaseAuthorizationV4(PurchaseRequestV4 calldata request) external view override returns (bytes32) {
        return _hashPurchaseAuthorizationV4(request);
    }

    function executePurchaseV4(PurchaseRequestV4 calldata request, bytes calldata purchaseData)
        external
        override
        whenNotPaused
        nonReentrant
        returns (bytes32 receiptId)
    {
        if (request.owner != msg.sender) revert InvalidPurchase();
        return _executePurchaseV4(request, purchaseData);
    }

    function executePurchaseWithAuthorizationV4(
        PurchaseRequestV4 calldata request,
        bytes calldata purchaseData,
        bytes calldata signature
    ) external override whenNotPaused nonReentrant returns (bytes32 receiptId) {
        if (request.owner == address(0)) revert InvalidPurchase();
        bytes32 digest = _hashPurchaseAuthorizationV4(request);
        if (!SignatureChecker.isValidSignatureNow(request.owner, digest, signature)) {
            revert InvalidPurchaseSignature();
        }
        return _executePurchaseV4(request, purchaseData);
    }

    function _executePurchaseV4(PurchaseRequestV4 calldata request, bytes calldata purchaseData)
        internal
        returns (bytes32 receiptId)
    {
        if (
            request.owner == address(0) || request.game == address(0) || request.beneficiary == address(0)
                || request.amount == 0
        ) revert InvalidPurchase();
        if (block.timestamp > request.deadline) revert PurchaseExpired();
        if (request.purchaseDataHash != keccak256(purchaseData)) revert PurchaseDataHashMismatch();
        bool hasOrderId = request.wfOrderId != bytes32(0);
        if (hasOrderId != (request.partnerCode != bytes32(0))) revert InvalidAttribution();
        if (hasOrderId && usedWfOrderIds[request.wfOrderId]) revert WfOrderAlreadyUsed();

        uint256 currentNonce = purchaseNonces[request.owner];
        if (request.nonce != currentNonce) revert InvalidPurchaseNonce();

        IGameRegistry.GameConfig memory config = gameRegistry.getGameConfig(request.game);
        if (config.status != IGameRegistry.GameStatus.Active || config.treasury == address(0)) revert GameNotActive();

        purchaseNonces[request.owner] = currentNonce + 1;
        if (hasOrderId) usedWfOrderIds[request.wfOrderId] = true;
        _moveBalance(request.owner, config.treasury, request.amount);

        IGameModuleV4.PurchaseContext memory context =
            IGameModuleV4.PurchaseContext({wfOrderId: request.wfOrderId, partnerCode: request.partnerCode});
        uint32 allocationVersion;
        uint16 partnerBps;
        (receiptId, allocationVersion, partnerBps) = IGameModuleV4(request.game)
            .purchaseFromLedgerV4(request.owner, request.beneficiary, request.amount, context, purchaseData);

        emit PurchaseExecutedV4(
            receiptId,
            request.owner,
            request.game,
            request.beneficiary,
            config.treasury,
            request.amount,
            request.purchaseDataHash,
            request.wfOrderId,
            request.partnerCode,
            allocationVersion,
            partnerBps,
            currentNonce,
            msg.sender
        );
    }

    function _hashPurchaseAuthorizationV4(PurchaseRequestV4 calldata request) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                PURCHASE_REQUEST_V4_TYPEHASH,
                request.owner,
                request.game,
                request.beneficiary,
                request.amount,
                request.purchaseDataHash,
                request.wfOrderId,
                request.partnerCode,
                request.nonce,
                request.deadline
            )
        );
        return _hashTypedDataV4(structHash);
    }
}
