// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {GameRegistry} from "../src/protocol/GameRegistry.sol";
import {IGameRegistry} from "../src/protocol/IGameRegistry.sol";
import {IUnifiedLedgerV2} from "../src/wusd/IUnifiedLedgerV2.sol";
import {IUnifiedLedgerV3} from "../src/wusd/IUnifiedLedgerV3.sol";
import {UnifiedLedgerV2} from "../src/wusd/UnifiedLedgerV2.sol";
import {UnifiedLedgerV3} from "../src/wusd/UnifiedLedgerV3.sol";

import {ILotto3DGame} from "../src/games/lotto3d/interfaces/ILotto3DGame.sol";
import {ILottoRounds} from "../src/games/lotto7uma/interfaces/ILottoRounds.sol";
import {WusdLotto3DGame} from "../src/games/wusd/lotto3d/WusdLotto3DGame.sol";
import {WusdLotto3DTreasury} from "../src/games/wusd/lotto3d/WusdLotto3DTreasury.sol";
import {WusdLotto7Game} from "../src/games/wusd/lotto7/WusdLotto7Game.sol";
import {WusdLotto7Treasury} from "../src/games/wusd/lotto7/WusdLotto7Treasury.sol";
import {WusdLottoRounds} from "../src/games/wusd/lotto7uma/WusdLottoRounds.sol";
import {WusdLottoTreasury} from "../src/games/wusd/lotto7uma/WusdLottoTreasury.sol";

