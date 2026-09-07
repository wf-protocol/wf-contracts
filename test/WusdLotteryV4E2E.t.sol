// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DatRevenueVault} from "../src/protocol/DatRevenueVault.sol";
import {GameRegistry} from "../src/protocol/GameRegistry.sol";
import {IGameRegistry} from "../src/protocol/IGameRegistry.sol";
import {IRevenueAllocationTreasury} from "../src/protocol/IRevenueAllocationTreasury.sol";
import {ProtocolRevenueRouter} from "../src/protocol/ProtocolRevenueRouter.sol";
import {IUnifiedLedgerV2} from "../src/wusd/IUnifiedLedgerV2.sol";
import {IUnifiedLedgerV4} from "../src/wusd/IUnifiedLedgerV4.sol";
import {UnifiedLedgerV2} from "../src/wusd/UnifiedLedgerV2.sol";
import {UnifiedLedgerV4} from "../src/wusd/UnifiedLedgerV4.sol";

import {ILotto3DGame} from "../src/games/lotto3d/interfaces/ILotto3DGame.sol";
import {WusdLotto3DGame} from "../src/games/wusd/lotto3d/WusdLotto3DGame.sol";
import {WusdLotto3DTreasury} from "../src/games/wusd/lotto3d/WusdLotto3DTreasury.sol";
import {ILotto7Game} from "../src/games/lotto7/interfaces/ILotto7Game.sol";
import {WusdLotto7Game} from "../src/games/wusd/lotto7/WusdLotto7Game.sol";
import {WusdLotto7Treasury} from "../src/games/wusd/lotto7/WusdLotto7Treasury.sol";
import {ILottoRounds} from "../src/games/lotto7uma/interfaces/ILottoRounds.sol";
import {WusdLottoRounds} from "../src/games/wusd/lotto7uma/WusdLottoRounds.sol";
import {WusdLottoTreasury} from "../src/games/wusd/lotto7uma/WusdLottoTreasury.sol";

