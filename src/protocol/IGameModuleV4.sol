// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IGameModuleV4 {
    function protocolImplementationHash() external view returns (bytes32);
    function quotePurchase(address payer, address beneficiary, bytes calldata purchaseData)
        external
        view
        returns (uint256 amount);

    struct PurchaseContext {
        bytes32 wfOrderId;
        bytes32 partnerCode;
    }

    function purchaseFromLedgerV4(
        address payer,
        address beneficiary,
        uint256 amount,
        PurchaseContext calldata context,
        bytes calldata purchaseData
    ) external returns (bytes32 receiptId, uint32 allocationVersion, uint16 partnerBps);
}
