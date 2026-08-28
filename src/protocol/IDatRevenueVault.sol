// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IDatRevenueVault {
    function beneficiary() external view returns (address);
    function claim(uint256 amount) external;
    function claimAll() external;
}
