// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ILotto7Treasury
/// @notice 管理 Lotto7 的资金池：奖金池 / 运维费 / 持币分红池。
/// @dev 对应 规则.md 第9节资金分配：80% 奖金池 + 15% 运维成本 + 5% 持币分红。
interface ILotto7Treasury {
    /// @notice 记录一轮销售额并按 80/15/5 拆分入奖金池/运维池/分红池。
    function collectSales(uint256 roundId, uint256 totalSales) external;

    /// @notice 结算时获取本轮可用于派奖的奖金池余额。
    function settleRoundPrize(uint256 roundId) external returns (uint256 prizePool);

    /// @notice 向中奖用户支付奖金。
    function payClaim(address to, uint256 amount) external;

    /// @notice 取消轮次后向玩家退回完整票款；退款不受 pause 限制。
    function payRefund(address to, uint256 amount) external;

    /// @notice 任何人可向指定档位奖池注资（需先 approveOperator 授权本 Treasury）。
    /// @param tier 1/2/3 对应一/二/三等奖浮动奖池
    function injectJackpot(uint8 tier, uint256 amount) external;

    /// @notice 查询当前各档滚存奖池余额。
    function getJackpots() external view returns (uint256 j1, uint256 j2, uint256 j3);

    /// @notice 运维方按 OPS_ROLE 权限提取累计运维费。
    function claimOps() external;

    /// @notice 分红角色按 DIVIDEND_ROLE 权限提取累计分红池资金。
    function claimDividend() external;
}
