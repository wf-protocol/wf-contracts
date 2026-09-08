// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {WusdLedgerV4Test} from "./WusdLedgerV4.t.sol";
import {UnifiedLedgerV4} from "../src/wusd/UnifiedLedgerV4.sol";
import {IUnifiedLedgerV4} from "../src/wusd/IUnifiedLedgerV4.sol";
import {IGameRegistry} from "../src/protocol/IGameRegistry.sol";
import {MockERC1271Wallet} from "./mocks/MockERC1271Wallet.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract ReentrantFundingReceiver {
    function onProtocolFunding(address funder, uint256 amount, bytes calldata) external {
        UnifiedLedgerV4(msg.sender).protocolTransfer(funder, amount);
    }
}

contract V4LedgerSecurityTest is WusdLedgerV4Test {
    function test_FundingCallbackCannotReenterLedgerAndFailureRollsBack() public {
        ReentrantFundingReceiver receiver = new ReentrantFundingReceiver();
        vm.startPrank(admin);
        ledger.grantRole(ledger.PROTOCOL_ACCOUNT_ROLE(), address(receiver));
        vm.stopPrank();
        vm.prank(user);
        vm.expectRevert();
        ledger.fundProtocolAccount(address(receiver), UNIT, "");
        assertEq(ledger.balanceOf(user), 100 * UNIT);
        assertEq(ledger.balanceOf(address(receiver)), 0);
        assertEq(ledger.totalWusdLiability(), 100 * UNIT);
    }

    function test_ChangingLedgerInvalidatesSignature() public {
        UnifiedLedgerV4 other = UnifiedLedgerV4(
            address(
                new ERC1967Proxy(
                    address(new UnifiedLedgerV4()), abi.encodeCall(UnifiedLedgerV4.initialize, (admin, registry))
                )
            )
        );
        IUnifiedLedgerV4.PurchaseRequestV4 memory r = _request(0, 0, 0);
        bytes memory signature = _sign(r);
        vm.expectRevert(UnifiedLedgerV4.InvalidPurchaseSignature.selector);
        other.executePurchaseWithAuthorizationV4(r, abi.encode(2 * UNIT), signature);
    }

    function test_PurchaseNonceReplayRejected() public {
        IUnifiedLedgerV4.PurchaseRequestV4 memory r = _request(0, 0, 0);
        bytes memory sig = _sign(r);
        ledger.executePurchaseWithAuthorizationV4(r, abi.encode(2 * UNIT), sig);
        vm.expectRevert(UnifiedLedgerV4.InvalidPurchaseNonce.selector);
        ledger.executePurchaseWithAuthorizationV4(r, abi.encode(2 * UNIT), sig);
    }

    function test_ChangedPartnerInvalidatesSignature() public {
        IUnifiedLedgerV4.PurchaseRequestV4 memory r = _request(keccak256("order"), keccak256("partner"), 0);
        bytes memory sig = _sign(r);
        r.partnerCode = keccak256("attacker");
        vm.expectRevert(UnifiedLedgerV4.InvalidPurchaseSignature.selector);
        ledger.executePurchaseWithAuthorizationV4(r, abi.encode(2 * UNIT), sig);
    }

    function test_ChangedDataAndExpiredPurchaseRejected() public {
        IUnifiedLedgerV4.PurchaseRequestV4 memory r = _request(0, 0, 0);
        vm.prank(user);
        vm.expectRevert(UnifiedLedgerV4.PurchaseDataHashMismatch.selector);
        ledger.executePurchaseV4(r, abi.encode(3 * UNIT));
        vm.warp(r.deadline + 1);
        vm.prank(user);
        vm.expectRevert(UnifiedLedgerV4.PurchaseExpired.selector);
        ledger.executePurchaseV4(r, abi.encode(2 * UNIT));
    }

    function test_OnlyOwnerMayUseDirectPath() public {
        IUnifiedLedgerV4.PurchaseRequestV4 memory r = _request(0, 0, 0);
        vm.expectRevert(UnifiedLedgerV4.InvalidPurchase.selector);
        ledger.executePurchaseV4(r, abi.encode(2 * UNIT));
        assertEq(ledger.balanceOf(user), 100 * UNIT);
    }

    function test_ERC1271AuthorizationWorks() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet(user);
        vm.prank(admin);
        ledger.creditFromReserve(address(wallet), 5 * UNIT);
        IUnifiedLedgerV4.PurchaseRequestV4 memory r = _request(0, 0, 0);
        r.owner = address(wallet);
        ledger.executePurchaseWithAuthorizationV4(r, abi.encode(2 * UNIT), _sign(r));
        assertEq(ledger.balanceOf(address(wallet)), 3 * UNIT);
    }

    function test_ChangingChainInvalidatesSignature() public {
        IUnifiedLedgerV4.PurchaseRequestV4 memory r = _request(0, 0, 0);
        bytes memory sig = _sign(r);
        vm.chainId(block.chainid + 1);
        vm.expectRevert(UnifiedLedgerV4.InvalidPurchaseSignature.selector);
        ledger.executePurchaseWithAuthorizationV4(r, abi.encode(2 * UNIT), sig);
    }

    function test_GameFailureRollsBackFundsNonceAndOrder() public {
        bytes32 order = keccak256("failed-order");
        IUnifiedLedgerV4.PurchaseRequestV4 memory r = _request(order, keccak256("partner"), 0);
        r.amount = UNIT;
        vm.prank(user);
        vm.expectRevert();
        ledger.executePurchaseV4(r, abi.encode(2 * UNIT));
        assertEq(ledger.balanceOf(user), 100 * UNIT);
        assertEq(ledger.balanceOf(address(treasury)), 0);
        assertEq(ledger.purchaseNonces(user), 0);
        assertFalse(ledger.usedWfOrderIds(order));
    }

    function test_SuspensionAndCodeDriftPreventPurchases() public {
        IUnifiedLedgerV4.PurchaseRequestV4 memory r = _request(0, 0, 0);
        vm.prank(admin);
        registry.suspendGame(address(game));
        vm.prank(user);
        vm.expectRevert(UnifiedLedgerV4.GameNotActive.selector);
        ledger.executePurchaseV4(r, abi.encode(2 * UNIT));
        vm.prank(admin);
        registry.setGameStatus(address(game), IGameRegistry.GameStatus.Active);
        vm.etch(address(game), hex"00");
        assertFalse(registry.isActive(address(game)));
        vm.prank(user);
        vm.expectRevert(UnifiedLedgerV4.GameNotActive.selector);
        ledger.executePurchaseV4(r, abi.encode(2 * UNIT));
    }

    function test_UserCanInvalidatePendingSignaturesWhilePaused() public {
        IUnifiedLedgerV4.PurchaseRequestV4 memory r = _request(0, 0, 0);
        bytes memory sig = _sign(r);
        vm.prank(admin);
        ledger.pause();
        vm.prank(user);
        ledger.invalidatePurchaseNonce(10);
        vm.prank(admin);
        ledger.unpause();
        vm.expectRevert(UnifiedLedgerV4.InvalidPurchaseNonce.selector);
        ledger.executePurchaseWithAuthorizationV4(r, abi.encode(2 * UNIT), sig);
    }

    function test_ProtocolRoleCanOnlySpendItsOwnBalance() public {
        vm.startPrank(admin);
        ledger.grantRole(ledger.PROTOCOL_ACCOUNT_ROLE(), address(treasury));
        ledger.creditFromReserve(address(treasury), UNIT);
        registry.suspendGame(address(game));
        vm.stopPrank();
        treasury.pay(ledger, beneficiary, UNIT);
        assertEq(ledger.balanceOf(beneficiary), UNIT);
        vm.expectRevert(UnifiedLedgerV4.InsufficientBalance.selector);
        treasury.pay(ledger, beneficiary, UNIT);
        assertEq(ledger.balanceOf(user), 100 * UNIT);
        vm.expectRevert();
        ledger.protocolTransfer(user, UNIT);
    }

    function test_OldSelectorsAndInitializersDoNotExist() public {
        bytes4[7] memory selectors = [
            bytes4(keccak256("approveOperator(address,uint256)")),
            bytes4(keccak256("operatorTransfer(address,address,uint256)")),
            bytes4(keccak256("directOperatorTransfer(address,address,uint256)")),
            bytes4(keccak256("executePurchase((address,address,uint256,bytes32,uint256,uint48),bytes)")),
            bytes4(keccak256("initializeV3(address)")),
            bytes4(keccak256("initializeV4()")),
            bytes4(keccak256("treasuryTransfer(address,uint256)"))
        ];
        for (uint256 i; i < selectors.length; ++i) {
            vm.prank(admin);
            (bool success,) = address(ledger).call(abi.encodePacked(selectors[i], new bytes(512)));
            assertFalse(success);
        }
    }

    function test_InitializationAndUpgradeAreRestricted() public {
        vm.expectRevert();
        ledger.initialize(user, registry);
        UnifiedLedgerV4 implementation = new UnifiedLedgerV4();
        vm.expectRevert();
        implementation.initialize(admin, registry);
        vm.expectRevert();
        ledger.upgradeToAndCall(address(implementation), "");
        vm.prank(admin);
        ledger.upgradeToAndCall(address(implementation), "");
        assertEq(ledger.balanceOf(user), 100 * UNIT);
        assertEq(ledger.totalWusdLiability(), 100 * UNIT);
    }

    function testFuzz_PurchaseConservesLiability(uint96 rawAmount) public {
        uint256 amount = bound(rawAmount, 1, 100 * UNIT);
        IUnifiedLedgerV4.PurchaseRequestV4 memory r = _request(0, 0, 0);
        r.amount = amount;
        r.purchaseDataHash = keccak256(abi.encode(amount));
        vm.prank(user);
        ledger.executePurchaseV4(r, abi.encode(amount));
        assertEq(ledger.balanceOf(user) + ledger.balanceOf(address(treasury)), ledger.totalWusdLiability());
        assertEq(ledger.totalWusdLiability(), 100 * UNIT);
    }
}
