// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev 原样移植自 lotto7-refactored/src/lotto3d/libraries/Lotto3DPrizeMath.sol，
///      逻辑未作任何改动。3 位数字彩票号码匹配纯数学库，不涉及资金操作。
library Lotto3DPrizeMath {
    uint16 internal constant NUMBER_MODULUS = 1000;

    function isValidNumber(uint16 number) internal pure returns (bool) {
        return number < NUMBER_MODULUS;
    }

    function splitDigits(uint16 number) internal pure returns (uint8 d0, uint8 d1, uint8 d2) {
        d2 = uint8(number % 10);
        d1 = uint8((number / 10) % 10);
        d0 = uint8(number / 100);
    }

    function isTriple(uint16 number) internal pure returns (bool) {
        (uint8 d0, uint8 d1, uint8 d2) = splitDigits(number);
        return d0 == d1 && d1 == d2;
    }

    function comboKey(uint16 number) internal pure returns (uint16) {
        (uint8 d0, uint8 d1, uint8 d2) = splitDigits(number);
        if (d0 > d1) (d0, d1) = (d1, d0);
        if (d1 > d2) (d1, d2) = (d2, d1);
        if (d0 > d1) (d0, d1) = (d1, d0);
        return uint16(d0) * 100 + uint16(d1) * 10 + uint16(d2);
    }

    function pairKeys(uint16 number) internal pure returns (uint16 key01, uint16 key02, uint16 key12) {
        (uint8 d0, uint8 d1, uint8 d2) = splitDigits(number);
        key01 = uint16(d0) * 10 + uint16(d1);
        key02 = 100 + uint16(d0) * 10 + uint16(d2);
        key12 = 200 + uint16(d1) * 10 + uint16(d2);
    }

    function highestTier(uint16 ticket, uint16 winning) internal pure returns (uint8) {
        if (ticket == winning) return 1;

        if (!isTriple(winning) && comboKey(ticket) == comboKey(winning)) return 2;

        (uint8 t0, uint8 t1, uint8 t2) = splitDigits(ticket);
        (uint8 w0, uint8 w1, uint8 w2) = splitDigits(winning);
        if (t0 == w0 && t1 == w1) return 3;
        if (t0 == w0 && t2 == w2) return 3;
        if (t1 == w1 && t2 == w2) return 3;

        return 0;
    }

    function uniquePermCount(uint16 number) internal pure returns (uint256) {
        (uint8 d0, uint8 d1, uint8 d2) = splitDigits(number);
        if (d0 == d1 && d1 == d2) return 1;
        if (d0 == d1 || d1 == d2 || d0 == d2) return 3;
        return 6;
    }

    function allPermutations(uint16 number) internal pure returns (uint16[6] memory perms) {
        (uint8 d0, uint8 d1, uint8 d2) = splitDigits(number);

        perms[0] = _encode(d0, d1, d2);
        perms[1] = _encode(d0, d2, d1);
        perms[2] = _encode(d1, d0, d2);
        perms[3] = _encode(d1, d2, d0);
        perms[4] = _encode(d2, d0, d1);
        perms[5] = _encode(d2, d1, d0);

        uint256 count = 6;
        for (uint256 i = 0; i < count; i++) {
            for (uint256 j = i + 1; j < count;) {
                if (perms[j] == perms[i]) {
                    perms[j] = perms[count - 1];
                    perms[count - 1] = 0;
                    count--;
                } else {
                    j++;
                }
            }
        }
    }

    function _encode(uint8 d0, uint8 d1, uint8 d2) internal pure returns (uint16) {
        return uint16(d0) * 100 + uint16(d1) * 10 + uint16(d2);
    }
}
