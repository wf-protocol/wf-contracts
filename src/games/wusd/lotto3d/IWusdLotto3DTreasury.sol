// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ILotto3DTreasury} from "../../lotto3d/interfaces/ILotto3DTreasury.sol";
import {IRevenueAllocationTreasury} from "../../../protocol/IRevenueAllocationTreasury.sol";

/// @notice Round-scoped accounting extensions used by the WUSD Lotto3D game.
interface IWusdLotto3DTreasury is ILotto3DTreasury, IRevenueAllocationTreasury {
    function finalizeRoundAccounting(uint40 roundId, uint64 claimDeadline, uint256 winnerLiability) external;

    function payRoundClaim(uint40 roundId, address to, uint256 amount) external;

    function payRoundClaims(uint40[] calldata roundIds, address to, uint256[] calldata amounts) external;

    function expireRoundClaims(uint40 roundId) external returns (uint256 recycledAmount);
}
