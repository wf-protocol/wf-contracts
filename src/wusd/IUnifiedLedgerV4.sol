// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUnifiedLedgerV3} from "./IUnifiedLedgerV3.sol";

interface IUnifiedLedgerV4 is IUnifiedLedgerV3 {
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
