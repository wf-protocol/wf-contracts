// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DatRevenueVault} from "../src/protocol/DatRevenueVault.sol";
import {ProtocolRevenueRouter} from "../src/protocol/ProtocolRevenueRouter.sol";
import {WusdLotto7Treasury} from "../src/games/wusd/lotto7/WusdLotto7Treasury.sol";
import {WusdLotto3DTreasury} from "../src/games/wusd/lotto3d/WusdLotto3DTreasury.sol";
import {WusdLottoTreasury} from "../src/games/wusd/lotto7uma/WusdLottoTreasury.sol";
import {UnifiedLedgerV2} from "../src/wusd/UnifiedLedgerV2.sol";

contract RevenueTreasuryTest is Test {
    uint256 internal constant UNIT = 1e6;
    address internal admin = address(0xA11CE);
    address internal datSafe = address(0xDA7);
    address internal partnerSafe = address(0xBEEF);
    address internal opsSafe = address(0x0F5);

    UnifiedLedgerV2 internal ledger;
    ProtocolRevenueRouter internal router;
    DatRevenueVault internal datVault;
    WusdLotto7Treasury internal lotto7;
    WusdLotto3DTreasury internal lotto3d;
    WusdLottoTreasury internal lottoUma;

    function setUp() public {
        ledger = UnifiedLedgerV2(
            address(
                new ERC1967Proxy(address(new UnifiedLedgerV2()), abi.encodeCall(UnifiedLedgerV2.initialize, (admin)))
            )
        );
        router = new ProtocolRevenueRouter(admin, 8000, 0, 500, 1500);
        datVault = new DatRevenueVault(admin, ledger, datSafe);
        lotto7 = WusdLotto7Treasury(
            address(
                new ERC1967Proxy(
                    address(new WusdLotto7Treasury()),
                    abi.encodeCall(WusdLotto7Treasury.initialize, (admin, ledger, opsSafe, partnerSafe))
                )
            )
        );
        lotto3d = WusdLotto3DTreasury(
            address(
                new ERC1967Proxy(
                    address(new WusdLotto3DTreasury()),
                    abi.encodeCall(WusdLotto3DTreasury.initialize, (admin, ledger, opsSafe))
                )
            )
        );
        lottoUma = WusdLottoTreasury(
            address(
                new ERC1967Proxy(
                    address(new WusdLottoTreasury()),
                    abi.encodeCall(WusdLottoTreasury.initialize, (admin, ledger, UNIT, opsSafe, partnerSafe, admin))
                )
            )
        );

        vm.startPrank(admin);
        lotto7.initializeRevenue(router, address(datVault), partnerSafe, opsSafe, admin);
        lotto3d.initializeRevenue(router, address(datVault), partnerSafe, opsSafe, admin);
        lottoUma.initializeRevenue(router, address(datVault), partnerSafe, opsSafe, admin);
        lotto7.grantRole(lotto7.GAME_ROLE(), address(this));
        lotto3d.grantRole(lotto3d.GAME_ROLE(), address(this));
        lottoUma.grantRole(lottoUma.ROUNDS_ROLE(), address(this));
        lottoUma.grantRole(lottoUma.SETTLEMENT_ROLE(), address(this));
        ledger.grantRole(ledger.RESERVE_ROLE(), admin);
        ledger.registerOperator(address(lotto7));
        ledger.registerOperator(address(lotto3d));
        ledger.registerOperator(address(lottoUma));
        ledger.creditFromReserve(address(lotto7), 200 * UNIT);
        ledger.creditFromReserve(address(lotto3d), 200 * UNIT);
        ledger.creditFromReserve(address(lottoUma), 200 * UNIT);
        lotto7.syncLedgerAllowance();
        lotto3d.syncLedgerAllowance();
        lottoUma.syncLedgerAllowance();
        vm.stopPrank();
    }

    function test_Lotto7UsesImmutableRoundSnapshotsAndTransfersDat() public {
        lotto7.snapshotRoundAllocation(1);
        vm.prank(admin);
        router.setRevenueAllocation(7500, 500, 500, 1500);
        lotto7.snapshotRoundAllocation(2);

        lotto7.collectSales(1, 100 * UNIT);
        lotto7.collectSales(2, 100 * UNIT);

        assertEq(lotto7.pendingPrize(), 155 * UNIT);
        assertEq(lotto7.partnerReserveAccrued(), 10 * UNIT);
        assertEq(lotto7.opsAccrued(), 30 * UNIT);
        assertEq(lotto7.datDistributed(), 5 * UNIT);
        assertEq(ledger.balanceOf(address(datVault)), 5 * UNIT);
        assertEq(lotto7.totalLiabilities(), 195 * UNIT);
    }

    function test_Lotto3dPreservesInternalPrizeRatioAndRoundIsolation() public {
        lotto3d.snapshotRoundAllocation(1);
        vm.prank(admin);
        router.setRevenueAllocation(7500, 500, 500, 1500);
        lotto3d.snapshotRoundAllocation(2);

        lotto3d.collectSales(1, 100 * UNIT);
        lotto3d.collectSales(2, 100 * UNIT);

        assertEq(lotto3d.roundBasePrize(1), 50 * UNIT);
        assertEq(lotto3d.roundBasePrize(2), 46_875_000);
        assertEq(lotto3d.pendingPrize(), 96_875_000);
        assertEq(lotto3d.accumulatedPool(), 58_125_000);
        assertEq(lotto3d.partnerReserveAccrued(), 10 * UNIT);
        assertEq(lotto3d.opsAccrued(), 30 * UNIT);
        assertEq(lotto3d.datDistributed(), 5 * UNIT);

        lotto3d.settleRoundPrize(1, false);
        assertEq(lotto3d.pendingPrize(), 46_875_000);
        assertEq(lotto3d.roundPrizePool(1), 50 * UNIT);
    }

    function test_PartnerSafeClaimsAccumulatedReserve() public {
        lotto7.snapshotRoundAllocation(1);
        lotto7.snapshotRoundAllocation(2);
        lotto7.collectSales(1, 100 * UNIT);
        lotto7.collectSales(2, 100 * UNIT);

        vm.prank(partnerSafe);
        lotto7.claimPartnerReserve(keccak256("collection-1"), keccak256("root-1"), 8 * UNIT);

        assertEq(lotto7.partnerReserveAccrued(), 2 * UNIT);
        assertEq(ledger.balanceOf(partnerSafe), 8 * UNIT);
        assertEq(ledger.balanceOf(opsSafe), 0);

        vm.prank(partnerSafe);
        vm.expectRevert(WusdLotto7Treasury.PartnerCollectionAlreadyProcessed.selector);
        lotto7.claimPartnerReserve(keccak256("collection-1"), keccak256("root-1"), 1);

        vm.prank(admin);
        vm.expectRevert(WusdLotto7Treasury.OnlyPartnerPayoutSafe.selector);
        lotto7.claimPartnerReserve(keccak256("collection-2"), keccak256("root-2"), 1);
    }

    function test_Lotto3dPartnerSafeClaimsAccumulatedReserve() public {
        lotto3d.snapshotRoundAllocation(1);
        lotto3d.collectSales(1, 200 * UNIT);

        vm.prank(partnerSafe);
        lotto3d.claimPartnerReserve(keccak256("collection-3d"), keccak256("root-3d"), 10 * UNIT);

        assertEq(lotto3d.partnerReserveAccrued(), 0);
        assertEq(ledger.balanceOf(partnerSafe), 10 * UNIT);
        assertEq(ledger.balanceOf(opsSafe), 0);
    }

    function test_UmaConvertsRefundReserveOnlyAfterFinalSettlement() public {
        lottoUma.snapshotRoundAllocation(1);
        lottoUma.reserveRefunds(100 * UNIT);
        assertEq(lottoUma.refundReserve(), 100 * UNIT);

        lottoUma.releaseRefundsForSettlement(100 * UNIT);
        lottoUma.reserveRoundPrizes(1, uint64(block.timestamp + 90 days), 80 * UNIT);
        uint256 prizeAmount = lottoUma.finalizeRoundRevenue(1, 100 * UNIT);

        assertEq(prizeAmount, 80 * UNIT);
        assertEq(lottoUma.refundReserve(), 0);
        assertEq(lottoUma.prizeReserve(), 80 * UNIT);
        assertEq(lottoUma.partnerReserveAccrued(), 5 * UNIT);
        assertEq(lottoUma.opsAccrued(), 15 * UNIT);
        assertEq(lottoUma.totalLiabilities(), 100 * UNIT);

        vm.prank(partnerSafe);
        lottoUma.claimPartnerReserve(keccak256("collection-uma"), keccak256("root-uma"), 5 * UNIT);

        assertEq(lottoUma.partnerReserveAccrued(), 0);
        assertEq(ledger.balanceOf(partnerSafe), 5 * UNIT);
        assertEq(ledger.balanceOf(opsSafe), 0);
    }
}
