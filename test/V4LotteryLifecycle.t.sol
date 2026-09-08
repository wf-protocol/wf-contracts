// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {WusdLotteryV4E2ETest} from "./WusdLotteryV4E2E.t.sol";
import {IUnifiedLedgerV4} from "../src/wusd/IUnifiedLedgerV4.sol";
import {ILottoRounds} from "../src/games/lotto7uma/interfaces/ILottoRounds.sol";
import {ILotto3DGame} from "../src/games/lotto3d/interfaces/ILotto3DGame.sol";
import {ILottoTreasury} from "../src/games/lotto7uma/interfaces/ILottoTreasury.sol";
import {LottoSettlement} from "../src/games/lotto7uma/LottoSettlement.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LottoOracleAdapter} from "../src/games/lotto7uma/LottoOracleAdapter.sol";
import {MockUmaOracle} from "./mocks/MockUmaOracle.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";

contract V4LotteryLifecycleTest is WusdLotteryV4E2ETest {
    function _oracle() internal returns (LottoOracleAdapter adapter, MockUmaOracle oracle, MockUSDT bond) {
        oracle = new MockUmaOracle();
        bond = new MockUSDT();
        adapter = LottoOracleAdapter(
            address(
                new ERC1967Proxy(
                    address(new LottoOracleAdapter()),
                    abi.encodeCall(
                        LottoOracleAdapter.initialize,
                        (admin, admin, ILottoRounds(address(umaRounds)), oracle, bond, UNIT, uint64(5 minutes))
                    )
                )
            )
        );
        vm.startPrank(admin);
        umaRounds.grantRole(umaRounds.ORACLE_ROLE(), address(adapter));
        vm.stopPrank();
        bond.mint(address(adapter), 10 * UNIT);
    }

    function _assertDraw(LottoOracleAdapter adapter) internal returns (bytes32) {
        vm.prank(admin);
        return adapter.assertDraw(1, 1_234_567, keccak256("sources"), keccak256("data"), "Test rules and evidence");
    }

    function test_UmaAdapterRequiresClosedSalesAndManager() public {
        (LottoOracleAdapter adapter, MockUmaOracle oracle, MockUSDT bond) = _oracle();
        vm.expectRevert();
        adapter.assertDraw(1, 1_234_567, keccak256("sources"), keccak256("data"), "Test");
        vm.expectRevert();
        _assertDraw(adapter);
        assertEq(oracle.nonce(), 0);
        assertEq(bond.balanceOf(address(adapter)), 10 * UNIT);
        assertEq(adapter.lockedBond(), 0);
    }

    function test_UmaAdapterRejectsEarlyAndForgedResolution() public {
        (LottoOracleAdapter adapter,, MockUSDT bond) = _oracle();
        vm.warp(block.timestamp + 10 minutes + 1);
        bytes32 id = _assertDraw(adapter);
        vm.expectRevert();
        adapter.settleAssertion(id);
        vm.expectRevert(LottoOracleAdapter.UnauthorizedCallbackCaller.selector);
        adapter.assertionResolvedCallback(id, true);
        vm.expectRevert(LottoOracleAdapter.UnauthorizedCallbackCaller.selector);
        adapter.assertionDisputedCallback(id);
        assertEq(adapter.lockedBond(), UNIT);
        vm.warp(block.timestamp + 5 minutes);
        assertTrue(adapter.settleAssertion(id));
        assertTrue(umaRounds.isRoundDrawn(1));
        assertEq(umaRounds.roundWinningNumber(1), 1_234_567);
        assertEq(adapter.lockedBond(), 0);
        assertEq(bond.balanceOf(address(adapter)), 10 * UNIT);
    }

    function test_UmaFalseDisputeCanRetryWithoutUnlockingSales() public {
        (LottoOracleAdapter adapter, MockUmaOracle oracle, MockUSDT bond) = _oracle();
        _buyUma(1_234_567, user, 1);
        vm.warp(block.timestamp + 10 minutes + 1);
        bytes32 id = _assertDraw(adapter);
        oracle.dispute(id);
        vm.warp(block.timestamp + 11 minutes);
        vm.expectRevert();
        adapter.settleAssertion(id);
        assertFalse(umaRounds.isRoundDrawn(1));
        oracle.resolveDispute(id, false);
        assertFalse(adapter.settleAssertion(id));
        assertEq(uint256(umaRounds.roundDrawStatus(1)), uint256(ILottoRounds.DrawStatus.ReadyForRetry));
        assertEq(adapter.lockedBond(), 0);
        assertTrue(umaRounds.getRound(1).salesClosed);
        bytes32 retry = _assertDraw(adapter);
        assertTrue(retry != id);
        vm.warp(block.timestamp + 5 minutes);
        assertTrue(adapter.settleAssertion(retry));
        assertTrue(umaRounds.isRoundDrawn(1));
        assertEq(bond.balanceOf(address(adapter)), 9 * UNIT);
    }

    function test_3dNoWinnerRecyclesEntirePrizeShare() public {
        _buy3d(123, 1);
        _draw3d(999);
        assertEq(lotto3dTreasury.activeWinnerLiability(), 0);
        assertEq(lotto3dTreasury.accumulatedPool(), 8 * UNIT / 10);
        assertEq(lotto3dTreasury.totalLiabilities(), UNIT);
    }

    function _buy3d(uint16 number, uint256 count) internal {
        uint16[] memory numbers = new uint16[](count);
        for (uint256 i; i < count; ++i) {
            numbers[i] = number;
        }
        bytes memory data = abi.encode(uint40(1), numbers);
        IUnifiedLedgerV4.PurchaseRequestV4 memory r = _request(address(lotto3d), count * UNIT, data, 0, 0);
        vm.prank(user);
        ledger.executePurchaseV4(r, data);
    }

    function _buyUma(uint32 number, address beneficiary, uint256 count) internal {
        uint32[] memory numbers = new uint32[](count);
        uint16[] memory multipliers = new uint16[](count);
        for (uint256 i; i < count; ++i) {
            numbers[i] = number;
            multipliers[i] = 1;
        }
        bytes memory data = abi.encode(uint40(1), numbers, multipliers);
        IUnifiedLedgerV4.PurchaseRequestV4 memory r = _request(address(umaRounds), count * UNIT, data, 0, 0);
        r.beneficiary = beneficiary;
        vm.prank(user);
        ledger.executePurchaseV4(r, data);
    }

    function _draw3d(uint16 number) internal {
        vm.warp(block.timestamp + 10 minutes + 1);
        vm.prank(admin);
        lotto3d.settleDraw(1, number);
    }

    function _settleUma(uint32 number) internal returns (LottoSettlement settlement) {
        settlement = LottoSettlement(
            address(
                new ERC1967Proxy(
                    address(new LottoSettlement()),
                    abi.encodeCall(
                        LottoSettlement.initialize,
                        (admin, ILottoRounds(address(umaRounds)), ILottoTreasury(address(umaTreasury)))
                    )
                )
            )
        );
        vm.startPrank(admin);
        umaRounds.grantRole(umaRounds.SETTLEMENT_ROLE(), address(settlement));
        umaRounds.grantRole(umaRounds.ORACLE_ROLE(), admin);
        umaTreasury.grantRole(umaTreasury.SETTLEMENT_ROLE(), address(settlement));
        vm.warp(block.timestamp + 10 minutes + 1);
        umaRounds.markDrawAssertionPending(1, keccak256("assertion"), keccak256("evidence"), number, keccak256("data"));
        umaRounds.submitDraw(1, number, keccak256("evidence"));
        vm.stopPrank();
        settlement.processSettlement(1, 100);
    }

    function test_3dSettlementClaimAndCollectionConserveFunds() public {
        _buy3d(123, 10);
        assertEq(lotto3dTreasury.refundReserve(), 10 * UNIT);
        assertEq(lotto3dTreasury.partnerReserveAccrued(), 0);
        _draw3d(123);
        assertEq(lotto3dTreasury.refundReserve(), 0);
        assertEq(lotto3dTreasury.partnerReserveAccrued(), UNIT / 2);
        uint256[] memory ids = new uint256[](10);
        for (uint256 i; i < 10; ++i) {
            ids[i] = i + 1;
        }
        vm.prank(user);
        lotto3d.batchClaim(ids);
        assertEq(ledger.balanceOf(user), 925 * UNIT / 10);
        vm.prank(user);
        vm.expectRevert();
        lotto3d.claim(1);
        bytes32 collection = keccak256("collection");
        bytes32 accounting = keccak256("accounting");
        vm.prank(user);
        vm.expectRevert();
        lotto3dTreasury.claimPartnerReserve(collection, accounting, UNIT / 2);
        vm.prank(partnerSafe);
        lotto3dTreasury.claimPartnerReserve(collection, accounting, UNIT / 2);
        vm.prank(partnerSafe);
        vm.expectRevert();
        lotto3dTreasury.claimPartnerReserve(collection, accounting, UNIT / 2);
        vm.prank(ops);
        lotto3dTreasury.claimOps();
        assertEq(lotto3dTreasury.totalLiabilities(), ledger.balanceOf(address(lotto3dTreasury)));
        assertEq(ledger.totalWusdLiability(), 100 * UNIT);
    }

    function test_3dCancelledRoundFullyRefundsAndCannotAccrueRevenue() public {
        _buy3d(123, 1);
        vm.prank(admin);
        lotto3d.cancelRound(1);
        lotto3d.refundTicket(1);
        assertEq(ledger.balanceOf(user), 100 * UNIT);
        assertEq(lotto3dTreasury.totalLiabilities(), 0);
        assertEq(lotto3dTreasury.partnerReserveAccrued(), 0);
        vm.expectRevert();
        lotto3d.refundTicket(1);
    }

    function test_3dExpiredPrizeReturnsToAccumulatedPool() public {
        _buy3d(123, 1);
        _draw3d(123);
        assertGt(lotto3dTreasury.activeWinnerLiability(), 0);
        vm.warp(lotto3d.roundClaimDeadline(1) + 1);
        lotto3d.expireRoundClaims(1);
        assertEq(lotto3dTreasury.activeWinnerLiability(), 0);
        assertEq(lotto3dTreasury.accumulatedPool(), 8 * UNIT / 10);
        vm.prank(user);
        vm.expectRevert();
        lotto3d.claim(1);
    }

    function test_AllocationUpdateOnlyAffectsNewRounds() public {
        _buy3d(123, 1);
        vm.prank(admin);
        router.setRevenueAllocation(7000, 1000, 1000, 1000);
        _draw3d(123);
        assertEq(lotto3dTreasury.datDistributed(), 0);
        vm.prank(admin);
        lotto3d.createRound(
            2,
            ILotto3DGame.RoundConfig(
                uint64(block.timestamp), uint64(block.timestamp + 60), uint64(block.timestamp + 120)
            )
        );
        assertEq(lotto3dTreasury.roundRevenueAllocation(1).version, 1);
        assertEq(lotto3dTreasury.roundRevenueAllocation(2).version, 2);
        uint16[] memory numbers = new uint16[](1);
        numbers[0] = 999;
        bytes memory data = abi.encode(uint40(2), numbers);
        IUnifiedLedgerV4.PurchaseRequestV4 memory r = _request(address(lotto3d), UNIT, data, 0, 0);
        vm.prank(user);
        ledger.executePurchaseV4(r, data);
        vm.warp(block.timestamp + 61);
        vm.prank(admin);
        lotto3d.settleDraw(2, 999);
        assertEq(ledger.balanceOf(address(datVault)), UNIT / 10);
        vm.prank(address(0xDA7A));
        datVault.claimAll();
        assertEq(ledger.balanceOf(address(0xDA7A)), UNIT / 10);
    }

    function test_FundingIsAtomicAndCannotDebitOtherUsers() public {
        vm.startPrank(admin);
        ledger.creditFromReserve(admin, 10 * UNIT);
        ledger.fundProtocolAccount(address(lotto3dTreasury), 3 * UNIT, "");
        ledger.fundProtocolAccount(address(umaTreasury), 4 * UNIT, abi.encode(uint8(1)));
        ledger.fundProtocolAccount(address(umaTreasury), 3 * UNIT, abi.encode(uint8(0)));
        vm.stopPrank();
        assertEq(lotto3dTreasury.accumulatedPool(), 3 * UNIT);
        assertEq(umaTreasury.carryPool(), 4 * UNIT);
        assertEq(umaTreasury.reserveBalance(), 3 * UNIT);
        vm.prank(user);
        vm.expectRevert();
        ledger.fundProtocolAccount(address(umaTreasury), UNIT, abi.encode(uint8(1)));
        assertEq(ledger.balanceOf(user), 100 * UNIT);
        vm.expectRevert();
        umaTreasury.onProtocolFunding(admin, 100 * UNIT, abi.encode(uint8(1)));
        vm.prank(admin);
        umaTreasury.withdrawReserve(admin, 3 * UNIT);
        assertEq(ledger.balanceOf(admin), 3 * UNIT);
        assertEq(umaTreasury.totalLiabilities(), ledger.balanceOf(address(umaTreasury)));
    }

    function test_UmaGiftRefundGoesToPayer() public {
        _buyUma(1_234_567, address(0xB0B), 1);
        vm.prank(admin);
        umaRounds.cancelRound(1);
        umaRounds.refundTicket(1);
        assertEq(ledger.balanceOf(user), 100 * UNIT);
        assertEq(ledger.balanceOf(address(0xB0B)), 0);
        assertEq(umaTreasury.partnerReserveAccrued(), 0);
    }

    function test_UmaSettlementAndClaimUseExclusiveHighestTier() public {
        _buyUma(1_234_567, user, 10);
        LottoSettlement settlement = _settleUma(1_234_567);
        settlement.postSettlement(1);
        LottoSettlement.RoundSettlement memory result = settlement.getRoundSettlement(1);
        assertEq(result.winUnits1, 10);
        assertEq(result.winUnits4, 0);
        assertEq(result.winUnits5, 0);
        vm.prank(user);
        settlement.claim(1);
        vm.prank(user);
        vm.expectRevert();
        settlement.claim(1);
        assertEq(ledger.balanceOf(user), 90 * UNIT + result.payout1);
        assertEq(umaTreasury.totalLiabilities(), ledger.balanceOf(address(umaTreasury)));
        vm.prank(partnerSafe);
        umaTreasury.claimPartnerReserve(keccak256("uma"), keccak256("root"), UNIT / 2);
        assertEq(ledger.balanceOf(partnerSafe), UNIT / 2);
    }

    function test_UmaSettlementMoreThan100TicketsRequiresBatches() public {
        vm.prank(admin);
        ledger.creditFromReserve(user, UNIT);
        _buyUma(1_234_567, user, 100);
        _buyUma(1_234_567, user, 1);
        LottoSettlement settlement = _settleUma(1_234_567);
        vm.expectRevert();
        settlement.postSettlement(1);
        settlement.processSettlement(1, 1);
        settlement.postSettlement(1);
        assertEq(settlement.getRoundSettlement(1).winUnits1, 101);
    }

    function test_FutureRoundCannotSellEarly() public {
        uint64 opens = uint64(block.timestamp + 1 days);
        vm.prank(admin);
        lotto3d.createRound(2, ILotto3DGame.RoundConfig(opens, opens + 17 minutes, opens + 20 minutes));
        uint16[] memory numbers = new uint16[](1);
        numbers[0] = 1;
        bytes memory data = abi.encode(uint40(2), numbers);
        IUnifiedLedgerV4.PurchaseRequestV4 memory r = _request(address(lotto3d), UNIT, data, 0, 0);
        vm.prank(user);
        vm.expectRevert();
        ledger.executePurchaseV4(r, data);
        assertEq(ledger.balanceOf(user), 100 * UNIT);
        assertEq(ledger.purchaseNonces(user), 0);
    }
}
