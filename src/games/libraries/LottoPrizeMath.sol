// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev 原样移植自 lotto7-refactored/src/libraries/LottoPrizeMath.sol，逻辑未作任何改动。
///      7 位数字彩票（Lotto7）的号码匹配/等级判定纯数学库，不涉及资金操作，
///      因此不受本次"接入 LedgerContract"改造影响。
library LottoPrizeMath {
    uint32 internal constant NUMBER_MODULUS = 10_000_000;

    function isValidNumber(uint32 number) internal pure returns (bool) {
        return number < NUMBER_MODULUS;
    }

    function prefix6(uint32 number) internal pure returns (uint32) {
        return number / 10;
    }

    function prefix5(uint32 number) internal pure returns (uint32) {
        return number / 100;
    }

    function highestTier(uint32 ticketNumber, uint32 winningNumber) internal pure returns (uint8) {
        uint8[7] memory ticketDigits = splitDigits(ticketNumber);
        uint8[7] memory winningDigits = splitDigits(winningNumber);

        uint8 leading = leadingMatches(ticketDigits, winningDigits);
        if (leading == 7) {
            return 1;
        }
        if (leading == 6) {
            return 2;
        }
        if (leading == 5) {
            return 3;
        }
        if (_hasAnyContiguousWindow(ticketDigits, winningDigits, 4)) {
            return 4;
        }
        if (_hasAnyContiguousWindow(ticketDigits, winningDigits, 3)) {
            return 5;
        }
        return 0;
    }

    function splitDigits(uint32 number) internal pure returns (uint8[7] memory digits) {
        for (uint256 i = 0; i < 7; ++i) {
            digits[6 - i] = uint8(number % 10);
            number /= 10;
        }
    }

    function leadingMatches(uint8[7] memory ticketDigits, uint8[7] memory winningDigits)
        internal
        pure
        returns (uint8 matches_)
    {
        for (uint8 i = 0; i < 7; ++i) {
            if (ticketDigits[i] != winningDigits[i]) {
                return matches_;
            }
            unchecked {
                ++matches_;
            }
        }
    }

    function _hasAnyContiguousWindow(uint8[7] memory ticketDigits, uint8[7] memory winningDigits, uint8 window)
        private
        pure
        returns (bool)
    {
        unchecked {
            for (uint8 ticketStart = 0; ticketStart <= 7 - window; ++ticketStart) {
                for (uint8 winningStart = 0; winningStart <= 7 - window; ++winningStart) {
                    bool matched = true;
                    for (uint8 offset = 0; offset < window; ++offset) {
                        if (ticketDigits[ticketStart + offset] != winningDigits[winningStart + offset]) {
                            matched = false;
                            break;
                        }
                    }
                    if (matched) {
                        return true;
                    }
                }
            }
        }
        return false;
    }
}
