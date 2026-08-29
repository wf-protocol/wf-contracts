// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {GameRegistry} from "../src/protocol/GameRegistry.sol";
import {IGameRegistry} from "../src/protocol/IGameRegistry.sol";
import {StablecoinReserve} from "../src/wusd/StablecoinReserve.sol";
import {Lotto3DVRFAdapter} from "../src/games/lotto3d/Lotto3DVRFAdapter.sol";
import {LottoSettlement} from "../src/games/lotto7uma/LottoSettlement.sol";
import {WusdLotto3DGame} from "../src/games/wusd/lotto3d/WusdLotto3DGame.sol";
import {WusdLotto3DTreasury} from "../src/games/wusd/lotto3d/WusdLotto3DTreasury.sol";
import {WusdLottoRounds} from "../src/games/wusd/lotto7uma/WusdLottoRounds.sol";
import {WusdLottoTreasury} from "../src/games/wusd/lotto7uma/WusdLottoTreasury.sol";

contract PolygonMainnetMockSecurityUpgradeForkTest is Test {
    address internal constant SAFE = 0xA94AA53C7f6075f650AfE9cE69500Bc593306f48;
    GameRegistry internal constant REGISTRY = GameRegistry(0x423D2374b41Ae8524512E7079b81Ebd8CC4A5a19);
    StablecoinReserve internal constant RESERVE = StablecoinReserve(0x6947B739692A5937e5b8272831Ac301061259Fc7);
    WusdLotto3DGame internal constant LOTTO3D_GAME = WusdLotto3DGame(0x1A66C6f2F63085d26d93F42Bc4eB2Fd7584666A3);
    WusdLotto3DTreasury internal constant LOTTO3D_TREASURY =
        WusdLotto3DTreasury(0x9Fb8E69B6187Fe628d72f696Da5d91894A208F18);
    Lotto3DVRFAdapter internal constant LOTTO3D_VRF = Lotto3DVRFAdapter(0xc2dDFf0f6287343C9Dc9D51326bAD4FDEd71cf1d);
    WusdLottoRounds internal constant UMA_ROUNDS = WusdLottoRounds(0x3a6F08D45179A4f575E5F9E82916342a13195143);
    WusdLottoTreasury internal constant UMA_TREASURY = WusdLottoTreasury(0x394FDaDce39F01AD208c63432e6139c80f523802);
    LottoSettlement internal constant UMA_SETTLEMENT = LottoSettlement(0x6121146343414cD24C72AC8985b4455bC025945F);

    uint40 internal constant LOTTO3D_LATEST_ROUND = 564;
    uint40 internal constant LOTTO3D_EXISTING_ROUND_COUNT = 564;
    uint40 internal constant UMA_LATEST_ROUND = 2;

    function testSecurityUpgradePreservesLiveState() external {
        if (address(RESERVE).code.length == 0) return;

        uint256 recognizedReserve = RESERVE.totalRecognizedReserve();
        uint256 accumulatedPool = LOTTO3D_TREASURY.accumulatedPool();
        uint256 carryPool = UMA_TREASURY.currentCarryPool();
        uint256 pendingVrfRequests = LOTTO3D_VRF.pendingRequestCount();
        IGameRegistry.GameConfig memory lotto3dConfig = REGISTRY.getGameConfig(address(LOTTO3D_GAME));
        IGameRegistry.GameConfig memory umaConfig = REGISTRY.getGameConfig(address(UMA_ROUNDS));

        StablecoinReserve reserveImplementation = new StablecoinReserve();
        WusdLotto3DGame lotto3dGameImplementation = new WusdLotto3DGame();
        WusdLotto3DTreasury lotto3dTreasuryImplementation = new WusdLotto3DTreasury();
        Lotto3DVRFAdapter lotto3dVrfImplementation = new Lotto3DVRFAdapter();
        WusdLottoRounds umaRoundsImplementation = new WusdLottoRounds();
        WusdLottoTreasury umaTreasuryImplementation = new WusdLottoTreasury();
        LottoSettlement umaSettlementImplementation = new LottoSettlement();

        vm.startPrank(SAFE);
        RESERVE.upgradeToAndCall(address(reserveImplementation), bytes(""));
        LOTTO3D_TREASURY.upgradeToAndCall(address(lotto3dTreasuryImplementation), bytes(""));
        LOTTO3D_VRF.upgradeToAndCall(address(lotto3dVrfImplementation), bytes(""));
        UMA_TREASURY.upgradeToAndCall(address(umaTreasuryImplementation), bytes(""));
        UMA_SETTLEMENT.upgradeToAndCall(address(umaSettlementImplementation), bytes(""));
        LOTTO3D_GAME.upgradeToAndCall(
            address(lotto3dGameImplementation),
            abi.encodeCall(
                WusdLotto3DGame.initializeRoundOrdering, (LOTTO3D_LATEST_ROUND, LOTTO3D_EXISTING_ROUND_COUNT)
            )
        );
        UMA_ROUNDS.upgradeToAndCall(
            address(umaRoundsImplementation),
            abi.encodeCall(WusdLottoRounds.initializeRoundOrdering, (UMA_LATEST_ROUND))
        );
        REGISTRY.setGameReview(
            address(LOTTO3D_GAME), address(lotto3dGameImplementation).codehash, lotto3dConfig.rulesHash, true, true
        );
        REGISTRY.setGameReview(
            address(UMA_ROUNDS), address(umaRoundsImplementation).codehash, umaConfig.rulesHash, true, true
        );
        vm.stopPrank();

        assertTrue(LOTTO3D_GAME.roundOrderingEnabled());
        assertEq(LOTTO3D_GAME.latestRoundId(), LOTTO3D_LATEST_ROUND);
        assertEq(LOTTO3D_GAME.roundSequenceCount(), LOTTO3D_EXISTING_ROUND_COUNT);
        assertTrue(UMA_ROUNDS.roundOrderingEnabled());
        assertEq(UMA_ROUNDS.latestRoundId(), UMA_LATEST_ROUND);
        assertTrue(REGISTRY.isActive(address(LOTTO3D_GAME)));
        assertTrue(REGISTRY.isActive(address(UMA_ROUNDS)));
        assertEq(RESERVE.totalRecognizedReserve(), recognizedReserve);
        assertEq(LOTTO3D_TREASURY.accumulatedPool(), accumulatedPool);
        assertEq(UMA_TREASURY.currentCarryPool(), carryPool);
        assertEq(LOTTO3D_VRF.pendingRequestCount(), pendingVrfRequests);
    }
}
