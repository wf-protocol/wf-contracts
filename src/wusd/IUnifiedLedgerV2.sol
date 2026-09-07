// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IUnifiedLedgerV2
/// @notice WUSD 内部记账层的最小外部接口。WUSD 不是 ERC-20，不支持自由钱包转账。
interface IUnifiedLedgerV2 {
    function balanceOf(address account) external view returns (uint256);
    function totalWusdLiability() external view returns (uint256);
    function operatorAllowances(address owner, address operator) external view returns (uint256);
    function operators(address operator) external view returns (bool);
    function directOperators(address operator) external view returns (bool);

    function approveOperator(address operator, uint256 amount) external;
    function operatorTransfer(address from, address to, uint256 amount) external;

    /// @notice 供平台明确登记的游戏在玩家主动调用购票函数时完成单笔扣款。
    /// @dev 游戏的普通 buy 路径必须始终以当前调用者作为 from；代买路径不得使用此入口。
    function directOperatorTransfer(address from, address to, uint256 amount) external;

    /// @dev 仅 StablecoinReserve 可调用；充值真实资产后生成等额 WUSD 负债。
    function creditFromReserve(address account, uint256 amount) external;

    /// @dev 仅 StablecoinReserve 可调用；提现真实资产前销毁对应 WUSD 负债。
    function debitToReserve(address account, uint256 amount) external;
}
