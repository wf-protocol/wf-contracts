// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {MockUSDT} from "./mocks/MockUSDT.sol";
import {FeeOnTransferERC20} from "./mocks/FeeOnTransferERC20.sol";
import {IUnifiedLedgerV2} from "../src/wusd/IUnifiedLedgerV2.sol";
import {UnifiedLedgerV2} from "../src/wusd/UnifiedLedgerV2.sol";
import {StablecoinReserve} from "../src/wusd/StablecoinReserve.sol";

contract WusdLedgerV2Test is Test {
    UnifiedLedgerV2 internal ledger;
    StablecoinReserve internal reserve;
    MockUSDT internal usdt;
    MockUSDT internal usdc;

    uint256 internal signerPk = 0xA11CE;
    address internal signer;
    address internal admin = address(0xAD01);
    address internal user = address(0xBEEF);
    address internal user2 = address(0xCAFE);
    address internal game = address(0x600D);
    address internal treasury = address(0x700D);

    uint128 internal constant SINGLE_LIMIT = 10_000e6;
    uint128 internal constant DAILY_DEPOSIT_LIMIT = 100_000e6;
    uint128 internal constant DAILY_WITHDRAW_LIMIT = 100_000e6;

    bytes32 internal constant DEPOSIT_AUTH_TYPEHASH = keccak256(
        "DepositAuthorization(address user,address token,uint256 authorizedAmount,uint256 deadline,uint256 nonce)"
    );

    function setUp() public {
        vm.warp(1_800_000_000);
        signer = vm.addr(signerPk);

        UnifiedLedgerV2 ledgerImpl = new UnifiedLedgerV2();
        ledger = UnifiedLedgerV2(
            address(new ERC1967Proxy(address(ledgerImpl), abi.encodeCall(UnifiedLedgerV2.initialize, (admin))))
        );

        StablecoinReserve reserveImpl = new StablecoinReserve();
        reserve = StablecoinReserve(
            address(
                new ERC1967Proxy(
                    address(reserveImpl),
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
        reserve.addAsset(address(usdt), BPS(), SINGLE_LIMIT, DAILY_DEPOSIT_LIMIT, DAILY_WITHDRAW_LIMIT);
        reserve.addAsset(address(usdc), BPS(), SINGLE_LIMIT, DAILY_DEPOSIT_LIMIT, DAILY_WITHDRAW_LIMIT);
        vm.stopPrank();

        usdt.mint(user, 1_000_000e6);
        usdc.mint(user, 1_000_000e6);
        usdt.mint(user2, 1_000_000e6);
        usdc.mint(user2, 1_000_000e6);

        vm.prank(user);
        usdt.approve(address(reserve), type(uint256).max);
        vm.prank(user);
        usdc.approve(address(reserve), type(uint256).max);
        vm.prank(user2);
        usdt.approve(address(reserve), type(uint256).max);
        vm.prank(user2);
        usdc.approve(address(reserve), type(uint256).max);
    }

    function BPS() internal pure returns (uint16) {
        return 10_000;
    }

    function _sign(address account, address token, uint256 authorizedAmount, uint256 deadline, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash =
            keccak256(abi.encode(DEPOSIT_AUTH_TYPEHASH, account, token, authorizedAmount, deadline, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", reserve.domainSeparatorV4(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _deposit(address account, address token, uint256 amount, uint256 nonce)
        internal
        returns (uint256 credited)
    {
        uint256 deadline = block.timestamp + 15 minutes;
        bytes memory signature = _sign(account, token, amount, deadline, nonce);
        vm.prank(account);
        (, credited) = reserve.deposit(token, amount, amount, amount, deadline, nonce, signature);
    }

    function test_USDTAndUSDCAggregateIntoOneWusdBalance() public {
        _deposit(user, address(usdt), 40e6, 1);
        _deposit(user, address(usdc), 60e6, 2);

        assertEq(ledger.balanceOf(user), 100e6);
        assertEq(ledger.totalWusdLiability(), 100e6);
        assertEq(reserve.accountedReserve(address(usdt)), 40e6);
        assertEq(reserve.accountedReserve(address(usdc)), 60e6);
        assertEq(reserve.totalRecognizedReserve(), 100e6);
        assertTrue(reserve.isSolvent());
    }

    function test_GameSpendsUnifiedBalanceRegardlessOfDepositAsset() public {
        _deposit(user, address(usdt), 99e6, 1);

        vm.prank(admin);
        ledger.registerOperator(game);
        vm.prank(user);
        ledger.approveOperator(game, 10e6);

        vm.prank(game);
        ledger.operatorTransfer(user, treasury, 1e6);

        assertEq(ledger.balanceOf(user), 98e6);
        assertEq(ledger.balanceOf(treasury), 1e6);
        assertEq(ledger.operatorAllowances(user, game), 9e6);
        assertEq(ledger.totalWusdLiability(), 99e6);
    }

    function test_DirectGameTransferNeedsNoUserApproval() public {
        _deposit(user, address(usdt), 10e6, 1);

        vm.startPrank(admin);
        ledger.registerOperator(game);
        ledger.setDirectOperator(game, true);
        vm.stopPrank();

        vm.prank(game);
        ledger.directOperatorTransfer(user, treasury, 1e6);

        assertEq(ledger.balanceOf(user), 9e6);
        assertEq(ledger.balanceOf(treasury), 1e6);
        assertEq(ledger.operatorAllowances(user, game), 0);
    }

    function test_OrdinaryOperatorCannotUseDirectTransfer() public {
        _deposit(user, address(usdt), 10e6, 1);
        vm.prank(admin);
        ledger.registerOperator(game);

        vm.prank(game);
        vm.expectRevert(UnifiedLedgerV2.DirectOperatorNotEnabled.selector);
        ledger.directOperatorTransfer(user, treasury, 1e6);
    }

    function test_UserCanWithdrawDifferentHealthyReserveAsset() public {
        _deposit(user, address(usdt), 40e6, 1);
        _deposit(user2, address(usdc), 50e6, 1);

        uint256 beforeUsdc = usdc.balanceOf(user);
        vm.prank(user);
        reserve.withdraw(address(usdc), 20e6, 20e6, user);

        assertEq(usdc.balanceOf(user) - beforeUsdc, 20e6);
        assertEq(ledger.balanceOf(user), 20e6);
        assertEq(ledger.balanceOf(user2), 50e6);
        assertEq(ledger.totalWusdLiability(), 70e6);
        assertEq(reserve.totalRecognizedReserve(), 70e6);
        assertTrue(reserve.isSolvent());
    }

    function test_DirectReserveDonationActsAsUnencumberedWithdrawalLiquidity() public {
        _deposit(user, address(usdt), 20e6, 1);

        usdc.mint(address(reserve), 20e6);
        assertEq(reserve.accountedReserve(address(usdc)), 0);
        assertEq(reserve.totalRecognizedReserve(), 40e6);

        uint256 before = usdc.balanceOf(user);
        vm.prank(user);
        reserve.withdraw(address(usdc), 20e6, 20e6, user);

        assertEq(usdc.balanceOf(user) - before, 20e6);
        assertEq(ledger.totalWusdLiability(), 0);
        assertEq(reserve.totalRecognizedReserve(), 20e6);
        assertTrue(reserve.isSolvent());
    }

    function test_WithdrawRemainsAvailableWhenDepositsAndGamesPaused() public {
        _deposit(user, address(usdt), 25e6, 1);

        vm.prank(admin);
        ledger.pause();
        vm.prank(admin);
        reserve.pauseDeposits();

        uint256 before = usdt.balanceOf(user);
        vm.prank(user);
        reserve.withdraw(address(usdt), 10e6, 10e6, user);

        assertEq(usdt.balanceOf(user) - before, 10e6);
        assertEq(ledger.balanceOf(user), 15e6);
        assertEq(ledger.totalWusdLiability(), 15e6);
    }

    function test_FeeOnTransferWithdrawalUsesActualRecipientAmount() public {
        FeeOnTransferERC20 feeToken = new FeeOnTransferERC20();
        vm.prank(admin);
        reserve.addAsset(address(feeToken), BPS(), SINGLE_LIMIT, DAILY_DEPOSIT_LIMIT, DAILY_WITHDRAW_LIMIT);

        feeToken.mint(user, 100e6);
        vm.prank(user);
        feeToken.approve(address(reserve), type(uint256).max);
        _deposit(user, address(feeToken), 100e6, 9);

        feeToken.setFeeBps(100);
        uint256 liabilityBefore = ledger.totalWusdLiability();
        vm.prank(user);
        vm.expectRevert(StablecoinReserve.SlippageExceeded.selector);
        reserve.withdraw(address(feeToken), 10e6, 10e6, user);
        assertEq(ledger.totalWusdLiability(), liabilityBefore);

        uint256 before = feeToken.balanceOf(user);
        vm.prank(user);
        uint256 received = reserve.withdraw(address(feeToken), 10e6, 9.9e6, user);

        assertEq(received, 9.9e6);
        assertEq(feeToken.balanceOf(user) - before, 9.9e6);
        assertEq(ledger.balanceOf(user), 90e6);
        assertEq(ledger.totalWusdLiability(), liabilityBefore - 10e6);
        assertEq(reserve.accountedReserve(address(feeToken)), 90e6);
    }

    function test_PausedLedgerRejectsGameTransfer() public {
        _deposit(user, address(usdt), 10e6, 1);
        vm.prank(admin);
        ledger.registerOperator(game);
        vm.prank(user);
        ledger.approveOperator(game, 10e6);
        vm.prank(admin);
        ledger.pause();

        vm.prank(game);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        ledger.operatorTransfer(user, treasury, 1e6);
    }

    function test_ReserveRoleIsOnlyLiabilityCreationPath() public {
        vm.prank(user);
        vm.expectRevert();
        ledger.creditFromReserve(user, 1e6);

        assertEq(ledger.balanceOf(user), 0);
        assertEq(ledger.totalWusdLiability(), 0);
    }

    function test_DepositAuthorizationCannotBeReplayed() public {
        uint256 deadline = block.timestamp + 15 minutes;
        bytes memory signature = _sign(user, address(usdt), 10e6, deadline, 7);

        vm.prank(user);
        reserve.deposit(address(usdt), 10e6, 10e6, 10e6, deadline, 7, signature);

        vm.prank(user);
        vm.expectRevert(StablecoinReserve.NonceAlreadyUsed.selector);
        reserve.deposit(address(usdt), 10e6, 10e6, 10e6, deadline, 7, signature);
    }

    function test_RiskRateCreditsHaircutAndRedeemsAtSameRate() public {
        vm.prank(admin);
        reserve.setAssetRisk(address(usdt), 9_000, SINGLE_LIMIT, DAILY_DEPOSIT_LIMIT, DAILY_WITHDRAW_LIMIT);

        uint256 deadline = block.timestamp + 15 minutes;
        bytes memory signature = _sign(user, address(usdt), 100e6, deadline, 1);
        vm.prank(user);
        reserve.deposit(address(usdt), 100e6, 100e6, 90e6, deadline, 1, signature);

        assertEq(ledger.balanceOf(user), 90e6);
        assertEq(reserve.totalRecognizedReserve(), 90e6);

        uint256 before = usdt.balanceOf(user);
        vm.prank(user);
        reserve.withdraw(address(usdt), 90e6, 100e6, user);

        assertEq(usdt.balanceOf(user) - before, 100e6);
        assertEq(ledger.totalWusdLiability(), 0);
        assertEq(reserve.totalRecognizedReserve(), 0);
    }

    function testFuzz_InternalTransfersPreserveTotalLiability(uint96 rawDeposit, uint96 rawSpend) public {
        uint256 depositAmount = bound(uint256(rawDeposit), 1e6, SINGLE_LIMIT);
        uint256 spendAmount = bound(uint256(rawSpend), 1, depositAmount);
        _deposit(user, address(usdt), depositAmount, 1);

        vm.prank(admin);
        ledger.registerOperator(game);
        vm.prank(user);
        ledger.approveOperator(game, spendAmount);

        uint256 liabilityBefore = ledger.totalWusdLiability();
        vm.prank(game);
        ledger.operatorTransfer(user, treasury, spendAmount);

        assertEq(ledger.totalWusdLiability(), liabilityBefore);
        assertEq(ledger.balanceOf(user) + ledger.balanceOf(treasury), liabilityBefore);
        assertGe(reserve.totalRecognizedReserve(), ledger.totalWusdLiability());
    }
}
