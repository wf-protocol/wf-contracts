# WF Contracts

Core smart contracts for the decentralized lottery protocol.

The `v4` branch is a **fresh-deployment-only standalone V4 candidate**. It must
not be installed with `upgradeToAndCall` on existing V2/V3/inherited-V4 proxies:
Ledger and Treasury storage layouts changed. Existing deployed services are not
updated by this branch. See [deployment and integration notes](docs/STANDALONE_V4.md).

## Scope

- Independent UnifiedLedgerV4 and StablecoinReserve
- Protocol game registry and revenue routing
- Lotto3D game, treasury, and Chainlink VRF adapter
- World Lotto UMA rounds, treasury, settlement, and oracle adapter
- Accumulated Partner revenue accounting and Safe-controlled collection

Frontend applications, backend services, deployment records, private configuration, legacy game implementations, and disabled experimental markets are intentionally excluded.

## Build

```sh
git clone https://github.com/wf-protocol/wf-contracts.git
cd wf-contracts
git submodule update --init lib/forge-std lib/openzeppelin-contracts lib/openzeppelin-contracts-upgradeable
forge build
forge test
```

The project uses Solidity 0.8.24 and Foundry. Dependency revisions are pinned as Git submodules.

## Local Deployment

See [local deployment and transaction checks](docs/LOCAL_V4_TESTING.md). These
scripts only accept chain ID 31337, use public test keys, and mock external
randomness/arbitration. No paid RPC, POL, LINK, or mainnet credentials are needed.
