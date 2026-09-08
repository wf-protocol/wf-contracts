// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ILottoRounds} from "../src/games/lotto7uma/interfaces/ILottoRounds.sol";
import {IUnifiedLedgerV4} from "../src/wusd/IUnifiedLedgerV4.sol";
import {WusdLottoRounds} from "../src/games/wusd/lotto7uma/WusdLottoRounds.sol";

contract MockSourcePlanTreasury {
    function snapshotRoundAllocation(uint256) external pure returns (uint16, uint16, uint16, uint16, uint32, bool) {
        return (8000, 0, 500, 1500, 1, true);
    }
}

contract WusdLottoRoundsOrderingTest is Test {
    WusdLottoRounds internal rounds;
    address internal constant KEEPER = address(0xA11CE);

    function setUp() public {
        vm.warp(1_800_000_000);
        rounds = WusdLottoRounds(
            address(
                new ERC1967Proxy(
                    address(new WusdLottoRounds()),
                    abi.encodeCall(
                        WusdLottoRounds.initialize,
                        (address(this), IUnifiedLedgerV4(address(0xBEEF)), address(new MockSourcePlanTreasury()), 1e6)
                    )
                )
            )
        );
        rounds.grantRole(rounds.KEEPER_ROLE(), KEEPER);
    }

    function testRoundsFormAnImmutableCreationOrder() public {
        _createRound(10);
        _createRound(1_000);

        assertEq(rounds.latestRoundId(), 1_000);
        assertEq(rounds.previousRoundId(10), 0);
        assertEq(rounds.previousRoundId(1_000), 10);
    }

    function testCannotCreateDuplicateOrDecreasingRoundId() public {
        _createRound(100);

        vm.expectRevert(WusdLottoRounds.InvalidRoundOrder.selector);
        _createRound(100);
        vm.expectRevert(WusdLottoRounds.InvalidRoundOrder.selector);
        _createRound(99);
    }

    function testKeeperCanCreateRound() public {
        vm.prank(KEEPER);
        _createRound(1);

        assertEq(rounds.latestRoundId(), 1);
    }

    function _createRound(uint40 roundId) internal {
        rounds.createRound(
            roundId,
            ILottoRounds.RoundConfig({
                salesOpenTime: uint64(block.timestamp + 10),
                salesCloseTime: uint64(block.timestamp + 20),
                drawDataDeadline: uint64(block.timestamp + 30),
                claimDeadline: uint64(block.timestamp + 40),
                maxMultiplierPerTicket: 10,
                assertionLiveness: 1
            })
        );
    }
}
