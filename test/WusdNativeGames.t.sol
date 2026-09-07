// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MockUSDT} from "./mocks/MockUSDT.sol";
import {IUnifiedLedgerV2} from "../src/wusd/IUnifiedLedgerV2.sol";
import {UnifiedLedgerV2} from "../src/wusd/UnifiedLedgerV2.sol";
import {StablecoinReserve} from "../src/wusd/StablecoinReserve.sol";

import {ILotto3DGame} from "../src/games/lotto3d/interfaces/ILotto3DGame.sol";
import {ILotto7Game} from "../src/games/lotto7/interfaces/ILotto7Game.sol";
import {WusdLotto3DGame} from "../src/games/wusd/lotto3d/WusdLotto3DGame.sol";
import {WusdLotto3DTreasury} from "../src/games/wusd/lotto3d/WusdLotto3DTreasury.sol";

import {WusdLotto7Game} from "../src/games/wusd/lotto7/WusdLotto7Game.sol";
import {WusdLotto7Treasury} from "../src/games/wusd/lotto7/WusdLotto7Treasury.sol";
import {LegacyWusdLotto7Treasury} from "./mocks/LegacyWusdLotto7Treasury.sol";

import {ILottoRounds} from "../src/games/lotto7uma/interfaces/ILottoRounds.sol";
import {WusdLottoRounds} from "../src/games/wusd/lotto7uma/WusdLottoRounds.sol";
import {WusdLottoTreasury} from "../src/games/wusd/lotto7uma/WusdLottoTreasury.sol";