contract WusdLotteryV4E2ETest is Test {
    uint256 internal constant UNIT = 1e6;

    address internal admin = address(0xAD01);
    address internal user = address(0xBEEF);
    address internal ops = address(0x0A05);
    address internal partnerSafe = address(0xA11CE);
    address internal revenueSettler = address(0x5E771E);

    GameRegistry internal registry;
    UnifiedLedgerV4 internal ledger;
    ProtocolRevenueRouter internal router;
    DatRevenueVault internal datVault;
    WusdLotto7Game internal lotto7;
    WusdLotto7Treasury internal lotto7Treasury;
    WusdLotto3DGame internal lotto3d;
    WusdLotto3DTreasury internal lotto3dTreasury;
    WusdLottoRounds internal umaRounds;
    WusdLottoTreasury internal umaTreasury;

    function setUp() public {
        vm.warp(1_800_000_000);

        registry = GameRegistry(
            address(new ERC1967Proxy(address(new GameRegistry()), abi.encodeCall(GameRegistry.initialize, (admin))))
        );
        ledger = UnifiedLedgerV4(
            address(
                new ERC1967Proxy(address(new UnifiedLedgerV4()), abi.encodeCall(UnifiedLedgerV2.initialize, (admin)))
            )
        );
        router = new ProtocolRevenueRouter(admin, 8000, 0, 500, 1500);
        datVault = new DatRevenueVault(admin, IUnifiedLedgerV2(address(ledger)), address(0xDA7A));

        _deployGames();
        _configureProtocol();
    }

    function _deployGames() internal {
        lotto7Treasury = WusdLotto7Treasury(
            address(
                new ERC1967Proxy(
                    address(new WusdLotto7Treasury()),
                    abi.encodeCall(
                        WusdLotto7Treasury.initialize, (admin, IUnifiedLedgerV2(address(ledger)), ops, address(0xD1A1))
                    )
                )
            )
        );
        lotto7 = WusdLotto7Game(
            address(
                new ERC1967Proxy(
                    address(new WusdLotto7Game()),
                    abi.encodeCall(
                        WusdLotto7Game.initialize,
                        (admin, IUnifiedLedgerV2(address(ledger)), lotto7Treasury, block.timestamp)
                    )
                )
            )
        );

        lotto3dTreasury = WusdLotto3DTreasury(
            address(
                new ERC1967Proxy(
                    address(new WusdLotto3DTreasury()),
                    abi.encodeCall(WusdLotto3DTreasury.initialize, (admin, IUnifiedLedgerV2(address(ledger)), ops))
                )
            )
        );
        lotto3d = WusdLotto3DGame(
            address(
                new ERC1967Proxy(
                    address(new WusdLotto3DGame()),
                    abi.encodeCall(
                        WusdLotto3DGame.initialize, (admin, IUnifiedLedgerV2(address(ledger)), lotto3dTreasury, UNIT)
                    )
                )
            )
        );

        umaTreasury = WusdLottoTreasury(
            address(
                new ERC1967Proxy(
                    address(new WusdLottoTreasury()),
                    abi.encodeCall(
                        WusdLottoTreasury.initialize,
                        (admin, IUnifiedLedgerV2(address(ledger)), UNIT, ops, address(0xD1A1), address(0xF00D))
                    )
                )
            )
        );
        umaRounds = WusdLottoRounds(
            address(
                new ERC1967Proxy(
                    address(new WusdLottoRounds()),
                    abi.encodeCall(
                        WusdLottoRounds.initialize,
                        (admin, IUnifiedLedgerV2(address(ledger)), address(umaTreasury), UNIT)
                    )
                )
            )
        );
    }

    function _configureProtocol() internal {
        vm.startPrank(admin);
        ledger.initializeV3(IGameRegistry(address(registry)));
        ledger.initializeV4();
        ledger.grantRole(ledger.RESERVE_ROLE(), admin);

        ledger.registerOperator(address(lotto7Treasury));
        ledger.registerOperator(address(lotto3dTreasury));
        ledger.registerOperator(address(umaTreasury));
        ledger.registerOperator(address(datVault));

        lotto7Treasury.grantRole(lotto7Treasury.GAME_ROLE(), address(lotto7));
        lotto3dTreasury.grantRole(lotto3dTreasury.GAME_ROLE(), address(lotto3d));
        umaTreasury.grantRole(umaTreasury.ROUNDS_ROLE(), address(umaRounds));

        lotto7Treasury.initializeRevenue(router, address(datVault), partnerSafe, ops, revenueSettler);
        lotto3dTreasury.initializeRevenue(router, address(datVault), partnerSafe, ops, revenueSettler);
        umaTreasury.initializeRevenue(router, address(datVault), partnerSafe, ops, revenueSettler);

        lotto7.grantRole(lotto7.GAME_ROLE(), admin);
        lotto3d.grantRole(lotto3d.VRF_ROLE(), admin);

        lotto3d.createRound(
            1,
            ILotto3DGame.RoundConfig({
                salesOpenTime: uint64(block.timestamp),
                salesCloseTime: uint64(block.timestamp + 10 minutes),
                drawDeadline: uint64(block.timestamp + 20 minutes)
            })
        );
        umaRounds.createRound(
            1,
            ILottoRounds.RoundConfig({
                salesOpenTime: uint64(block.timestamp),
                salesCloseTime: uint64(block.timestamp + 10 minutes),
                drawDataDeadline: uint64(block.timestamp + 20 minutes),
                claimDeadline: uint64(block.timestamp + 30 days),
                maxMultiplierPerTicket: 10,
                assertionLiveness: uint64(5 minutes)
            })
        );

        lotto7.initializeRevenueV4();
        lotto3d.initializeRevenueV4(1);
        umaRounds.initializeRevenueV4(1);

        registry.registerGame(
            address(lotto7),
            address(lotto7Treasury),
            address(0),
            lotto7.protocolImplementationHash(),
            keccak256("lotto7-v4"),
            true,
            true
        );
        registry.registerGame(
            address(lotto3d),
            address(lotto3dTreasury),
            address(0),
            lotto3d.protocolImplementationHash(),
            keccak256("lotto3d-v4"),
            true,
            true
        );
        registry.registerGame(
            address(umaRounds),
            address(umaTreasury),
            address(0),
            umaRounds.protocolImplementationHash(),
            keccak256("lotto7-uma-v4"),
            true,
            true
        );

        ledger.creditFromReserve(user, 100 * UNIT);
        vm.stopPrank();
    }

    function _request(address game, uint256 amount, bytes memory purchaseData, bytes32 wfOrderId, bytes32 partnerCode)
        internal
        view
        returns (IUnifiedLedgerV4.PurchaseRequestV4 memory)
    {
        return IUnifiedLedgerV4.PurchaseRequestV4({
            owner: user,
            game: game,
            beneficiary: user,
            amount: amount,
            purchaseDataHash: keccak256(purchaseData),
            wfOrderId: wfOrderId,
            partnerCode: partnerCode,
            nonce: ledger.purchaseNonces(user),
            deadline: uint48(block.timestamp + 5 minutes)
        });
    }

    function test_V4PurchasesReachAllOfficialLotteryGames() public {
        uint32[] memory lotto7Numbers = new uint32[](1);
        lotto7Numbers[0] = 1_234_567;
        uint32[] memory lotto7Multipliers = new uint32[](1);
        lotto7Multipliers[0] = 1;
        bytes memory lotto7Data = abi.encode(uint256(1), lotto7Numbers, lotto7Multipliers);
        bytes32 lotto7OrderId = keccak256("partner-order-lotto7");
        bytes32 partnerCode = keccak256("partner-a");
        IUnifiedLedgerV4.PurchaseRequestV4 memory lotto7Request =
            _request(address(lotto7), UNIT, lotto7Data, lotto7OrderId, partnerCode);

        vm.prank(user);
        ledger.executePurchaseV4(lotto7Request, lotto7Data);

        uint16[] memory lotto3dNumbers = new uint16[](1);
        lotto3dNumbers[0] = 123;
        bytes memory lotto3dData = abi.encode(uint40(1), lotto3dNumbers);
        IUnifiedLedgerV4.PurchaseRequestV4 memory lotto3dRequest =
            _request(address(lotto3d), UNIT, lotto3dData, bytes32(0), bytes32(0));
        vm.prank(user);
        ledger.executePurchaseV4(lotto3dRequest, lotto3dData);

        uint32[] memory umaNumbers = new uint32[](1);
        umaNumbers[0] = 7_654_321;
        uint16[] memory umaMultipliers = new uint16[](1);
        umaMultipliers[0] = 1;
        bytes memory umaData = abi.encode(uint40(1), umaNumbers, umaMultipliers);
        IUnifiedLedgerV4.PurchaseRequestV4 memory umaRequest =
            _request(address(umaRounds), UNIT, umaData, bytes32(0), bytes32(0));
        vm.prank(user);
        ledger.executePurchaseV4(umaRequest, umaData);

        assertEq(ledger.balanceOf(user), 97 * UNIT);
        assertEq(ledger.balanceOf(address(lotto7Treasury)), UNIT);
        assertEq(ledger.balanceOf(address(lotto3dTreasury)), UNIT);
        assertEq(ledger.balanceOf(address(umaTreasury)), UNIT);
        assertEq(lotto7.userBoughtCount(1, user), 1);
        assertEq(lotto3d.ticketsPerAddress(1, user), 1);
        assertEq(umaRounds.ticketsPerRound(1, user), 1);
        assertEq(ledger.purchaseNonces(user), 3);
        assertTrue(ledger.usedWfOrderIds(lotto7OrderId));
    }

    function test_RealGameReadsAllocationFromTreasury() public {
        uint32[] memory numbers = new uint32[](1);
        numbers[0] = 1_234_567;
        uint32[] memory multipliers = new uint32[](1);
        multipliers[0] = 1;
        bytes memory purchaseData = abi.encode(uint256(1), numbers, multipliers);
        IUnifiedLedgerV4.PurchaseRequestV4 memory request =
            _request(address(lotto7), UNIT, purchaseData, bytes32(0), bytes32(0));
        vm.prank(user);
        ledger.executePurchaseV4(request, purchaseData);

        IRevenueAllocationTreasury.RoundRevenueAllocation memory allocation_ = lotto7Treasury.roundRevenueAllocation(1);
        assertEq(allocation_.version, 1);
        assertEq(allocation_.partnerBps, 500);
        assertEq(ledger.balanceOf(user), 99 * UNIT);
        assertEq(ledger.balanceOf(address(lotto7Treasury)), UNIT);
        assertEq(lotto7.userBoughtCount(1, user), 1);
        assertEq(ledger.purchaseNonces(user), 1);
    }

    function test_SettlementUsesRoundSnapshotAfterRouterUpdate() public {
        uint32[] memory numbers = new uint32[](1);
        numbers[0] = 1_234_567;
        uint32[] memory multipliers = new uint32[](1);
        multipliers[0] = 10;
        bytes memory purchaseData = abi.encode(uint256(1), numbers, multipliers);
        IUnifiedLedgerV4.PurchaseRequestV4 memory request =
            _request(address(lotto7), 10 * UNIT, purchaseData, bytes32(0), bytes32(0));

        vm.prank(user);
        ledger.executePurchaseV4(request, purchaseData);

        vm.prank(admin);
        router.setRevenueAllocation(7000, 1000, 1000, 1000);
        vm.prank(admin);
        lotto7.settleDraw(1, 1_234_567);

        IRevenueAllocationTreasury.RoundRevenueAllocation memory round1 = lotto7Treasury.roundRevenueAllocation(1);
        IRevenueAllocationTreasury.RoundRevenueAllocation memory round2 = lotto7Treasury.roundRevenueAllocation(2);
        assertEq(round1.version, 1);
        assertEq(round1.prizeBps, 8000);
        assertEq(round2.version, 2);
        assertEq(round2.prizeBps, 7000);
        assertEq(lotto7Treasury.partnerReserveAccrued(), UNIT / 2);
        assertEq(lotto7Treasury.opsAccrued(), 3 * UNIT / 2);
        assertEq(lotto7Treasury.datDistributed(), 0);
    }
}
