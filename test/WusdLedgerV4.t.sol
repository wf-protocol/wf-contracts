// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {GameRegistry} from "../src/protocol/GameRegistry.sol";
import {IGameRegistry} from "../src/protocol/IGameRegistry.sol";
import {IGameModuleV4} from "../src/protocol/IGameModuleV4.sol";
import {IUnifiedLedgerV4} from "../src/wusd/IUnifiedLedgerV4.sol";
import {UnifiedLedgerV2} from "../src/wusd/UnifiedLedgerV2.sol";
import {UnifiedLedgerV3} from "../src/wusd/UnifiedLedgerV3.sol";
import {UnifiedLedgerV4} from "../src/wusd/UnifiedLedgerV4.sol";
import {MockGameModuleV4} from "./mocks/MockGameModuleV4.sol";
import {MockOfficialTreasuryV3} from "./mocks/MockOfficialTreasuryV3.sol";

contract WusdLedgerV4Test is Test {
    uint256 internal constant UNIT = 1e6;
    uint256 internal userPk = 0xBEEF;
    address internal admin = address(0xAD01);
    address internal user;
    address internal beneficiary = address(0xB0B);
    address internal relayer = address(0x1E1A);

    GameRegistry internal registry;
    UnifiedLedgerV4 internal ledger;
    MockGameModuleV4 internal game;
    MockOfficialTreasuryV3 internal treasury;

    event PurchaseExecutedV4(
        bytes32 indexed receiptId,
        address indexed owner,
        address indexed game,
        address beneficiary,
        address treasury,
        uint256 amount,
        bytes32 purchaseDataHash,
        bytes32 wfOrderId,
        bytes32 partnerCode,
        uint32 allocationVersion,
        uint16 partnerBps,
        uint256 nonce,
        address submitter
    );

    function setUp() public {
        vm.warp(1_800_000_000);
        user = vm.addr(userPk);
        registry = GameRegistry(
            address(new ERC1967Proxy(address(new GameRegistry()), abi.encodeCall(GameRegistry.initialize, (admin))))
        );
        ledger = UnifiedLedgerV4(
            address(
                new ERC1967Proxy(address(new UnifiedLedgerV4()), abi.encodeCall(UnifiedLedgerV2.initialize, (admin)))
            )
        );
        vm.startPrank(admin);
        ledger.initializeV3(IGameRegistry(address(registry)));
        ledger.initializeV4();
        ledger.grantRole(ledger.RESERVE_ROLE(), admin);
        ledger.creditFromReserve(user, 100 * UNIT);
        vm.stopPrank();

        game = new MockGameModuleV4(address(ledger));
        treasury = new MockOfficialTreasuryV3();
        vm.prank(admin);
        registry.registerGame(
            address(game), address(treasury), address(0), address(game).codehash, keccak256("rules-v4"), true, true
        );
    }

    function _request(bytes32 wfOrderId, bytes32 partnerCode, uint256 nonce)
        internal
        view
        returns (IUnifiedLedgerV4.PurchaseRequestV4 memory)
    {
        bytes memory data = abi.encode(2 * UNIT);
        return IUnifiedLedgerV4.PurchaseRequestV4({
            owner: user,
            game: address(game),
            beneficiary: beneficiary,
            amount: 2 * UNIT,
            purchaseDataHash: keccak256(data),
            wfOrderId: wfOrderId,
            partnerCode: partnerCode,
            nonce: nonce,
            deadline: uint48(block.timestamp + 5 minutes)
        });
    }

    function _sign(IUnifiedLedgerV4.PurchaseRequestV4 memory request) internal view returns (bytes memory) {
        bytes32 digest = ledger.hashPurchaseAuthorizationV4(request);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_DirectPurchaseUsesGameAllocation() public {
        IUnifiedLedgerV4.PurchaseRequestV4 memory request = _request(bytes32(0), bytes32(0), 0);
        vm.prank(user);
        ledger.executePurchaseV4(request, abi.encode(2 * UNIT));

        assertEq(ledger.balanceOf(user), 98 * UNIT);
        assertEq(ledger.balanceOf(address(treasury)), 2 * UNIT);
        assertEq(game.purchaseCount(), 1);
    }

    function test_RelayedPartnerPurchaseConsumesUniqueOrderId() public {
        bytes32 orderId = keccak256("order-1");
        bytes32 partnerCode = keccak256("partner-a");
        IUnifiedLedgerV4.PurchaseRequestV4 memory request = _request(orderId, partnerCode, 0);

        vm.prank(relayer);
        ledger.executePurchaseWithAuthorizationV4(request, abi.encode(2 * UNIT), _sign(request));
        assertTrue(ledger.usedWfOrderIds(orderId));
        assertEq(game.lastWfOrderId(), orderId);
        assertEq(game.lastPartnerCode(), partnerCode);

        request.nonce = 1;
        bytes memory reusedOrderSignature = _sign(request);
        vm.prank(relayer);
        vm.expectRevert(UnifiedLedgerV4.WfOrderAlreadyUsed.selector);
        ledger.executePurchaseWithAuthorizationV4(request, abi.encode(2 * UNIT), reusedOrderSignature);
    }

    function test_RejectsPartialAttribution() public {
        IUnifiedLedgerV4.PurchaseRequestV4 memory request = _request(keccak256("order-1"), bytes32(0), 0);
        vm.prank(user);
        vm.expectRevert(UnifiedLedgerV4.InvalidAttribution.selector);
        ledger.executePurchaseV4(request, abi.encode(2 * UNIT));
    }

    function test_CallerCannotChooseRoundAllocation() public {
        IUnifiedLedgerV4.PurchaseRequestV4 memory request = _request(bytes32(0), bytes32(0), 0);
        game.setAllocation(7, 900);
        IGameModuleV4.PurchaseContext memory context =
            IGameModuleV4.PurchaseContext({wfOrderId: bytes32(0), partnerCode: bytes32(0)});
        bytes32 expectedReceipt = keccak256(abi.encode(user, beneficiary, 2 * UNIT, context, uint256(1)));

        vm.expectEmit(true, true, true, true, address(ledger));
        emit PurchaseExecutedV4(
            expectedReceipt,
            user,
            address(game),
            beneficiary,
            address(treasury),
            2 * UNIT,
            keccak256(abi.encode(2 * UNIT)),
            bytes32(0),
            bytes32(0),
            7,
            900,
            0,
            user
        );
        vm.prank(user);
        ledger.executePurchaseV4(request, abi.encode(2 * UNIT));

        assertEq(game.allocationVersion(), 7);
        assertEq(game.partnerBps(), 900);
        assertEq(ledger.balanceOf(user), 98 * UNIT);
        assertEq(ledger.purchaseNonces(user), 1);
    }

    function test_UpgradeFromV3PreservesBalancesRegistryAndNonces() public {
        UnifiedLedgerV3 ledgerV3 = UnifiedLedgerV3(
            address(
                new ERC1967Proxy(address(new UnifiedLedgerV3()), abi.encodeCall(UnifiedLedgerV2.initialize, (admin)))
            )
        );
        vm.startPrank(admin);
        ledgerV3.initializeV3(IGameRegistry(address(registry)));
        ledgerV3.grantRole(ledgerV3.RESERVE_ROLE(), admin);
        ledgerV3.creditFromReserve(user, 25 * UNIT);
        vm.stopPrank();
        vm.prank(user);
        ledgerV3.invalidatePurchaseNonce(7);

        UnifiedLedgerV4 implementation = new UnifiedLedgerV4();
        vm.prank(admin);
        ledgerV3.upgradeToAndCall(address(implementation), abi.encodeCall(UnifiedLedgerV4.initializeV4, ()));
        UnifiedLedgerV4 upgraded = UnifiedLedgerV4(address(ledgerV3));

        assertEq(upgraded.balanceOf(user), 25 * UNIT);
        assertEq(upgraded.totalWusdLiability(), 25 * UNIT);
        assertEq(address(upgraded.gameRegistry()), address(registry));
        assertEq(upgraded.purchaseNonces(user), 7);
        assertFalse(upgraded.usedWfOrderIds(keccak256("unused")));
    }
}