contract WusdNativeGamesV3Test is Test {
    uint256 internal constant UNIT = 1e6;

    address internal admin = address(0xAD01);
    address internal user = address(0xBEEF);
    address internal beneficiary = address(0xCAFE);
    address internal ops = address(0x0A05);
    address internal dividend = address(0xD1A1);
    address internal fund = address(0xF00D);

    GameRegistry internal registry;
    UnifiedLedgerV3 internal ledger;
    WusdLotto7Game internal lotto7;
    WusdLotto3DGame internal lotto3d;
    WusdLottoRounds internal uma;
    WusdLotto7Treasury internal lotto7Treasury;
    WusdLotto3DTreasury internal lotto3dTreasury;
    WusdLottoTreasury internal umaTreasury;

    function setUp() public {
        vm.warp(1_800_000_000);
        registry = GameRegistry(
            address(new ERC1967Proxy(address(new GameRegistry()), abi.encodeCall(GameRegistry.initialize, (admin))))
        );
        ledger = UnifiedLedgerV3(
            address(
                new ERC1967Proxy(address(new UnifiedLedgerV3()), abi.encodeCall(UnifiedLedgerV2.initialize, (admin)))
            )
        );
        vm.prank(admin);
        ledger.initializeV3(IGameRegistry(address(registry)));

        _deployGames();
        _configureProtocol();
        _createRounds();

        vm.startPrank(admin);
        ledger.grantRole(ledger.RESERVE_ROLE(), admin);
        ledger.creditFromReserve(user, 100 * UNIT);
        vm.stopPrank();
    }

    function _deployGames() internal {
        lotto7Treasury = WusdLotto7Treasury(
            address(
                new ERC1967Proxy(
                    address(new WusdLotto7Treasury()),
                    abi.encodeCall(
                        WusdLotto7Treasury.initialize, (admin, IUnifiedLedgerV2(address(ledger)), ops, dividend)
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
                        (admin, IUnifiedLedgerV2(address(ledger)), UNIT, ops, dividend, fund)
                    )
                )
            )
        );
        uma = WusdLottoRounds(
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
        registry.registerGame(
            address(lotto7),
            address(lotto7Treasury),
            address(0),
            lotto7.protocolImplementationHash(),
            keccak256("lotto7-rules"),
            true,
            true
        );
        registry.registerGame(
            address(lotto3d),
            address(lotto3dTreasury),
            address(0),
            lotto3d.protocolImplementationHash(),
            keccak256("lotto3d-rules"),
            true,
            true
        );
        registry.registerGame(
            address(uma),
            address(umaTreasury),
            address(0),
            uma.protocolImplementationHash(),
            keccak256("lotto7-uma-rules"),
            true,
            true
        );

        ledger.registerOperator(address(lotto7Treasury));
        ledger.registerOperator(address(lotto3dTreasury));
        ledger.registerOperator(address(umaTreasury));

        lotto7Treasury.grantRole(lotto7Treasury.GAME_ROLE(), address(lotto7));
        lotto3dTreasury.grantRole(lotto3dTreasury.GAME_ROLE(), address(lotto3d));
        umaTreasury.grantRole(umaTreasury.ROUNDS_ROLE(), address(uma));
        lotto7Treasury.syncLedgerAllowance();
        lotto3dTreasury.syncLedgerAllowance();
        umaTreasury.syncLedgerAllowance();
        vm.stopPrank();
    }

    function _createRounds() internal {
        vm.prank(admin);
        lotto3d.createRound(
            1,
            ILotto3DGame.RoundConfig({
                salesOpenTime: uint64(block.timestamp),
                salesCloseTime: uint64(block.timestamp + 10 minutes),
                drawDeadline: uint64(block.timestamp + 20 minutes)
            })
        );
        vm.prank(admin);
        uma.createRound(
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
    }

    function _request(address game, address receiver, uint256 amount, bytes memory data, uint256 nonce)
        internal
        view
        returns (IUnifiedLedgerV3.PurchaseRequest memory)
    {
        return IUnifiedLedgerV3.PurchaseRequest({
            game: game,
            beneficiary: receiver,
            amount: amount,
            purchaseDataHash: keccak256(data),
            nonce: nonce,
            deadline: uint48(block.timestamp + 5 minutes)
        });
    }

    function test_V3PurchasesAllNativeGamesWithoutLegacyDirectOperators() public {
        uint32[] memory lotto7Numbers = new uint32[](1);
        uint32[] memory lotto7Multipliers = new uint32[](1);
        lotto7Numbers[0] = 1_234_567;
        lotto7Multipliers[0] = 1;
        bytes memory lotto7Data = abi.encode(lotto7.currentRoundId(), lotto7Numbers, lotto7Multipliers);

        uint16[] memory lotto3dNumbers = new uint16[](1);
        lotto3dNumbers[0] = 123;
        bytes memory lotto3dData = abi.encode(uint40(1), lotto3dNumbers);

        uint32[] memory umaNumbers = new uint32[](1);
        uint16[] memory umaMultipliers = new uint16[](1);
        umaNumbers[0] = 7_654_321;
        umaMultipliers[0] = 1;
        bytes memory umaData = abi.encode(uint40(1), umaNumbers, umaMultipliers);

        assertEq(lotto7.quotePurchase(user, user, lotto7Data), UNIT);
        assertEq(lotto3d.quotePurchase(user, user, lotto3dData), UNIT);
        assertEq(uma.quotePurchase(user, user, umaData), UNIT);

        vm.startPrank(user);
        ledger.executePurchase(_request(address(lotto7), user, UNIT, lotto7Data, 0), lotto7Data);
        ledger.executePurchase(_request(address(lotto3d), user, UNIT, lotto3dData, 1), lotto3dData);
        ledger.executePurchase(_request(address(uma), user, UNIT, umaData, 2), umaData);
        vm.stopPrank();

        assertEq(ledger.balanceOf(user), 97 * UNIT);
        assertEq(ledger.balanceOf(address(lotto7Treasury)), UNIT);
        assertEq(ledger.balanceOf(address(lotto3dTreasury)), UNIT);
        assertEq(ledger.balanceOf(address(umaTreasury)), UNIT);
        assertEq(lotto7.userBoughtCount(1, user), 1);
        assertEq(lotto3d.ticketsPerAddress(1, user), 1);
        assertEq(uma.ticketsPerRound(1, user), 1);
    }

    function test_UmaGiftTicketRecordsActualPayerForRefund() public {
        uint32[] memory numbers = new uint32[](1);
        uint16[] memory multipliers = new uint16[](1);
        numbers[0] = 1_111_111;
        multipliers[0] = 2;
        bytes memory data = abi.encode(uint40(1), numbers, multipliers);

        vm.prank(user);
        ledger.executePurchase(_request(address(uma), beneficiary, 2 * UNIT, data, 0), data);

        ILottoRounds.TicketData memory ticket = uma.getTicket(1);
        assertEq(ticket.buyer, beneficiary);
        assertEq(ticket.payer, user);
        assertEq(ticket.paid, 2 * UNIT);
    }

    function test_DisablingLegacyTransferDoesNotAffectV3Purchase() public {
        vm.startPrank(admin);
        lotto7.disableLegacyPurchases();
        lotto3d.disableLegacyPurchases();
        uma.disableLegacyPurchases();
        ledger.disableLegacyDirectTransfers();
        vm.stopPrank();

        uint16[] memory numbers = new uint16[](1);
        numbers[0] = 456;
        bytes memory data = abi.encode(uint40(1), numbers);

        vm.prank(user);
        ledger.executePurchase(_request(address(lotto3d), user, UNIT, data, 0), data);
        assertEq(lotto3d.ticketsPerAddress(1, user), 1);
    }

    function test_FinalizedGamesRejectLegacyPurchaseEntrypoints() public {
        vm.startPrank(admin);
        lotto7.disableLegacyPurchases();
        lotto3d.disableLegacyPurchases();
        uma.disableLegacyPurchases();
        vm.stopPrank();

        uint32[] memory lotto7Numbers = new uint32[](1);
        uint32[] memory lotto7Multipliers = new uint32[](1);
        lotto7Numbers[0] = 1_234_567;
        lotto7Multipliers[0] = 1;

        vm.startPrank(user);
        vm.expectRevert(WusdLotto7Game.LegacyPurchasesAreDisabled.selector);
        lotto7.buy(lotto7Numbers, lotto7Multipliers);

        vm.expectRevert(WusdLotto3DGame.LegacyPurchasesAreDisabled.selector);
        lotto3d.buy(1, 123);

        vm.expectRevert(WusdLottoRounds.LegacyPurchasesAreDisabled.selector);
        uma.buy(1, 1_234_567, 1);
        vm.stopPrank();
    }
}
