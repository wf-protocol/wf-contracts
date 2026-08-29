// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Lotto3DVRFAdapter} from "../src/games/lotto3d/Lotto3DVRFAdapter.sol";
import {ILotto3DGame} from "../src/games/lotto3d/interfaces/ILotto3DGame.sol";
import {MockVRFCoordinatorV2Plus} from "./mocks/MockVRFCoordinatorV2Plus.sol";

contract MockLotto3DGameForVrf is ILotto3DGame {
    mapping(uint40 => RoundData) internal rounds;
    bool public failSettlement;
    uint40 public settledRound;
    uint16 public settledNumber;
    uint40 public cancelledRound;

    function setRound(uint40 roundId, RoundData calldata round) external {
        rounds[roundId] = round;
    }

    function setFailSettlement(bool fail) external {
        failSettlement = fail;
    }

    function settleDraw(uint40 roundId, uint16 winningNumber) external {
        if (failSettlement) revert("settlement failed");
        settledRound = roundId;
        settledNumber = winningNumber;
    }

    function cancelTimedOutRound(uint40 roundId) external {
        cancelledRound = roundId;
    }

    function getRound(uint40 roundId) external view returns (RoundData memory) {
        return rounds[roundId];
    }
}

contract Lotto3DVRFAdapterTest is Test {
    address internal admin = address(0xAD01);
    address internal keeper = address(0xBEEF);
    MockLotto3DGameForVrf internal game;
    MockVRFCoordinatorV2Plus internal coordinator;
    Lotto3DVRFAdapter internal adapter;

    function setUp() public {
        vm.warp(1_800_000_000);
        game = new MockLotto3DGameForVrf();
        coordinator = new MockVRFCoordinatorV2Plus();
        Lotto3DVRFAdapter.VRFConfig memory config = Lotto3DVRFAdapter.VRFConfig({
            vrfCoordinator: address(coordinator),
            keyHash: keccak256("key"),
            subscriptionId: 1,
            requestConfirmations: 3,
            callbackGasLimit: 500_000
        });
        adapter = Lotto3DVRFAdapter(
            address(
                new ERC1967Proxy(
                    address(new Lotto3DVRFAdapter()),
                    abi.encodeCall(Lotto3DVRFAdapter.initialize, (admin, ILotto3DGame(address(game)), config))
                )
            )
        );
        bytes32 keeperRole = adapter.KEEPER_ROLE();
        vm.prank(admin);
        adapter.grantRole(keeperRole, keeper);
    }

    function testCannotRequestNonexistentRound() public {
        vm.prank(keeper);
        vm.expectRevert(Lotto3DVRFAdapter.DrawNotReady.selector);
        adapter.requestDraw(999);
    }

    function testCallbackStoresRandomnessAndSettlementCanRetry() public {
        _setReadyRound(1);
        vm.prank(keeper);
        uint256 requestId = adapter.requestDraw(1);

        game.setFailSettlement(true);
        coordinator.fulfillRandomWords(requestId, 1_234);
        assertTrue(adapter.randomnessFulfilled(1));
        assertEq(adapter.storedWinningNumber(1), 234);
        assertEq(adapter.pendingRequestCount(), 0);

        vm.expectRevert(bytes("settlement failed"));
        adapter.finalizeDraw(1);
        assertFalse(adapter.drawFinalized(1));

        game.setFailSettlement(false);
        adapter.finalizeDraw(1);
        assertTrue(adapter.drawFinalized(1));
        assertEq(game.settledRound(), 1);
        assertEq(game.settledNumber(), 234);
    }

    function testTimedOutRequestCanCancelAndLateCallbackIsIgnored() public {
        _setReadyRound(2);
        vm.prank(keeper);
        uint256 requestId = adapter.requestDraw(2);
        ILotto3DGame.RoundData memory round = game.getRound(2);

        vm.warp(uint256(round.config.drawDeadline) + adapter.effectiveResponseTimeout() + 1);
        adapter.cancelTimedOutRequest(2);

        assertEq(adapter.pendingRequestCount(), 0);
        assertEq(game.cancelledRound(), 2);
        assertTrue(adapter.drawFinalized(2));

        coordinator.fulfillRandomWords(requestId, 777);
        assertFalse(adapter.randomnessFulfilled(2));
        assertEq(adapter.storedWinningNumber(2), 0);
    }

    function testCannotChangeConfigWhileRequestIsPending() public {
        _setReadyRound(3);
        vm.prank(keeper);
        adapter.requestDraw(3);

        vm.prank(admin);
        vm.expectRevert(Lotto3DVRFAdapter.ActiveRequests.selector);
        adapter.setGame(ILotto3DGame(address(game)));
    }

    function testTimedOutRequestCanBeClearedAfterRoundWasAlreadyCancelled() public {
        _setReadyRound(4);
        vm.prank(keeper);
        adapter.requestDraw(4);

        ILotto3DGame.RoundData memory round = game.getRound(4);
        round.status = ILotto3DGame.RoundStatus.Cancelled;
        game.setRound(4, round);
        vm.warp(uint256(round.config.drawDeadline) + adapter.effectiveResponseTimeout() + 1);

        adapter.cancelTimedOutRequest(4);
        assertEq(adapter.pendingRequestCount(), 0);
        assertTrue(adapter.drawFinalized(4));

        vm.prank(admin);
        adapter.setGame(ILotto3DGame(address(game)));
    }

    function _setReadyRound(uint40 roundId) internal {
        ILotto3DGame.RoundData memory round;
        round.exists = true;
        round.status = ILotto3DGame.RoundStatus.Open;
        round.config = ILotto3DGame.RoundConfig({
            salesOpenTime: uint64(block.timestamp - 2 hours),
            salesCloseTime: uint64(block.timestamp - 1 hours),
            drawDeadline: uint64(block.timestamp + 1 hours)
        });
        game.setRound(roundId, round);
    }
}
