// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IGameModuleV3 {
    /// @notice Code hash of the implementation currently backing this game module.
    /// @dev Upgradeable modules report the ERC-1967 implementation code hash,
    ///      not the proxy code hash, so Registry reviews expire on upgrade.
    function protocolImplementationHash() external view returns (bytes32);

    function quotePurchase(address payer, address beneficiary, bytes calldata purchaseData)
        external
        view
        returns (uint256 amount);

    function purchaseFromLedger(address payer, address beneficiary, uint256 amount, bytes calldata purchaseData)
        external
        returns (bytes32 receiptId);
}
