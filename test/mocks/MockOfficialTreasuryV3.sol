// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUnifiedLedgerV3} from "../../src/wusd/IUnifiedLedgerV3.sol";

contract MockOfficialTreasuryV3 {
    function pay(IUnifiedLedgerV3 ledger, address recipient, uint256 amount) external {
        ledger.treasuryTransfer(recipient, amount);
    }
}
