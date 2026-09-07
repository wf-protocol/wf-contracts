// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {UnifiedLedgerV3} from "./UnifiedLedgerV3.sol";
import {IUnifiedLedgerV4} from "./IUnifiedLedgerV4.sol";
import {IGameRegistry} from "../protocol/IGameRegistry.sol";
import {IGameModuleV4} from "../protocol/IGameModuleV4.sol";

/// @title UnifiedLedgerV4
/// @notice Purchase entry point that binds channel attribution to the Treasury's round allocation snapshot.
contract UnifiedLedgerV4 is UnifiedLedgerV3, IUnifiedLedgerV4 {
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

    function initializeV4() external reinitializer(4) onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(gameRegistry) == address(0)) revert InvalidRegistry();
        __EIP712_init("UnifiedLedger", "4");
    }

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
        _moveBalance(address(this), request.owner, config.treasury, request.amount);

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
