// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRevenueAllocationTreasury} from "../../../protocol/IRevenueAllocationTreasury.sol";

interface IWusdLottoUmaRevenueTreasury is IRevenueAllocationTreasury {
    function previewRoundPrize(uint256 roundId, uint256 totalSales) external view returns (uint256 prizeAmount);
    function finalizeRoundRevenue(uint256 roundId, uint256 totalSales) external returns (uint256 prizeAmount);
}
