// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUnifiedLedgerV4} from "../../src/wusd/IUnifiedLedgerV4.sol";

contract MockOfficialTreasuryV4 {
    function pay(IUnifiedLedgerV4 ledger, address recipient, uint256 amount) external {
        ledger.protocolTransfer(recipient, amount);
    }
}
