# Standalone V4

## Deployment Boundary

This branch removes the Ledger V2/V3 inheritance tree and their public purchase,
operator-allowance, migration, and activation entry points. Ordinary OpenZeppelin
inheritance remains. UMA Optimistic Oracle V3 and Chainlink VRF V2.5 names describe
external protocols, not Ledger compatibility, and must remain.

Fresh deployment is mandatory. **Do not upgrade existing proxies to this branch.**
Balances, nonces, ticket IDs, permissions and liabilities are not migrated. A
production launch requires an independently reviewed deployment and funding plan;
this local test does not move or retire any existing user balances or games.

Only Lotto3D and World Lotto UMA are active source targets. Unused Lotto7 VRF
contracts and legacy purchase tests are removed from this branch, recoverable
from Git history. Country order, replacements and evidence preparation remain
offchain; no new country-selection storage was added.

## Ledger Interfaces

| Function | Caller and effect |
| --- | --- |
| `initialize(admin, registry)` | Fresh proxy initialization; locks implementation initializer |
| `balanceOf`, `totalWusdLiability` | Read six-decimal WUSD accounting |
| `creditFromReserve`, `debitToReserve` | Reserve role only; change balance and total liability together |
| `executePurchaseV4` | Owner directly buys through an active registered game |
| `executePurchaseWithAuthorizationV4` | Any submitter carrying an owner EIP-712 / ERC-1271 authorization |
| `invalidatePurchaseNonce` | Owner invalidates outstanding purchase authorizations, even while paused |
| `protocolTransfer(recipient, amount)` | Protocol role spends only its own balance; no arbitrary `from` |
| `fundProtocolAccount(account, amount, data)` | Caller funds a role-approved contract with an atomic accounting callback |
| `pause`, `unpause`, `upgradeToAndCall` | Existing role-restricted operational controls |

The V4 purchase request, domain (`UnifiedLedger`, version `4`), attribution rules,
and `PurchaseExecutedV4` event remain unchanged. Signatures still bind the chain
and Ledger proxy address, so old-domain signatures do not work on a fresh Ledger.
`allocationVersion` and `partnerBps` remain event outputs from the round snapshot,
not fields the user or third party supplies in a purchase signature.

No free user-to-user WUSD transfer or general-purpose operator allowance remains.
Do not replace removed operator calls with a role that can debit arbitrary users.
`protocolTransfer` does not change total WUSD liability. Reserve withdrawals
continue while Ledger purchases/deposits are paused; protocol payouts still obey
the Ledger pause.

## Funding and Revenue

Funding is one atomic call to Ledger, not a transfer followed by a separate
accounting call. The callback authenticates Ledger and checks the original funder.
Any callback failure reverts the debit, credit and accounting changes together.

| Account | `data` | Effect and authority |
| --- | --- | --- |
| Lotto3D Treasury | empty bytes | Seed accumulated pool; funder must hold Treasury admin role |
| World Lotto Treasury | `abi.encode(uint8(0))` | Contribute to protocol reserve; any funder, not a refundable personal deposit |
| World Lotto Treasury | `abi.encode(uint8(1))` | Seed carry pool; funder must hold Treasury admin role |

All transfers debit the funder's own WUSD. No prior Ledger allowance is needed.
The protocol reserve contribution is distinct from `StablecoinReserve.deposit`:
the latter credits personal WUSD; the former spends it into protocol-controlled funds.

Every new round snapshots Router allocation. Defaults in the local deployment
are prize 80%, DAT 0%, partner pool 5%, operations 15%, summing to 100%. Updates
affect new rounds only. Partner pool is the gross pool, not the final Web2 partner
contract rate. Partner approval, secondary allocation and payment approval are
not implemented by Ledger.

Purchases reserve full refundable sales until draw settlement. Cancelled rounds
refund the payer and do not accrue revenue. Settled rounds accumulate partner
reserve; the configured Partner Payout Safe independently calls
`claimPartnerReserve(collectionId, accountingRoot, amount)`. It receives WUSD in
Ledger and can withdraw through Reserve. The root records the collection's
accounting commitment, not per-partner entitlement enforced by this contract.
Batching multiple game collections still requires an external Safe batch.

World Lotto uses exclusive highest-tier ticket counting and round-specific
liabilities; expired prizes return to carry. Lotto3D likewise uses round-specific
claim liabilities, with unallocated/expired prizes returning to the accumulated
pool. Base-pool and carry rules are not replaced by a fixed per-ticket payout.

## Deployment Wiring

Deploy Registry, Ledger, Reserve, Router, DAT Vault, both Treasury/Game groups
and their adapters. Initialize proxies atomically at construction.

- Ledger initializer is now `initialize(admin, registry)` only.
- UMA Treasury initializer is `initialize(admin, ledger, tokenUnit, ops, fund)`.
- Grant Ledger `RESERVE_ROLE` only to Reserve; grant `PROTOCOL_ACCOUNT_ROLE` to
  both Treasuries and DAT Vault. A game does not need a spending role.
- Grant 3D Treasury `GAME_ROLE` to its Game and Game `VRF_ROLE` to its adapter.
- Grant UMA Treasury `ROUNDS_ROLE` to Rounds, Treasury/Rounds `SETTLEMENT_ROLE`
  to Settlement, and Rounds `ORACLE_ROLE` to the UMA adapter.
- Configure Treasury `initializeRevenue` before creating any rounds. This is a
  one-time revenue configuration step, not a V2/V3 migration.
- Register each game against the matching Treasury and reviewed implementation
  hash; configure production signers, keepers, asset limits and oracle funding.
- Do not call `initializeV3`, `initializeV4`, `initializeRevenueV4`, or
  `syncLedgerAllowance`; these compatibility functions are absent.

Admins, registry reviewers, upgrade authorities and oracle assertion managers
remain trusted roles. Standalone V4 does not remove their trust or replace Safe
governance. Test admin EOAs and mock oracle configuration are not production-safe.

## Service Changes Required Before Integration

This branch changes only the contract repository. It does not change or deploy
frontend, Backend, Indexer, Settlement Service, Market Service or public manifests.

1. Generate ABI from this branch and publish a new deployment manifest with
   chain ID, all fresh addresses, deployment blocks and implementation identities.
2. Replace old purchase/operator/migration calls. V4 purchase and Reserve
   deposit/withdraw shapes remain usable with new addresses and signatures.
3. Replace prize injection calls with `fundProtocolAccount`. Update deployment
   role setup instead of allowance synchronization.
4. Index `BalanceTransferred` and `ProtocolAccountFunded` instead of removed
   operator events. Preserve `ReserveCredit`, `ReserveDebit`, `Deposited`,
   `Withdrawn`, `PurchaseExecutedV4` and game/revenue event indexing. Do not
   double-count monetary movements by counting both semantic and balance events.
5. Scope balances, tickets, orders and scan cursors by chain/deployment address;
   initialize a new indexed deployment without deleting historical funds records.
6. Exercise wallet confirmation, direct and relayed purchase, refunds, claims,
   Safe collection, and withdrawals through the actual services before release.

Local mocks prove deterministic adapter integration only. Live Chainlink
subscription billing, public UMA disputes, Safe multisignature execution and
frontend/Indexer operation require separate integration checks and security review.
