# WF Contracts

Core smart contracts for WF Protocol.

## Scope

- WUSD ledger and stablecoin reserve
- Protocol game registry and revenue routing
- Lotto3D game, treasury, and VRF adapter
- World Lotto UMA rounds, treasury, settlement, and oracle adapter

Frontend applications, backend services, deployment records, private configuration, and unsupported games are intentionally excluded.

## Build

```sh
git clone https://github.com/wf-protocol/wf-contracts.git
cd wf-contracts
git submodule update --init lib/forge-std lib/openzeppelin-contracts lib/openzeppelin-contracts-upgradeable
forge build
forge test
```

The project uses Solidity 0.8.24 and Foundry. Dependency revisions are pinned as Git submodules.
