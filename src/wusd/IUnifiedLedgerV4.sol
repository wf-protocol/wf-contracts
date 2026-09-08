// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IGameRegistry} from "../protocol/IGameRegistry.sol";

interface IUnifiedLedgerV4 {
    struct PurchaseRequestV4 {
        address owner;
        address game;
        address beneficiary;
        uint256 amount;
        bytes32 purchaseDataHash;
        bytes32 wfOrderId;
        bytes32 partnerCode;
        uint256 nonce;
        uint48 deadline;
    }

    function usedWfOrderIds(bytes32 wfOrderId) external view returns (bool);
    function gameRegistry() external view returns (IGameRegistry);
    function balanceOf(address account) external view returns (uint256);
    function totalWusdLiability() external view returns (uint256);
    function purchaseNonces(address owner) external view returns (uint256);
    function invalidatePurchaseNonce(uint256 newNonce) external;
    function creditFromReserve(address account, uint256 amount) external;
    function debitToReserve(address account, uint256 amount) external;
    function protocolTransfer(address recipient, uint256 amount) external;
    function fundProtocolAccount(address account, uint256 amount, bytes calldata data) external;
    function hashPurchaseAuthorizationV4(PurchaseRequestV4 calldata request) external view returns (bytes32);

    function executePurchaseV4(PurchaseRequestV4 calldata request, bytes calldata purchaseData)
        external
        returns (bytes32 receiptId);

    function executePurchaseWithAuthorizationV4(
        PurchaseRequestV4 calldata request,
        bytes calldata purchaseData,
        bytes calldata signature
    ) external returns (bytes32 receiptId);
}
