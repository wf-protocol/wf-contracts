// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GameRegistry} from "../src/protocol/GameRegistry.sol";
import {IGameRegistry} from "../src/protocol/IGameRegistry.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DatRevenueVault} from "../src/protocol/DatRevenueVault.sol";
import {IProtocolRevenueRouter} from "../src/protocol/IProtocolRevenueRouter.sol";
import {ProtocolRevenueRouter} from "../src/protocol/ProtocolRevenueRouter.sol";
import {UnifiedLedgerV4} from "../src/wusd/UnifiedLedgerV4.sol";

contract RevenueAllocationTest is Test {
    uint256 internal constant UNIT = 1e6;
    address internal governance = address(0xA11CE);
    address internal datSafe = address(0xDA7);
    address internal nextDatSafe = address(0xDA8);
    address internal stranger = address(0xBAD);

    ProtocolRevenueRouter internal router;
    UnifiedLedgerV4 internal ledger;
    DatRevenueVault internal vault;

    function setUp() public {
        router = new ProtocolRevenueRouter(governance, 8000, 0, 500, 1500);
        ledger = UnifiedLedgerV4(
            address(
                new ERC1967Proxy(
                    address(new UnifiedLedgerV4()),
                    abi.encodeCall(UnifiedLedgerV4.initialize, (governance, IGameRegistry(address(new GameRegistry()))))
                )
            )
        );
        vault = new DatRevenueVault(governance, ledger, datSafe);

        vm.startPrank(governance);
        ledger.grantRole(ledger.RESERVE_ROLE(), governance);
        ledger.grantRole(ledger.PROTOCOL_ACCOUNT_ROLE(), address(vault));
        ledger.creditFromReserve(address(vault), 100 * UNIT);
        vm.stopPrank();
    }

    function test_InitialAndUpdatedAllocationsAreVersionedAndImmutable() public {
        IProtocolRevenueRouter.RevenueAllocation memory first = router.activeAllocation();
        assertEq(first.version, 1);
        assertEq(first.prizeBps, 8000);
        assertEq(first.datBps, 0);
        assertEq(first.partnerBps, 500);
        assertEq(first.opsBps, 1500);

        vm.prank(governance);
        uint32 version = router.setRevenueAllocation(7500, 500, 750, 1250);
        assertEq(version, 2);
        assertEq(router.activeVersion(), 2);

        IProtocolRevenueRouter.RevenueAllocation memory historical = router.allocation(1);
        assertEq(historical.prizeBps, 8000);
        assertEq(historical.datBps, 0);
    }

    function test_AllocationMustEqualOneHundredPercent() public {
        vm.prank(governance);
        vm.expectRevert(ProtocolRevenueRouter.InvalidAllocationTotal.selector);
        router.setRevenueAllocation(8000, 0, 500, 1499);
    }

    function test_OnlyGovernanceCanUpdateAllocation() public {
        vm.prank(stranger);
        vm.expectRevert();
        router.setRevenueAllocation(7500, 500, 750, 1250);
    }

    function test_DatSafeCanClaimAndAdminCannotSweep() public {
        vm.prank(governance);
        vm.expectRevert(DatRevenueVault.UnauthorizedBeneficiary.selector);
        vault.claim(UNIT);

        vm.prank(datSafe);
        vault.claim(40 * UNIT);
        assertEq(ledger.balanceOf(datSafe), 40 * UNIT);
        assertEq(ledger.balanceOf(address(vault)), 60 * UNIT);
    }

    function test_BeneficiaryChangeRequiresDatGovernanceAndNewSafe() public {
        vm.prank(datSafe);
        vault.proposeBeneficiary(nextDatSafe);

        vm.prank(nextDatSafe);
        vm.expectRevert(DatRevenueVault.InvalidBeneficiaryChange.selector);
        vault.acceptBeneficiary();

        vm.prank(governance);
        vault.approveBeneficiaryChange(nextDatSafe);

        vm.prank(nextDatSafe);
        vault.acceptBeneficiary();
        assertEq(vault.beneficiary(), nextDatSafe);

        vm.prank(nextDatSafe);
        vault.claimAll();
        assertEq(ledger.balanceOf(nextDatSafe), 100 * UNIT);
    }
}