contract WusdNativeGamesTest is Test {
    uint256 internal constant UNIT = 1e6;
    uint128 internal constant LIMIT = 1_000_000e6;
    bytes32 internal constant DEPOSIT_AUTH_TYPEHASH = keccak256(
        "DepositAuthorization(address user,address token,uint256 authorizedAmount,uint256 deadline,uint256 nonce)"
    );

    uint256 internal signerPk = 0xA11CE;
    address internal signer;
    address internal admin = address(0xAD01);
    address internal user = address(0xBEEF);
    address internal ops = address(0x0A05);
    address internal dividend = address(0xD1A1);
    address internal fund = address(0xF00D);

    UnifiedLedgerV2 internal ledger;
    StablecoinReserve internal reserve;
    MockUSDT internal usdt;
    MockUSDT internal usdc;

    WusdLotto7Game internal lotto7;
    WusdLotto7Treasury internal lotto7Treasury;
    WusdLotto3DGame internal lotto3d;
    WusdLotto3DTreasury internal lotto3dTreasury;
    WusdLottoRounds internal umaRounds;
    WusdLottoTreasury internal umaTreasury;

    function setUp() public {
        vm.warp(1_800_000_000);
        signer = vm.addr(signerPk);

        ledger = UnifiedLedgerV2(
            address(
                new ERC1967Proxy(address(new UnifiedLedgerV2()), abi.encodeCall(UnifiedLedgerV2.initialize, (admin)))
            )
        );
        reserve = StablecoinReserve(
            address(
                new ERC1967Proxy(
                    address(new StablecoinReserve()),
                    abi.encodeCall(StablecoinReserve.initialize, (admin, IUnifiedLedgerV2(address(ledger)), signer))
                )
            )
        );

        bytes32 reserveRole = ledger.RESERVE_ROLE();
        vm.prank(admin);
        ledger.grantRole(reserveRole, address(reserve));

        usdt = new MockUSDT();
        usdc = new MockUSDT();
        vm.startPrank(admin);
        reserve.addAsset(address(usdt), 10_000, LIMIT, LIMIT, LIMIT);
        reserve.addAsset(address(usdc), 10_000, LIMIT, LIMIT, LIMIT);
        vm.stopPrank();

        usdt.mint(user, 1_000e6);
        usdc.mint(user, 1_000e6);
        vm.startPrank(user);
        usdt.approve(address(reserve), type(uint256).max);
        usdc.approve(address(reserve), type(uint256).max);
        vm.stopPrank();

        _deployNativeGames();
        _configureRolesAndAllowances();
    }

    function _deployNativeGames() internal {
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

    function _configureRolesAndAllowances() internal {
        vm.startPrank(admin);
        ledger.registerOperator(address(lotto7));
        ledger.registerOperator(address(lotto7Treasury));
        ledger.registerOperator(address(lotto3d));
        ledger.registerOperator(address(lotto3dTreasury));
        ledger.registerOperator(address(umaRounds));
        ledger.registerOperator(address(umaTreasury));
        ledger.setDirectOperator(address(lotto7), true);
        ledger.setDirectOperator(address(lotto3d), true);
        ledger.setDirectOperator(address(umaRounds), true);

        lotto7Treasury.grantRole(lotto7Treasury.GAME_ROLE(), address(lotto7));
        lotto3dTreasury.grantRole(lotto3dTreasury.GAME_ROLE(), address(lotto3d));
        lotto3d.grantRole(lotto3d.VRF_ROLE(), admin);
        umaTreasury.grantRole(umaTreasury.ROUNDS_ROLE(), address(umaRounds));
        lotto7Treasury.syncLedgerAllowance();
        lotto3dTreasury.syncLedgerAllowance();
        umaTreasury.syncLedgerAllowance();
        vm.stopPrank();
    }

    function _signDeposit(address token, uint256 amount, uint256 deadline, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(DEPOSIT_AUTH_TYPEHASH, user, token, amount, deadline, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", reserve.domainSeparatorV4(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _deposit(address token, uint256 amount, uint256 nonce) internal {
        uint256 deadline = block.timestamp + 15 minutes;
        bytes memory signature = _signDeposit(token, amount, deadline, nonce);
        vm.prank(user);
        reserve.deposit(token, amount, amount, amount, deadline, nonce, signature);
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
    }

    function test_USDTAndUSDCFundAllThreeNativeWusdGames() public {
        _deposit(address(usdt), 40e6, 1);
        _deposit(address(usdc), 60e6, 2);
        _createRounds();

        uint32[] memory lotto7Numbers = new uint32[](1);
        uint32[] memory lotto7Multipliers = new uint32[](1);
        lotto7Numbers[0] = 1_234_567;
        lotto7Multipliers[0] = 1;

        vm.startPrank(user);
        lotto7.buy(lotto7Numbers, lotto7Multipliers);
        lotto3d.buy(1, 123);
        umaRounds.buy(1, 7_654_321, 1);
        vm.stopPrank();

        assertEq(ledger.balanceOf(user), 97e6);
        assertEq(ledger.balanceOf(address(lotto7Treasury)), 1e6);
        assertEq(ledger.balanceOf(address(lotto3dTreasury)), 1e6);
        assertEq(ledger.balanceOf(address(umaTreasury)), 1e6);
        assertEq(ledger.totalWusdLiability(), 100e6);
        assertTrue(reserve.isSolvent());
    }

    function test_WusdUmaAllowsMoreThanTenTicketsPerWalletPerRound() public {
        _deposit(address(usdt), 100e6, 1);
        _createRounds();

        vm.startPrank(user);
        for (uint32 i = 0; i < 11; i++) {
            umaRounds.buy(1, 1_000_000 + i, 1);
        }
        vm.stopPrank();

        assertEq(umaRounds.ticketsPerRound(1, user), 11);
        assertEq(umaRounds.nextTicketId(), 11);
        assertEq(umaRounds.roundTicketCount(1), 11);
        assertEq(umaRounds.roundTicketIdAt(1, 10), 11);
        assertEq(ledger.balanceOf(user), 89e6);
        assertEq(ledger.balanceOf(address(umaTreasury)), 11e6);
        assertEq(ledger.totalWusdLiability(), 100e6);
        assertTrue(reserve.isSolvent());
    }

    function test_Lotto3DSettlesAndPaysClaimInWusd() public {
        _deposit(address(usdt), 40e6, 1);
        _deposit(address(usdc), 60e6, 2);
        _createRounds();

        vm.prank(user);
        lotto3d.buy(1, 123);

        vm.warp(block.timestamp + 10 minutes + 1);
        vm.prank(admin);
        lotto3d.settleDraw(1, 123);

        ILotto3DGame.RoundData memory round = lotto3d.getRound(1);
        assertEq(round.prizePool, 0.5e6);
        assertEq(round.prize1PerUnit, 0.25e6);

        vm.prank(user);
        lotto3d.claim(1);

        assertEq(ledger.balanceOf(user), 99.25e6);
        assertEq(ledger.balanceOf(address(lotto3dTreasury)), 0.75e6);
        assertEq(ledger.totalWusdLiability(), 100e6);
        assertTrue(reserve.isSolvent());
    }

    function test_Lotto3DCannotSettleBeforeSalesClose() public {
        _createRounds();

        vm.prank(admin);
        vm.expectRevert(WusdLotto3DGame.SalesNotClosed.selector);
        lotto3d.settleDraw(1, 123);
    }

    function test_Lotto3DNoWinnerRecyclesEntirePrizePool() public {
        _deposit(address(usdt), 10e6, 1);
        _createRounds();
        vm.prank(user);
        lotto3d.buy(1, 123);

        uint256 accumulatedBefore = lotto3dTreasury.accumulatedPool();
        vm.warp(block.timestamp + 10 minutes + 1);
        vm.prank(admin);
        lotto3d.settleDraw(1, 999);

        ILotto3DGame.RoundData memory round = lotto3d.getRound(1);
        assertEq(lotto3dTreasury.roundOutstandingLiability(1), 0);
        assertEq(lotto3dTreasury.accumulatedPool(), accumulatedBefore + 0.3e6 + round.prizePool);
        assertEq(lotto3dTreasury.totalLiabilities(), ledger.balanceOf(address(lotto3dTreasury)));
    }

    function test_Lotto3DRoundingDustIsRecycled() public {
        _deposit(address(usdt), 20e6, 1);
        _createRounds();
        uint16[] memory numbers = new uint16[](8);
        for (uint256 i = 0; i < 7; ++i) {
            numbers[i] = 123;
        }
        numbers[7] = 999;
        vm.prank(user);
        lotto3d.batchBuy(1, numbers);

        vm.warp(block.timestamp + 10 minutes + 1);
        vm.prank(admin);
        lotto3d.settleDraw(1, 123);

        ILotto3DGame.RoundData memory round = lotto3d.getRound(1);
        uint256 exactLiability = round.prize1PerUnit * 7;
        assertEq(round.prizePool, 4e6);
        assertEq(lotto3dTreasury.roundOutstandingLiability(1), exactLiability);
        assertEq(lotto3dTreasury.accumulatedPool(), 2.4e6 + round.prizePool - exactLiability);
        assertEq(lotto3dTreasury.totalLiabilities(), ledger.balanceOf(address(lotto3dTreasury)));
    }

    function test_Lotto3DExpiredWinnerLiabilityIsPermissionlesslyRecycled() public {
        _deposit(address(usdt), 10e6, 1);
        _createRounds();
        vm.prank(user);
        lotto3d.buy(1, 123);

        vm.warp(block.timestamp + 10 minutes + 1);
        vm.prank(admin);
        lotto3d.settleDraw(1, 123);
        uint256 outstanding = lotto3dTreasury.roundOutstandingLiability(1);
        uint256 accumulatedBefore = lotto3dTreasury.accumulatedPool();
        assertGt(outstanding, 0);

        vm.warp(lotto3d.roundClaimDeadline(1) + 1);
        vm.prank(address(0xCA11));
        uint256 recycled = lotto3d.expireRoundClaims(1);

        assertEq(recycled, outstanding);
        assertEq(lotto3dTreasury.roundOutstandingLiability(1), 0);
        assertEq(lotto3dTreasury.activeWinnerLiability(), 0);
        assertEq(lotto3dTreasury.accumulatedPool(), accumulatedBefore + outstanding);
    }

    function test_Lotto3DBatchBuyUsesOneLedgerTransfer() public {
        _deposit(address(usdt), 100e6, 1);
        _createRounds();

        uint16[] memory numbers = new uint16[](3);
        numbers[0] = 123;
        numbers[1] = 456;
        numbers[2] = 789;

        bytes32 transferTopic = keccak256("OperatorTransfer(address,address,address,uint256,uint256,uint256)");
        vm.recordLogs();
        vm.prank(user);
        lotto3d.batchBuy(1, numbers);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 transferCount;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(ledger) && logs[i].topics.length > 0 && logs[i].topics[0] == transferTopic) {
                transferCount++;
            }
        }

        assertEq(transferCount, 1);
        assertEq(ledger.balanceOf(user), 97e6);
        assertEq(ledger.balanceOf(address(lotto3dTreasury)), 3e6);
        ILotto3DGame.RoundData memory round = lotto3d.getRound(1);
        assertEq(round.totalTickets, 3);
        assertEq(lotto3d.ticketsPerAddress(1, user), 3);
        assertEq(ledger.totalWusdLiability(), 100e6);
        assertTrue(reserve.isSolvent());
    }

    function test_Lotto3DBatchClaimAggregatesTreasuryPayment() public {
        _deposit(address(usdt), 100e6, 1);
        _createRounds();

        uint16[] memory numbers = new uint16[](3);
        numbers[0] = 123;
        numbers[1] = 123;
        numbers[2] = 456;
        vm.prank(user);
        lotto3d.batchBuy(1, numbers);

        vm.warp(block.timestamp + 10 minutes + 1);
        vm.prank(admin);
        lotto3d.settleDraw(1, 123);

        uint256[] memory ticketIds = new uint256[](3);
        ticketIds[0] = 1;
        ticketIds[1] = 2;
        ticketIds[2] = 3;

        bytes32 transferTopic = keccak256("OperatorTransfer(address,address,address,uint256,uint256,uint256)");
        vm.recordLogs();
        vm.prank(user);
        lotto3d.batchClaim(ticketIds);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 transferCount;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(ledger) && logs[i].topics.length > 0 && logs[i].topics[0] == transferTopic) {
                transferCount++;
            }
        }

        // Both exact-match tickets share the 50% first-tier pool; the third
        // ticket is intentionally skipped without reverting.
        assertEq(transferCount, 1);
        assertEq(ledger.balanceOf(user), 97.75e6);
        assertEq(ledger.balanceOf(address(lotto3dTreasury)), 2.25e6);
        bool claimed1;
        bool claimed2;
        bool claimed3;
        (,,, claimed1,) = lotto3d.tickets(1);
        (,,, claimed2,) = lotto3d.tickets(2);
        (,,, claimed3,) = lotto3d.tickets(3);
        assertTrue(claimed1);
        assertTrue(claimed2);
        assertFalse(claimed3);
        assertEq(lotto3dTreasury.unclaimedPrize(), 0);
        assertEq(lotto3dTreasury.activeWinnerLiability(), 0);
        assertEq(lotto3dTreasury.totalLiabilities(), ledger.balanceOf(address(lotto3dTreasury)));
        assertEq(ledger.totalWusdLiability(), 100e6);
        assertTrue(reserve.isSolvent());
    }

    function test_Lotto7StartsAndAdvancesOnTenMinuteBoundaries() public {
        ILotto7Game.Round memory first = lotto7.getRound(1);
        assertEq(first.startTime % 10 minutes, 0);
        assertEq(first.betCloseTime, first.startTime + 7 minutes);
        assertEq(first.endTime, first.startTime + 10 minutes);

        bytes32 gameRole = lotto7.GAME_ROLE();
        vm.prank(admin);
        lotto7.grantRole(gameRole, admin);

        vm.warp(first.betCloseTime + 1);
        vm.prank(admin);
        lotto7.settleDraw(1, 1_234_567);

        ILotto7Game.Round memory second = lotto7.getRound(2);
        assertEq(second.startTime, first.endTime);
        assertEq(second.startTime % 10 minutes, 0);
        assertEq(second.betCloseTime, second.startTime + 7 minutes);
        assertEq(second.endTime, second.startTime + 10 minutes);
    }

    function test_Lotto7LateSettlementWaitsForNextFullBoundary() public {
        ILotto7Game.Round memory first = lotto7.getRound(1);

        bytes32 gameRole = lotto7.GAME_ROLE();
        vm.prank(admin);
        lotto7.grantRole(gameRole, admin);

        vm.warp(first.endTime + 61);
        vm.prank(admin);
        lotto7.settleDraw(1, 7_654_321);

        ILotto7Game.Round memory second = lotto7.getRound(2);
        assertEq(second.startTime % 10 minutes, 0);
        assertGt(second.startTime, block.timestamp);
        assertEq(second.startTime - first.endTime, 10 minutes);
    }

    function test_Lotto7NoWinnerRebalancesSharedCarryIntoThreePools() public {
        _deposit(address(usdt), 10e6, 1);
        _enableLotto7Settlement();
        _buyLotto7(1_234_567, 1);

        ILotto7Game.Round memory round = lotto7.getRound(1);
        vm.warp(round.betCloseTime + 1);
        vm.prank(admin);
        lotto7.settleDraw(1, 9_999_999);

        assertEq(lotto7Treasury.jackpot1(), 0.4e6);
        assertEq(lotto7Treasury.jackpot2(), 0.24e6);
        assertEq(lotto7Treasury.jackpot3(), 0.16e6);
        assertEq(lotto7Treasury.sharedCarryPool(), 0);
        assertEq(lotto7Treasury.activeWinnerLiability(), 0);
        assertEq(lotto7Treasury.totalLiabilities(), ledger.balanceOf(address(lotto7Treasury)));
    }

    function test_Lotto7ClaimRecyclesLowerTierReserveIntoSharedCarry() public {
        _deposit(address(usdt), 10e6, 1);
        _enableLotto7Settlement();
        _buyLotto7(1_234_567, 1);

        ILotto7Game.Round memory round = lotto7.getRound(1);
        vm.warp(round.betCloseTime + 1);
        vm.prank(admin);
        lotto7.settleDraw(1, 1_234_567);

        uint256 liabilityBefore = lotto7Treasury.activeWinnerLiability();
        assertGt(liabilityBefore, 0);

        vm.prank(user);
        lotto7.claim(1, 0);

        assertEq(lotto7Treasury.activeWinnerLiability(), 0);
        assertGt(lotto7Treasury.sharedCarryPool(), 0);
        assertEq(lotto7Treasury.totalLiabilities(), ledger.balanceOf(address(lotto7Treasury)));

        uint256 carryBefore = lotto7Treasury.jackpot1() + lotto7Treasury.jackpot2() + lotto7Treasury.jackpot3()
            + lotto7Treasury.sharedCarryPool();
        ILotto7Game.Round memory nextRound = lotto7.getRound(2);
        vm.warp(nextRound.betCloseTime + 1);
        vm.prank(admin);
        lotto7.settleDraw(2, 9_999_999);

        assertEq(
            lotto7Treasury.jackpot1() + lotto7Treasury.jackpot2() + lotto7Treasury.jackpot3()
                + lotto7Treasury.sharedCarryPool(),
            carryBefore
        );
        assertApproxEqAbs(lotto7Treasury.jackpot1(), carryBefore / 2, 1);
        assertApproxEqAbs(lotto7Treasury.jackpot2(), (carryBefore * 3) / 10, 1);
        assertApproxEqAbs(lotto7Treasury.jackpot3(), carryBefore / 5, 1);
    }

    function test_Lotto7ExpiredClaimsReturnOutstandingLiabilityToSharedCarry() public {
        _deposit(address(usdt), 10e6, 1);
        _enableLotto7Settlement();
        _buyLotto7(1_234_567, 1);

        ILotto7Game.Round memory round = lotto7.getRound(1);
        vm.warp(round.betCloseTime + 1);
        vm.prank(admin);
        lotto7.settleDraw(1, 1_234_567);

        uint256 outstanding = lotto7Treasury.activeWinnerLiability();
        uint256 sharedBefore = lotto7Treasury.sharedCarryPool();
        uint256 deadline = lotto7.roundClaimDeadline(1);
        vm.warp(deadline + 1);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(WusdLotto7Game.PrizeClaimExpired.selector, 1));
        lotto7.claim(1, 0);

        uint256 recycled = lotto7.expireRoundClaims(1);
        assertEq(recycled, outstanding);
        assertEq(lotto7Treasury.activeWinnerLiability(), 0);
        assertEq(lotto7Treasury.sharedCarryPool(), sharedBefore + outstanding);
        assertEq(lotto7Treasury.totalLiabilities(), ledger.balanceOf(address(lotto7Treasury)));
    }

    function test_Lotto7OpsCannotClaimProtectedPrizePools() public {
        _deposit(address(usdt), 10e6, 1);
        _enableLotto7Settlement();
        _buyLotto7(1_234_567, 1);

        ILotto7Game.Round memory round = lotto7.getRound(1);
        vm.warp(round.betCloseTime + 1);
        vm.prank(admin);
        lotto7.settleDraw(1, 9_999_999);

        vm.prank(ops);
        lotto7Treasury.claimOps();

        assertEq(ledger.balanceOf(ops), 0.15e6);
        assertEq(lotto7Treasury.opsAccrued(), 0);
        assertEq(lotto7Treasury.totalLiabilities(), ledger.balanceOf(address(lotto7Treasury)));
    }

    function test_Lotto7ClaimPeriodIsSnapshottedWhenRoundStarts() public {
        _enableLotto7Settlement();
        ILotto7Game.Round memory first = lotto7.getRound(1);

        vm.startPrank(admin);
        lotto7.pause();
        lotto7.setClaimPeriod(uint64(30 days));
        lotto7.unpause();
        vm.stopPrank();

        vm.warp(first.betCloseTime + 1);
        uint256 settledAt = block.timestamp;
        vm.prank(admin);
        lotto7.settleDraw(1, 9_999_999);

        assertEq(lotto7.roundClaimDeadline(1), settledAt + 90 days);
        assertEq(lotto7.roundClaimPeriodSnapshot(2), 30 days);
    }

    function test_Lotto7TreasuryUpgradePreservesStorageAndRequiresLegacyReconciliation() public {
        _deposit(address(usdt), 10e6, 1);
        LegacyWusdLotto7Treasury legacy = LegacyWusdLotto7Treasury(
            address(
                new ERC1967Proxy(
                    address(new LegacyWusdLotto7Treasury()),
                    abi.encodeCall(LegacyWusdLotto7Treasury.initialize, (admin, IUnifiedLedgerV2(address(ledger))))
                )
            )
        );

        vm.prank(admin);
        legacy.seedLegacyAccounting(8e6, 1.5e6, 0.9e6, 0.6e6, 1e6, 1e6);
        vm.startPrank(admin);
        ledger.registerOperator(address(this));
        ledger.setDirectOperator(address(this), true);
        vm.stopPrank();
        ledger.directOperatorTransfer(user, address(legacy), 10e6);

        WusdLotto7Treasury implementation = new WusdLotto7Treasury();
        vm.prank(admin);
        legacy.upgradeToAndCall(address(implementation), bytes(""));
        WusdLotto7Treasury upgraded = WusdLotto7Treasury(address(legacy));

        assertFalse(upgraded.legacyAccountingReconciled());
        assertEq(upgraded.unclaimedPrize(), 8e6);
        assertEq(upgraded.jackpot1(), 1.5e6);
        assertEq(upgraded.jackpot2(), 0.9e6);
        assertEq(upgraded.jackpot3(), 0.6e6);

        vm.prank(admin);
        upgraded.reconcileLegacyAccounting(5e6, 0);

        assertTrue(upgraded.legacyAccountingReconciled());
        assertEq(upgraded.unclaimedPrize(), 5e6);
        assertEq(upgraded.totalLiabilities(), 10e6);
        assertEq(upgraded.totalLiabilities(), ledger.balanceOf(address(upgraded)));
    }

    function _enableLotto7Settlement() internal {
        bytes32 gameRole = lotto7.GAME_ROLE();
        vm.prank(admin);
        lotto7.grantRole(gameRole, admin);
    }

    function _buyLotto7(uint32 number, uint32 multiplier) internal {
        uint32[] memory numbers = new uint32[](1);
        uint32[] memory multipliers = new uint32[](1);
        numbers[0] = number;
        multipliers[0] = multiplier;
        vm.prank(user);
        lotto7.buy(numbers, multipliers);
    }
}
