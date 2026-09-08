# Local V4 Deployment and Smoke Test

Requirements: Foundry (`forge`, `cast`, `anvil`), Solidity 0.8.24 and the pinned
submodules. Run commands from the contract repository. This deploys **only to a
new local chain**, never a Polygon RPC or fork. Keep Anvil bound to loopback.

## Build and Start

```sh
git submodule update --init lib/forge-std lib/openzeppelin-contracts lib/openzeppelin-contracts-upgradeable
forge build
forge test
mkdir -p deployments
anvil --host 127.0.0.1 --port 18545 --silent
```

Keep Anvil running and use a second terminal. The script uses deliberately public
test keys `1` and `2` and refuses chain IDs other than 31337. **Never send real
funds to these accounts or expose this test node publicly.** Funding below creates
local gas balance, not real ETH/POL:

```sh
cast rpc --rpc-url http://127.0.0.1:18545 anvil_setBalance 0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf 0x3635c9adc5dea00000
cast rpc --rpc-url http://127.0.0.1:18545 anvil_setBalance 0x2B5AD5c4795c026514f8317c7a215E218DcCD6cF 0x3635c9adc5dea00000
forge script script/LocalV4.s.sol:DeployLocalV4 --rpc-url http://127.0.0.1:18545 --broadcast --slow
```

Addresses are generated in ignored file `deployments/local-v4.json`. Transaction
receipts are under ignored `broadcast/LocalV4.s.sol/31337/`. The script deploys
Registry, Ledger, Reserve, mock six-decimal USDT, Router, DAT Vault, Lotto3D,
World Lotto UMA, their Treasuries, adapters and local oracle mocks. It also wires
roles and creates round 1 in each game.

The local admin EOA stands in for the Partner Payout Safe to exercise the
Treasury caller restriction. This does **not** test Safe multisignature approval.

## Execute Real Local Transactions

Run each phase once on a fresh deployment, in this order. Complete phase 0
before the round closes. After advancing time, run phase 1 within the 3D draw
window (three minutes). Anvil also advances with wall-clock time.

```sh
SMOKE_PHASE=0 forge script script/LocalV4.s.sol:SmokeLocalV4 --rpc-url http://127.0.0.1:18545 --broadcast --slow
cast rpc --rpc-url http://127.0.0.1:18545 evm_increaseTime 1021
cast rpc --rpc-url http://127.0.0.1:18545 evm_mine
SMOKE_PHASE=1 forge script script/LocalV4.s.sol:SmokeLocalV4 --rpc-url http://127.0.0.1:18545 --broadcast --slow
cast rpc --rpc-url http://127.0.0.1:18545 evm_increaseTime 7201
cast rpc --rpc-url http://127.0.0.1:18545 evm_mine
SMOKE_PHASE=2 forge script script/LocalV4.s.sol:SmokeLocalV4 --rpc-url http://127.0.0.1:18545 --broadcast --slow
```

| Phase | Checks |
| --- | --- |
| 0 | Signed Reserve deposit of 100 USDT, one 1-WUSD ticket per game, partner attribution, user WUSD = 98 |
| 1 | Request/store/finalize mocked 3D randomness (`123`), assert World result (`1234567`), claim 3D ticket |
| 2 | Finish two-hour mocked UMA liveness, settle World, collect both partner reserves, claim World, withdraw 10 USDT |

Final assertions: total WUSD liability is 90; the collection recipient receives
0.1 WUSD; each Treasury balance equals its accounted liabilities. Oracle bonds
are separately minted test tokens and never debited from user WUSD.

Mock VRF fulfillment and UMA dispute resolution are intentionally controllable
by tests. They provide no randomness security or economic arbitration guarantees.
Unit tests separately exercise invalid signatures, replay, callback authorization,
premature oracle settlement, dispute/retry, refund and payout accounting.

## Scope of Verification

This validates contract transactions, not the localhost frontend or remote
database. No frontend environment is switched and no Settlement/Market daemon
is started. The smoke scripts perform individual keeper operations explicitly.
See [service migration requirements](STANDALONE_V4.md) before connecting services.

Anvil state is ephemeral unless explicitly persisted. Resetting the node or
running a new deployment invalidates the previous local address manifest. These
scripts intentionally do not delete any node data or reset existing state.

Optional persistence: start Anvil with `--state deployments/local-anvil.json
--state-interval 30` in addition to the arguments above. This ignored generated
snapshot is local test data only; do not commit it. Do not replay phase 0 on a
snapshot that has already completed the smoke test.

## Verification Record: 2026-09-08

- Clean build: 67 tests passed, 0 failed; purchase-conservation fuzz test ran 256 cases.
- Final compiled implementation bytecode matched all ten deployed proxy targets
  after normalizing constructor immutables; all runtime sizes are below 24,576 bytes.
- 45 deployment/configuration transactions and 15 smoke transactions were
  confirmed successful by reading receipts from the local node.
- Reserve token balance and total WUSD liability both equal 90.000000.
- User ends with 88.650000 WUSD and 910.000000 mock USDT, starting with 1,000
  mock USDT, after depositing 100, buying two tickets, claiming both and withdrawing 10.
- Collection recipient holds 0.100000 WUSD; both uncollected partner reserves are zero.
- 3D Treasury balance/liabilities both equal 0.700000; World Treasury both equal 0.550000.
- `forge fmt --check` and `git diff --check` pass. Compiler lint warnings about
  timestamps and numeric casts remain; passing tests is not a full security audit.
