// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IGameModuleV3} from "../../src/protocol/IGameModuleV3.sol";
import {IUnifiedLedgerV2} from "../../src/wusd/IUnifiedLedgerV2.sol";

contract MockGameModuleV3 is IGameModuleV3 {
    address public immutable ledger;
    uint256 public purchaseCount;
    address public lastPayer;
    address public lastBeneficiary;
    uint256 public lastAmount;
    bytes32 public lastActionId;
    bool public shouldRevert;

    error OnlyLedger();
    error WrongAmount();
    error ForcedRevert();

    constructor(address ledger_) {
        ledger = ledger_;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function protocolImplementationHash() external view returns (bytes32) {
        return address(this).codehash;
    }

    function quotePurchase(address, address, bytes calldata purchaseData) external pure returns (uint256 amount) {
        (amount,) = abi.decode(purchaseData, (uint256, bytes32));
    }

    function purchaseFromLedger(address payer, address beneficiary, uint256 amount, bytes calldata purchaseData)
        external
        returns (bytes32 receiptId)
    {
        if (msg.sender != ledger) revert OnlyLedger();
        if (shouldRevert) revert ForcedRevert();

        (uint256 expectedAmount, bytes32 actionId) = abi.decode(purchaseData, (uint256, bytes32));
        if (amount != expectedAmount) revert WrongAmount();

        purchaseCount++;
        lastPayer = payer;
        lastBeneficiary = beneficiary;
        lastAmount = amount;
        lastActionId = actionId;
        receiptId = keccak256(abi.encode(payer, beneficiary, amount, actionId, purchaseCount));
    }

    function attemptLegacyDrain(address from, address to, uint256 amount) external {
        IUnifiedLedgerV2(ledger).directOperatorTransfer(from, to, amount);
    }
}
