# WF Contracts

Core smart contracts for the decentralized lottery protocol.

## Scope

- UnifiedLedger V2/V3/V4 and StablecoinReserve
- Protocol game registry and revenue routing
- World Lotto and Lotto3D games, treasuries, and Chainlink VRF adapters
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
