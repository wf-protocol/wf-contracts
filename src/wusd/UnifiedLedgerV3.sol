// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {UnifiedLedgerV2} from "./UnifiedLedgerV2.sol";
import {IUnifiedLedgerV2} from "./IUnifiedLedgerV2.sol";
import {IUnifiedLedgerV3} from "./IUnifiedLedgerV3.sol";
import {IGameRegistry} from "../protocol/IGameRegistry.sol";
import {IGameModuleV3} from "../protocol/IGameModuleV3.sol";

/// @title UnifiedLedgerV3
/// @notice Open purchase entry point for direct wallets, smart accounts, and signed relayers.
contract UnifiedLedgerV3 is UnifiedLedgerV2, EIP712Upgradeable, IUnifiedLedgerV3 {
    bytes32 public constant PURCHASE_REQUEST_TYPEHASH = keccak256(
        "PurchaseRequest(address owner,address game,address beneficiary,uint256 amount,bytes32 purchaseDataHash,uint256 nonce,uint48 deadline)"
    );

    IGameRegistry public override gameRegistry;
    mapping(address owner => uint256 nonce) public override purchaseNonces;
    bool public legacyDirectTransfersDisabled;

    event GameRegistryUpdated(address indexed previousRegistry, address indexed newRegistry);
    event PurchaseExecuted(
        address indexed owner,
        address indexed beneficiary,
        address indexed game,
        address treasury,
        uint256 amount,
        uint256 nonce,
        bytes32 purchaseDataHash,
        bytes32 receiptId,
        address submitter
    );
    event PurchaseNonceInvalidated(address indexed owner, uint256 previousNonce, uint256 newNonce);
    event TreasuryTransfer(address indexed treasury, address indexed game, address indexed recipient, uint256 amount);
    event LegacyDirectTransfersPermanentlyDisabled();

    error InvalidRegistry();
    error InvalidPurchase();
    error PurchaseExpired();
    error InvalidPurchaseNonce();
    error InvalidPurchaseSignature();
    error GameNotActive();
    error PurchaseDataHashMismatch();
    error LegacyDirectTransfersAreDisabled();
    error UnregisteredTreasury();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initializeV3(IGameRegistry registry_) external reinitializer(3) onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(registry_) == address(0) || address(registry_).code.length == 0) revert InvalidRegistry();
        __EIP712_init("UnifiedLedger", "3");
        gameRegistry = registry_;
        emit GameRegistryUpdated(address(0), address(registry_));
    }

    function setGameRegistry(IGameRegistry registry_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(registry_) == address(0) || address(registry_).code.length == 0) revert InvalidRegistry();
        address previousRegistry = address(gameRegistry);
        gameRegistry = registry_;
        emit GameRegistryUpdated(previousRegistry, address(registry_));
    }

    function domainSeparatorV4() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function hashPurchaseAuthorization(address owner, PurchaseRequest calldata request)
        external
        view
        returns (bytes32)
    {
        return _hashPurchaseAuthorization(owner, request);
    }

    function executePurchase(PurchaseRequest calldata request, bytes calldata purchaseData)
        external
        override
        whenNotPaused
        nonReentrant
        returns (bytes32 receiptId)
    {
        return _executePurchase(msg.sender, request, purchaseData);
    }

    function executePurchaseWithAuthorization(
        address owner,
        PurchaseRequest calldata request,
        bytes calldata purchaseData,
        bytes calldata signature
    ) external override whenNotPaused nonReentrant returns (bytes32 receiptId) {
        if (owner == address(0)) revert InvalidPurchase();
        bytes32 digest = _hashPurchaseAuthorization(owner, request);
        if (!SignatureChecker.isValidSignatureNow(owner, digest, signature)) revert InvalidPurchaseSignature();
        return _executePurchase(owner, request, purchaseData);
    }

    function _executePurchase(address owner, PurchaseRequest calldata request, bytes calldata purchaseData)
        internal
        returns (bytes32 receiptId)
    {
        if (
            owner == address(0) || request.game == address(0) || request.beneficiary == address(0)
                || request.amount == 0
        ) revert InvalidPurchase();
        if (block.timestamp > request.deadline) revert PurchaseExpired();
        if (request.purchaseDataHash != keccak256(purchaseData)) revert PurchaseDataHashMismatch();

        uint256 currentNonce = purchaseNonces[owner];
        if (request.nonce != currentNonce) revert InvalidPurchaseNonce();

        IGameRegistry.GameConfig memory config = gameRegistry.getGameConfig(request.game);
        if (config.status != IGameRegistry.GameStatus.Active || config.treasury == address(0)) revert GameNotActive();

        purchaseNonces[owner] = currentNonce + 1;
        _moveBalance(address(this), owner, config.treasury, request.amount);

        receiptId =
            IGameModuleV3(request.game).purchaseFromLedger(owner, request.beneficiary, request.amount, purchaseData);

        emit PurchaseExecuted(
            owner,
            request.beneficiary,
            request.game,
            config.treasury,
            request.amount,
            currentNonce,
            request.purchaseDataHash,
            receiptId,
            msg.sender
        );
    }

    function invalidatePurchaseNonce(uint256 newNonce) external override {
        uint256 currentNonce = purchaseNonces[msg.sender];
        if (newNonce <= currentNonce) revert InvalidPurchaseNonce();
        purchaseNonces[msg.sender] = newNonce;
        emit PurchaseNonceInvalidated(msg.sender, currentNonce, newNonce);
    }

    function treasuryTransfer(address to, uint256 amount) external override whenNotPaused nonReentrant {
        address game = gameRegistry.gameForTreasury(msg.sender);
        if (game == address(0)) revert UnregisteredTreasury();

        IGameRegistry.GameConfig memory config = gameRegistry.getGameConfig(game);
        if (config.treasury != msg.sender || config.status == IGameRegistry.GameStatus.None) {
            revert UnregisteredTreasury();
        }

        _moveBalance(msg.sender, msg.sender, to, amount);
        emit TreasuryTransfer(msg.sender, game, to, amount);
    }

    function disableLegacyDirectTransfers() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (legacyDirectTransfersDisabled) revert LegacyDirectTransfersAreDisabled();
        legacyDirectTransfersDisabled = true;
        emit LegacyDirectTransfersPermanentlyDisabled();
    }

    function directOperatorTransfer(address from, address to, uint256 amount)
        public
        override(UnifiedLedgerV2, IUnifiedLedgerV2)
    {
        if (legacyDirectTransfersDisabled) revert LegacyDirectTransfersAreDisabled();
        super.directOperatorTransfer(from, to, amount);
    }

    function _hashPurchaseAuthorization(address owner, PurchaseRequest calldata request)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                PURCHASE_REQUEST_TYPEHASH,
                owner,
                request.game,
                request.beneficiary,
                request.amount,
                request.purchaseDataHash,
                request.nonce,
                request.deadline
            )
        );
        return _hashTypedDataV4(structHash);
    }
}
