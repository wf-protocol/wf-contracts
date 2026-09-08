// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Ledger calls this after moving the funder's own WUSD, atomically.
interface IProtocolFundingReceiver {
    function onProtocolFunding(address funder, uint256 amount, bytes calldata data) external;
}
