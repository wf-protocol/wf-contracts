// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UnifiedLedgerV4} from "../src/wusd/UnifiedLedgerV4.sol";
import {IUnifiedLedgerV4} from "../src/wusd/IUnifiedLedgerV4.sol";
import {StablecoinReserve} from "../src/wusd/StablecoinReserve.sol";
import {GameRegistry} from "../src/protocol/GameRegistry.sol";
import {IGameRegistry} from "../src/protocol/IGameRegistry.sol";
import {ProtocolRevenueRouter} from "../src/protocol/ProtocolRevenueRouter.sol";
import {DatRevenueVault} from "../src/protocol/DatRevenueVault.sol";
import {WusdLotto3DGame} from "../src/games/wusd/lotto3d/WusdLotto3DGame.sol";
import {WusdLotto3DTreasury} from "../src/games/wusd/lotto3d/WusdLotto3DTreasury.sol";
import {ILotto3DGame} from "../src/games/lotto3d/interfaces/ILotto3DGame.sol";
import {Lotto3DVRFAdapter} from "../src/games/lotto3d/Lotto3DVRFAdapter.sol";
import {WusdLottoRounds} from "../src/games/wusd/lotto7uma/WusdLottoRounds.sol";
import {WusdLottoTreasury} from "../src/games/wusd/lotto7uma/WusdLottoTreasury.sol";
import {ILottoRounds} from "../src/games/lotto7uma/interfaces/ILottoRounds.sol";
import {ILottoTreasury} from "../src/games/lotto7uma/interfaces/ILottoTreasury.sol";
import {LottoSettlement} from "../src/games/lotto7uma/LottoSettlement.sol";
import {LottoOracleAdapter} from "../src/games/lotto7uma/LottoOracleAdapter.sol";
import {MockUSDT} from "../test/mocks/MockUSDT.sol";
import {MockVRFCoordinatorV2Plus} from "../test/mocks/MockVRFCoordinatorV2Plus.sol";
import {MockUmaOracle} from "../test/mocks/MockUmaOracle.sol";

