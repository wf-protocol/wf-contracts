// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IUnifiedLedgerV2
interface IUnifiedLedgerV2 {
    function balanceOf(address account) external view returns (uint256);
    function totalWusdLiability() external view returns (uint256);
    function operatorAllowances(address owner, address operator) external view returns (uint256);
    function operators(address operator) external view returns (bool);
    function directOperators(address operator) external view returns (bool);

    function approveOperator(address operator, uint256 amount) external;
    function operatorTransfer(address from, address to, uint256 amount) external;

    function directOperatorTransfer(address from, address to, uint256 amount) external;

    function creditFromReserve(address account, uint256 amount) external;

    function debitToReserve(address account, uint256 amount) external;
}
