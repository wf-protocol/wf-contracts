// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUnifiedLedgerV2} from "./IUnifiedLedgerV2.sol";
import {IGameRegistry} from "../protocol/IGameRegistry.sol";

interface IUnifiedLedgerV3 is IUnifiedLedgerV2 {
    struct PurchaseRequest {
        address game;
        address beneficiary;
        uint256 amount;
        bytes32 purchaseDataHash;
        uint256 nonce;
        uint48 deadline;
    }

    function gameRegistry() external view returns (IGameRegistry);
    function purchaseNonces(address owner) external view returns (uint256);
    function domainSeparatorV4() external view returns (bytes32);

    function executePurchase(PurchaseRequest calldata request, bytes calldata purchaseData)
        external
        returns (bytes32 receiptId);

    function executePurchaseWithAuthorization(
        address owner,
        PurchaseRequest calldata request,
        bytes calldata purchaseData,
        bytes calldata signature
    ) external returns (bytes32 receiptId);

    function invalidatePurchaseNonce(uint256 newNonce) external;

    /// @notice Moves WUSD owned by a registered game Treasury to a recipient.
    /// @dev The caller is always the debited account; no arbitrary `from` is accepted.
    function treasuryTransfer(address to, uint256 amount) external;
}