contract DeployLocalV4 is Script {
    // Public test keys, deliberately restricted to local chain 31337.
    function run() external {
        require(block.chainid == 31337, "Local chain only");
        address admin = vm.addr(1);
        vm.startBroadcast(1);
        GameRegistry registry = GameRegistry(
            address(new ERC1967Proxy(address(new GameRegistry()), abi.encodeCall(GameRegistry.initialize, (admin))))
        );
        UnifiedLedgerV4 ledger = UnifiedLedgerV4(
            address(
                new ERC1967Proxy(
                    address(new UnifiedLedgerV4()), abi.encodeCall(UnifiedLedgerV4.initialize, (admin, registry))
                )
            )
        );
        StablecoinReserve reserve = StablecoinReserve(
            address(
                new ERC1967Proxy(
                    address(new StablecoinReserve()),
                    abi.encodeCall(StablecoinReserve.initialize, (admin, ledger, admin))
                )
            )
        );
        MockUSDT token = new MockUSDT();
        ledger.grantRole(ledger.RESERVE_ROLE(), address(reserve));
        reserve.addAsset(address(token), 10_000, 100_000e6, 1_000_000e6, 1_000_000e6);
        token.mint(vm.addr(2), 1000e6);
        ProtocolRevenueRouter router = new ProtocolRevenueRouter(admin, 8000, 0, 500, 1500);
        DatRevenueVault dat = new DatRevenueVault(admin, ledger, admin);
        WusdLotto3DTreasury t3 = WusdLotto3DTreasury(
            address(
                new ERC1967Proxy(
                    address(new WusdLotto3DTreasury()),
                    abi.encodeCall(WusdLotto3DTreasury.initialize, (admin, ledger, admin))
                )
            )
        );
        WusdLotto3DGame g3 = WusdLotto3DGame(
            address(
                new ERC1967Proxy(
                    address(new WusdLotto3DGame()), abi.encodeCall(WusdLotto3DGame.initialize, (admin, ledger, t3, 1e6))
                )
            )
        );
        MockVRFCoordinatorV2Plus vrf = new MockVRFCoordinatorV2Plus();
        Lotto3DVRFAdapter adapter3 = Lotto3DVRFAdapter(
            address(
                new ERC1967Proxy(
                    address(new Lotto3DVRFAdapter()),
                    abi.encodeCall(
                        Lotto3DVRFAdapter.initialize,
                        (
                            admin,
                            ILotto3DGame(address(g3)),
                            Lotto3DVRFAdapter.VRFConfig(address(vrf), bytes32(uint256(1)), 1, 3, 2_000_000)
                        )
                    )
                )
            )
        );
        WusdLottoTreasury tu = WusdLottoTreasury(
            address(
                new ERC1967Proxy(
                    address(new WusdLottoTreasury()),
                    abi.encodeCall(WusdLottoTreasury.initialize, (admin, ledger, 1e6, admin, admin))
                )
            )
        );
        WusdLottoRounds gu = WusdLottoRounds(
            address(
                new ERC1967Proxy(
                    address(new WusdLottoRounds()),
                    abi.encodeCall(WusdLottoRounds.initialize, (admin, ledger, address(tu), 1e6))
                )
            )
        );
        LottoSettlement settlement = LottoSettlement(
            address(
                new ERC1967Proxy(
                    address(new LottoSettlement()),
                    abi.encodeCall(
                        LottoSettlement.initialize, (admin, ILottoRounds(address(gu)), ILottoTreasury(address(tu)))
                    )
                )
            )
        );
        MockUmaOracle oracle = new MockUmaOracle();
        LottoOracleAdapter adapterU = LottoOracleAdapter(
            address(
                new ERC1967Proxy(
                    address(new LottoOracleAdapter()),
                    abi.encodeCall(
                        LottoOracleAdapter.initialize,
                        (admin, admin, ILottoRounds(address(gu)), oracle, IERC20(address(token)), 1e6, uint64(2 hours))
                    )
                )
            )
        );
        token.mint(address(adapterU), 100e6);
        ledger.grantRole(ledger.PROTOCOL_ACCOUNT_ROLE(), address(t3));
        ledger.grantRole(ledger.PROTOCOL_ACCOUNT_ROLE(), address(tu));
        ledger.grantRole(ledger.PROTOCOL_ACCOUNT_ROLE(), address(dat));
        t3.grantRole(t3.GAME_ROLE(), address(g3));
        t3.initializeRevenue(router, address(dat), admin, admin, admin);
        g3.grantRole(g3.VRF_ROLE(), address(adapter3));
        adapter3.grantRole(adapter3.KEEPER_ROLE(), admin);
        tu.grantRole(tu.ROUNDS_ROLE(), address(gu));
        tu.grantRole(tu.SETTLEMENT_ROLE(), address(settlement));
        tu.initializeRevenue(router, address(dat), admin, admin, admin);
        gu.grantRole(gu.ORACLE_ROLE(), address(adapterU));
        gu.grantRole(gu.SETTLEMENT_ROLE(), address(settlement));
        registry.registerGame(
            address(g3),
            address(t3),
            address(adapter3),
            g3.protocolImplementationHash(),
            keccak256("local-3d-v4"),
            true,
            false
        );
        registry.registerGame(
            address(gu),
            address(tu),
            address(adapterU),
            gu.protocolImplementationHash(),
            keccak256("local-world-v4"),
            true,
            false
        );
        uint64 start = uint64(block.timestamp);
        g3.createRound(1, ILotto3DGame.RoundConfig(start, start + 17 minutes, start + 20 minutes));
        gu.createRound(
            1, ILottoRounds.RoundConfig(start, start + 17 minutes, start + 1 days, start + 100 days, 999, 2 hours)
        );
        vm.stopBroadcast();
        vm.serializeUint("local-v4", "chainId", block.chainid);
        vm.serializeAddress("local-v4", "ledger", address(ledger));
        vm.serializeAddress("local-v4", "reserve", address(reserve));
        vm.serializeAddress("local-v4", "token", address(token));
        vm.serializeAddress("local-v4", "registry", address(registry));
        vm.serializeAddress("local-v4", "router", address(router));
        vm.serializeAddress("local-v4", "datVault", address(dat));
        vm.serializeAddress("local-v4", "lotto3d", address(g3));
        vm.serializeAddress("local-v4", "lotto3dTreasury", address(t3));
        vm.serializeAddress("local-v4", "vrfAdapter", address(adapter3));
        vm.serializeAddress("local-v4", "vrf", address(vrf));
        vm.serializeAddress("local-v4", "world", address(gu));
        vm.serializeAddress("local-v4", "worldTreasury", address(tu));
        vm.serializeAddress("local-v4", "settlement", address(settlement));
        vm.serializeAddress("local-v4", "umaOracle", address(oracle));
        string memory json = vm.serializeAddress("local-v4", "umaAdapter", address(adapterU));
        vm.writeJson(json, "deployments/local-v4.json");
    }
}

