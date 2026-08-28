// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {GameRegistry} from "../src/protocol/GameRegistry.sol";
import {IGameRegistry} from "../src/protocol/IGameRegistry.sol";
import {IUnifiedLedgerV3} from "../src/wusd/IUnifiedLedgerV3.sol";
import {UnifiedLedgerV2} from "../src/wusd/UnifiedLedgerV2.sol";
import {UnifiedLedgerV3} from "../src/wusd/UnifiedLedgerV3.sol";
import {MockERC1271Wallet} from "./mocks/MockERC1271Wallet.sol";
import {MockGameModuleV3} from "./mocks/MockGameModuleV3.sol";
import {MockOfficialTreasuryV3} from "./mocks/MockOfficialTreasuryV3.sol";

contract WusdLedgerV3Test is Test {
    uint256 internal constant UNIT = 1e6;
    uint256 internal userPk = 0xBEEF;
    uint256 internal walletOwnerPk = 0xCAFE;

    address internal admin = address(0xAD01);
    address internal user;
    address internal walletOwner;
    address internal beneficiary = address(0xB0B);
    address internal relayer = address(0x1E1A);

    GameRegistry internal registry;
    UnifiedLedgerV3 internal ledger;
    MockGameModuleV3 internal game;
    MockOfficialTreasuryV3 internal treasury;

    function setUp() public {
        vm.warp(1_800_000_000);
        user = vm.addr(userPk);
        walletOwner = vm.addr(walletOwnerPk);

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

        game = new MockGameModuleV3(address(ledger));
        treasury = new MockOfficialTreasuryV3();
        vm.prank(admin);
        registry.registerGame(
            address(game), address(treasury), address(0), address(game).codehash, keccak256("rules"), true, true
        );

        vm.startPrank(admin);
        ledger.grantRole(ledger.RESERVE_ROLE(), admin);
        ledger.creditFromReserve(user, 100 * UNIT);
        vm.stopPrank();
    }

    function _purchaseData(uint256 amount, bytes32 actionId) internal pure returns (bytes memory) {
        return abi.encode(amount, actionId);
    }

    function _request(address gameAddress, address receiver, uint256 amount, bytes memory data, uint256 nonce)
        internal
        view
        returns (IUnifiedLedgerV3.PurchaseRequest memory)
    {
        return IUnifiedLedgerV3.PurchaseRequest({
            game: gameAddress,
            beneficiary: receiver,
            amount: amount,
            purchaseDataHash: keccak256(data),
            nonce: nonce,
            deadline: uint48(block.timestamp + 5 minutes)
        });
    }

    function _sign(uint256 privateKey, address owner, IUnifiedLedgerV3.PurchaseRequest memory request)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = ledger.hashPurchaseAuthorization(owner, request);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_DirectPurchaseOnlyDebitsCaller() public {
        bytes memory data = _purchaseData(3 * UNIT, keccak256("direct"));
        IUnifiedLedgerV3.PurchaseRequest memory request = _request(address(game), beneficiary, 3 * UNIT, data, 0);

        vm.prank(user);
        bytes32 receiptId = ledger.executePurchase(request, data);

        assertNotEq(receiptId, bytes32(0));
        assertEq(ledger.balanceOf(user), 97 * UNIT);
        assertEq(ledger.balanceOf(address(treasury)), 3 * UNIT);
        assertEq(ledger.purchaseNonces(user), 1);
        assertEq(game.lastPayer(), user);
        assertEq(game.lastBeneficiary(), beneficiary);
    }

    function test_RelayerCanSubmitExactEoaAuthorization() public {
        bytes memory data = _purchaseData(4 * UNIT, keccak256("relayed"));
        IUnifiedLedgerV3.PurchaseRequest memory request = _request(address(game), user, 4 * UNIT, data, 0);
        bytes memory signature = _sign(userPk, user, request);

        vm.prank(relayer);
        ledger.executePurchaseWithAuthorization(user, request, data, signature);

        assertEq(ledger.balanceOf(user), 96 * UNIT);
        assertEq(ledger.balanceOf(address(treasury)), 4 * UNIT);
        assertEq(ledger.purchaseNonces(user), 1);
    }

    function test_RelayerSupportsErc1271Wallet() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet(walletOwner);
        vm.prank(admin);
        ledger.creditFromReserve(address(wallet), 20 * UNIT);

        bytes memory data = _purchaseData(5 * UNIT, keccak256("erc1271"));
        IUnifiedLedgerV3.PurchaseRequest memory request = _request(address(game), address(wallet), 5 * UNIT, data, 0);
        bytes memory signature = _sign(walletOwnerPk, address(wallet), request);

        vm.prank(relayer);
        ledger.executePurchaseWithAuthorization(address(wallet), request, data, signature);

        assertEq(ledger.balanceOf(address(wallet)), 15 * UNIT);
        assertEq(game.lastPayer(), address(wallet));
    }

    function test_ReplayIsRejected() public {
        bytes memory data = _purchaseData(UNIT, keccak256("replay"));
        IUnifiedLedgerV3.PurchaseRequest memory request = _request(address(game), user, UNIT, data, 0);
        bytes memory signature = _sign(userPk, user, request);

        vm.prank(relayer);
        ledger.executePurchaseWithAuthorization(user, request, data, signature);

        vm.prank(relayer);
        vm.expectRevert(UnifiedLedgerV3.InvalidPurchaseNonce.selector);
        ledger.executePurchaseWithAuthorization(user, request, data, signature);
    }

    function test_ChangedAmountInvalidatesAuthorization() public {
        bytes memory data = _purchaseData(UNIT, keccak256("changed"));
        IUnifiedLedgerV3.PurchaseRequest memory request = _request(address(game), user, UNIT, data, 0);
        bytes memory signature = _sign(userPk, user, request);
        request.amount = 2 * UNIT;

        vm.prank(relayer);
        vm.expectRevert(UnifiedLedgerV3.InvalidPurchaseSignature.selector);
        ledger.executePurchaseWithAuthorization(user, request, data, signature);
    }

    function test_ChangedPurchaseDataIsRejected() public {
        bytes memory data = _purchaseData(UNIT, keccak256("original"));
        bytes memory changedData = _purchaseData(UNIT, keccak256("changed"));
        IUnifiedLedgerV3.PurchaseRequest memory request = _request(address(game), user, UNIT, data, 0);

        vm.prank(user);
        vm.expectRevert(UnifiedLedgerV3.PurchaseDataHashMismatch.selector);
        ledger.executePurchase(request, changedData);
    }

    function test_SuspendedGameCannotSell() public {
        vm.prank(admin);
        registry.suspendGame(address(game));

        bytes memory data = _purchaseData(UNIT, keccak256("suspended"));
        IUnifiedLedgerV3.PurchaseRequest memory request = _request(address(game), user, UNIT, data, 0);

        vm.prank(user);
        vm.expectRevert(UnifiedLedgerV3.GameNotActive.selector);
        ledger.executePurchase(request, data);
    }

    function test_ImplementationDriftSuspendsAndRemovesReviewFlags() public {
        vm.etch(address(game), hex"00");

        IGameRegistry.GameConfig memory config = registry.getGameConfig(address(game));
        assertEq(uint256(config.status), uint256(IGameRegistry.GameStatus.Suspended));
        assertFalse(config.verified);
        assertFalse(config.sponsored);
        assertFalse(registry.isActive(address(game)));

        bytes memory data = _purchaseData(UNIT, keccak256("implementation-drift"));
        IUnifiedLedgerV3.PurchaseRequest memory request = _request(address(game), user, UNIT, data, 0);

        vm.prank(user);
        vm.expectRevert(UnifiedLedgerV3.GameNotActive.selector);
        ledger.executePurchase(request, data);
    }

    function test_GameFailureRollsBackBalanceAndNonce() public {
        game.setShouldRevert(true);
        bytes memory data = _purchaseData(2 * UNIT, keccak256("rollback"));
        IUnifiedLedgerV3.PurchaseRequest memory request = _request(address(game), user, 2 * UNIT, data, 0);

        vm.prank(user);
        vm.expectRevert(MockGameModuleV3.ForcedRevert.selector);
        ledger.executePurchase(request, data);

        assertEq(ledger.balanceOf(user), 100 * UNIT);
        assertEq(ledger.balanceOf(address(treasury)), 0);
        assertEq(ledger.purchaseNonces(user), 0);
    }

    function test_RegisteredGameCannotChooseAnotherPayer() public {
        bytes memory data = _purchaseData(UNIT, keccak256("caller-only"));
        IUnifiedLedgerV3.PurchaseRequest memory request = _request(address(game), beneficiary, UNIT, data, 0);

        vm.prank(address(game));
        vm.expectRevert(UnifiedLedgerV2.InsufficientBalance.selector);
        ledger.executePurchase(request, data);

        assertEq(ledger.balanceOf(user), 100 * UNIT);
    }

    function test_UserCanInvalidatePendingAuthorizations() public {
        vm.prank(user);
        ledger.invalidatePurchaseNonce(100);
        assertEq(ledger.purchaseNonces(user), 100);

        vm.prank(user);
        vm.expectRevert(UnifiedLedgerV3.InvalidPurchaseNonce.selector);
        ledger.invalidatePurchaseNonce(100);
    }

    function test_OnlyGovernanceCanRegisterOfficialGame() public {
        MockGameModuleV3 secondGame = new MockGameModuleV3(address(ledger));
        MockOfficialTreasuryV3 secondTreasury = new MockOfficialTreasuryV3();
        bytes32 managerRole = registry.REGISTRY_MANAGER_ROLE();
        bytes32 implementationHash = secondGame.protocolImplementationHash();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", user, managerRole));
        registry.registerGame(
            address(secondGame),
            address(secondTreasury),
            address(0),
            implementationHash,
            keccak256("official-rules"),
            true,
            true
        );
    }

    function test_RegistryRejectsEoaTreasury() public {
        MockGameModuleV3 secondGame = new MockGameModuleV3(address(ledger));
        address eoaTreasury = address(0x700D);
        bytes32 implementationHash = secondGame.protocolImplementationHash();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GameRegistry.NotAContract.selector, eoaTreasury));
        registry.registerGame(
            address(secondGame), eoaTreasury, address(0), implementationHash, keccak256("official-rules"), true, true
        );
    }

    function test_RegistryRejectsSharedTreasury() public {
        MockGameModuleV3 secondGame = new MockGameModuleV3(address(ledger));
        bytes32 implementationHash = secondGame.protocolImplementationHash();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GameRegistry.TreasuryAlreadyRegistered.selector, address(game)));
        registry.registerGame(
            address(secondGame),
            address(treasury),
            address(0),
            implementationHash,
            keccak256("official-rules"),
            true,
            true
        );
    }

    function test_OfficialTreasuryCanPayOnlyFromItsOwnBalanceAfterSuspension() public {
        bytes memory data = _purchaseData(3 * UNIT, keccak256("treasury-payout"));
        IUnifiedLedgerV3.PurchaseRequest memory request = _request(address(game), user, 3 * UNIT, data, 0);
        vm.prank(user);
        ledger.executePurchase(request, data);

        vm.prank(admin);
        registry.suspendGame(address(game));
        treasury.pay(ledger, beneficiary, 2 * UNIT);

        assertEq(ledger.balanceOf(address(treasury)), UNIT);
        assertEq(ledger.balanceOf(beneficiary), 2 * UNIT);

        vm.prank(user);
        vm.expectRevert(UnifiedLedgerV3.UnregisteredTreasury.selector);
        ledger.treasuryTransfer(beneficiary, UNIT);
    }

    function test_UpgradePreservesV2BalancesAndCanPermanentlyDisableLegacyPath() public {
        UnifiedLedgerV2 oldLedger = UnifiedLedgerV2(
            address(
                new ERC1967Proxy(address(new UnifiedLedgerV2()), abi.encodeCall(UnifiedLedgerV2.initialize, (admin)))
            )
        );
        vm.startPrank(admin);
        oldLedger.grantRole(oldLedger.RESERVE_ROLE(), admin);
        oldLedger.creditFromReserve(user, 9 * UNIT);
        oldLedger.registerOperator(address(game));
        oldLedger.setDirectOperator(address(game), true);
        oldLedger.upgradeToAndCall(
            address(new UnifiedLedgerV3()),
            abi.encodeCall(UnifiedLedgerV3.initializeV3, (IGameRegistry(address(registry))))
        );
        vm.stopPrank();

        UnifiedLedgerV3 upgraded = UnifiedLedgerV3(address(oldLedger));
        assertEq(upgraded.balanceOf(user), 9 * UNIT);
        assertEq(address(upgraded.gameRegistry()), address(registry));

        vm.prank(admin);
        upgraded.disableLegacyDirectTransfers();

        vm.prank(address(game));
        vm.expectRevert(UnifiedLedgerV3.LegacyDirectTransfersAreDisabled.selector);
        upgraded.directOperatorTransfer(user, address(treasury), UNIT);
    }
}
