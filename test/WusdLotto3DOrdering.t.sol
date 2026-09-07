// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ILotto3DGame} from "../src/games/lotto3d/interfaces/ILotto3DGame.sol";
import {IUnifiedLedgerV2} from "../src/wusd/IUnifiedLedgerV2.sol";
import {IWusdLotto3DTreasury} from "../src/games/wusd/lotto3d/IWusdLotto3DTreasury.sol";
import {WusdLotto3DGame} from "../src/games/wusd/lotto3d/WusdLotto3DGame.sol";

contract MockLotto3DOrderingTreasury {
    bool public lastReleaseRound;

    function settleRoundPrize(uint40, bool isReleaseRound) external returns (uint256 prizePool) {
        lastReleaseRound = isReleaseRound;
        return 0;
    }

    function finalizeRoundAccounting(uint40, uint64, uint256) external {}

    function reserveForRefund(uint256) external {}
}

contract WusdLotto3DOrderingTest is Test {
    WusdLotto3DGame internal game;
    MockLotto3DOrderingTreasury internal treasury;
    address internal constant KEEPER = address(0xA11CE);

    function setUp() public {
        vm.warp(1_800_000_000);
        treasury = new MockLotto3DOrderingTreasury();
        game = WusdLotto3DGame(
            address(
                new ERC1967Proxy(
                    address(new WusdLotto3DGame()),
                    abi.encodeCall(
                        WusdLotto3DGame.initialize,
                        (address(this), IUnifiedLedgerV2(address(0xBEEF)), IWusdLotto3DTreasury(address(treasury)), 1e6)
                    )
                )
            )
        );
        game.grantRole(game.VRF_ROLE(), address(this));
        game.grantRole(game.KEEPER_ROLE(), KEEPER);
    }

    function testCannotSettleLaterRoundBeforeItsPredecessor() public {
        _createClosedRound(1);
        _createClosedRound(100);

        vm.expectRevert(abi.encodeWithSelector(WusdLotto3DGame.PreviousRoundUnresolved.selector, uint40(1)));
        game.settleDraw(100, 123);

        game.cancelRound(1);
        game.settleDraw(100, 123);

        assertEq(uint8(game.getRound(100).status), uint8(ILotto3DGame.RoundStatus.Settled));
    }

    function testCreationSequenceDoesNotDependOnRoundId() public {
        _createClosedRound(10);
        _createClosedRound(1_000);

        assertEq(game.previousRoundId(1_000), 10);
        assertEq(game.roundSequence(10), 1);
        assertEq(game.roundSequence(1_000), 2);

        vm.expectRevert(WusdLotto3DGame.InvalidRoundOrder.selector);
        _createClosedRound(999);
    }

    function testKeeperCanOnlyCancelAfterDrawDeadline() public {
        _createClosedRound(1);

        vm.prank(KEEPER);
        vm.expectRevert(WusdLotto3DGame.SalesNotClosed.selector);
        game.cancelTimedOutRound(1);

        vm.warp(block.timestamp + 101);
        vm.prank(KEEPER);
        game.cancelTimedOutRound(1);

        assertEq(uint8(game.getRound(1).status), uint8(ILotto3DGame.RoundStatus.Cancelled));
    }

    function testKeeperCanCreateRound() public {
        vm.prank(KEEPER);
        _createClosedRound(1);

        assertTrue(game.getRound(1).exists);
    }

    function _createClosedRound(uint40 roundId) internal {
        game.createRound(
            roundId,
            ILotto3DGame.RoundConfig({
                salesOpenTime: uint64(block.timestamp - 100),
                salesCloseTime: uint64(block.timestamp - 50),
                drawDeadline: uint64(block.timestamp + 100)
            })
        );
    }
}