contract SmokeLocalV4 is Script {
    function run() external {
        require(block.chainid == 31337, "Local chain only");
        string memory manifest = vm.readFile("deployments/local-v4.json");
        UnifiedLedgerV4 ledger = UnifiedLedgerV4(vm.parseJsonAddress(manifest, ".ledger"));
        StablecoinReserve reserve = StablecoinReserve(vm.parseJsonAddress(manifest, ".reserve"));
        MockUSDT token = MockUSDT(vm.parseJsonAddress(manifest, ".token"));
        WusdLotto3DGame g3 = WusdLotto3DGame(vm.parseJsonAddress(manifest, ".lotto3d"));
        WusdLottoRounds gu = WusdLottoRounds(vm.parseJsonAddress(manifest, ".world"));
        LottoOracleAdapter ua = LottoOracleAdapter(vm.parseJsonAddress(manifest, ".umaAdapter"));
        uint256 phase = vm.envUint("SMOKE_PHASE");
        if (phase == 0) {
            uint256 deadline = block.timestamp + 1 hours;
            bytes32 hash = keccak256(
                abi.encode(
                    keccak256(
                        "DepositAuthorization(address user,address token,uint256 authorizedAmount,uint256 deadline,uint256 nonce)"
                    ),
                    vm.addr(2),
                    token,
                    uint256(100e6),
                    deadline,
                    uint256(1)
                )
            );
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(1, keccak256(abi.encodePacked("\x19\x01", reserve.domainSeparatorV4(), hash)));
            vm.startBroadcast(2);
            token.approve(address(reserve), 100e6);
            reserve.deposit(address(token), 100e6, 100e6, 100e6, deadline, 1, abi.encodePacked(r, s, v));
            uint16[] memory n3 = new uint16[](1);
            n3[0] = 123;
            _buy(ledger, address(g3), abi.encode(uint40(1), n3));
            uint32[] memory nu = new uint32[](1);
            nu[0] = 1_234_567;
            uint16[] memory mu = new uint16[](1);
            mu[0] = 1;
            _buy(ledger, address(gu), abi.encode(uint40(1), nu, mu));
            vm.stopBroadcast();
            require(ledger.balanceOf(vm.addr(2)) == 98e6, "purchase balance");
        } else if (phase == 1) {
            vm.startBroadcast(1);
            Lotto3DVRFAdapter a3 = Lotto3DVRFAdapter(vm.parseJsonAddress(manifest, ".vrfAdapter"));
            uint256 request = a3.requestDraw(1);
            MockVRFCoordinatorV2Plus(vm.parseJsonAddress(manifest, ".vrf")).fulfillRandomWords(request, 123);
            a3.finalizeDraw(1);
            ua.assertDraw(1, 1_234_567, keccak256("local-evidence"), keccak256("local-data"), "Local V4 test only");
            vm.stopBroadcast();
            vm.startBroadcast(2);
            g3.claim(1);
            vm.stopBroadcast();
            require(g3.getRound(1).winningNumber == 123, "3d draw");
        } else {
            require(phase == 2, "invalid phase");
            vm.startBroadcast(1);
            ua.settleAssertion(gu.roundOracleAssertionId(1));
            LottoSettlement settlement = LottoSettlement(vm.parseJsonAddress(manifest, ".settlement"));
            settlement.postSettlement(1);
            WusdLotto3DTreasury t3 = WusdLotto3DTreasury(vm.parseJsonAddress(manifest, ".lotto3dTreasury"));
            WusdLottoTreasury tu = WusdLottoTreasury(vm.parseJsonAddress(manifest, ".worldTreasury"));
            t3.claimPartnerReserve(keccak256("local3d"), keccak256("root3d"), t3.partnerReserveAccrued());
            tu.claimPartnerReserve(keccak256("localuma"), keccak256("rootuma"), tu.partnerReserveAccrued());
            vm.stopBroadcast();
            vm.startBroadcast(2);
            settlement.claim(1);
            reserve.withdraw(address(token), 10e6, 10e6, vm.addr(2));
            vm.stopBroadcast();
            require(ledger.totalWusdLiability() == 90e6, "liability");
            require(ledger.balanceOf(vm.addr(1)) == 100_000, "commission");
            require(ledger.balanceOf(address(t3)) == t3.totalLiabilities(), "3d solvency");
            require(ledger.balanceOf(address(tu)) == tu.totalLiabilities(), "world solvency");
        }
    }

    function _buy(UnifiedLedgerV4 ledger, address game, bytes memory data) internal {
        uint256 nonce = ledger.purchaseNonces(vm.addr(2));
        ledger.executePurchaseV4(
            IUnifiedLedgerV4.PurchaseRequestV4(
                vm.addr(2),
                game,
                vm.addr(2),
                1e6,
                keccak256(data),
                keccak256(abi.encode("local-order", nonce)),
                keccak256("local-partner"),
                nonce,
                uint48(block.timestamp + 1 hours)
            ),
            data
        );
    }
}
