// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library RevenueAllocationLib {
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    function split(uint256 amount, uint16 prizeBps, uint16 datBps, uint16 partnerBps)
        internal
        pure
        returns (uint256 prizeAmount, uint256 datAmount, uint256 partnerAmount, uint256 opsAmount)
    {
        prizeAmount = amount * prizeBps / BPS_DENOMINATOR;
        datAmount = amount * datBps / BPS_DENOMINATOR;
        partnerAmount = amount * partnerBps / BPS_DENOMINATOR;
        opsAmount = amount - prizeAmount - datAmount - partnerAmount;
    }
}
