// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IGameModuleV3} from "../../src/protocol/IGameModuleV3.sol";
import {IGameModuleV4} from "../../src/protocol/IGameModuleV4.sol";

contract MockGameModuleV4 is IGameModuleV3, IGameModuleV4 {
    address public immutable ledger;
    uint32 public allocationVersion = 1;
    uint16 public partnerBps = 500;
    uint256 public purchaseCount;
    bytes32 public lastWfOrderId;
    bytes32 public lastPartnerCode;

    error OnlyLedger();
    error WrongAmount();

    constructor(address ledger_) {
        ledger = ledger_;
    }

    function setAllocation(uint32 allocationVersion_, uint16 partnerBps_) external {
        allocationVersion = allocationVersion_;
        partnerBps = partnerBps_;
    }

    function protocolImplementationHash() external view returns (bytes32) {
        return address(this).codehash;
    }

    function quotePurchase(address, address, bytes calldata purchaseData) external pure returns (uint256 amount) {
        amount = abi.decode(purchaseData, (uint256));
    }

    function purchaseFromLedger(address, address, uint256, bytes calldata) external pure returns (bytes32) {
        revert("V4 only");
    }

    function purchaseFromLedgerV4(
        address payer,
        address beneficiary,
        uint256 amount,
        PurchaseContext calldata context,
        bytes calldata purchaseData
    ) external returns (bytes32 receiptId, uint32 returnedAllocationVersion, uint16 returnedPartnerBps) {
        if (msg.sender != ledger) revert OnlyLedger();
        if (amount != abi.decode(purchaseData, (uint256))) revert WrongAmount();
        lastWfOrderId = context.wfOrderId;
        lastPartnerCode = context.partnerCode;
        receiptId = keccak256(abi.encode(payer, beneficiary, amount, context, ++purchaseCount));
        returnedAllocationVersion = allocationVersion;
        returnedPartnerBps = partnerBps;
    }
}
