# Entry Point Map

> Transit Contracts | 46 entry points | 11 permissionless | 22 role-gated | 13 admin-only

Roles are `restricted` (OZ AccessManager) in code; the role holders below follow the reference wiring in `test/integration/SharedSetup.sol` (no deploy scripts exist). Unmapped `restricted` functions default to ADMIN (multisig, 48h execution delay in the reference wiring). `CCIPReceiver.ccipReceive` is inherited from `lib/chainlink-ccip` and was added manually (the scanner only reads `src/`). No contract uses a reentrancy guard.

---

## Protocol Flow Paths

### Setup (Deployer → Admin)

`AccessManager(DEPLOYER)` → deploy `Depot`, `Turnstile(VAULT)`, `CCIPMessagingAdapter`, conductors → `setTargetFunctionRole` / `grantRole` → `Turnstile.setMessagingAdapter()` → `MessagingAdapter.setPeer()` (each chain) → `Turnstile.setHubWarehouseConductor()` (hub only) → `setAssetWhitelisted()` → `setRoutable()` → VAULT `approve(Turnstile)` → `grantRole(ADMIN, multisig, 48h)` + deployer `renounceRole`

### Deposit

`[setup]` → user `approve(Turnstile)` → `Turnstile.dispatch(Deposit)` (or solver `facilitate`) ◄── asset whitelisted, deadline
  ├─→ hub: `HubWarehouseConductor.receiveDeposit()` → `Depot.mint()` [→ `Depot.transferFrom()` fee]
  └─→ spoke: `MessagingAdapter.send()` → [CCIP] → `CCIPMessagingAdapter.ccipReceive()` → `Turnstile.handleReceivedMessage()` → `receiveDeposit()` ◄── Failed → ADMIN `retry()`

### Transfer / Withdrawal request

`[deposit above]` → `UserConductor.requestTransfer()` / `HubWarehouseConductor.requestWithdrawal()` (direct on hub, or `Turnstile.dispatch(Generic)` from any chain) → `Depot.reserve()`
  → [epoch advances: `settle()` or 24h public `Depot.advanceEpoch()`] ◄── effective at epoch+1
  ├─→ anyone: `UserConductor.executeTransfer()` → `Depot.transferFrom()`
  └─→ anyone: `Turnstile.dispatch(Withdrawal)` → `executeWithdrawal()` → `Depot.burn()` → local VAULT release or `send()` → spoke `ccipReceive()` → VAULT `transferFrom`
Facilitated owner (hub account): `Turnstile.facilitate(Withdrawal | Generic executeTransfer)` skips request + epoch.

### Spot swap

`[deposit above]` → user signs `Order` or `SpotSwapConductor.preApprove()` → solver `SpotSwapConductor.settle(epoch)` ◄── epoch == current, not cancelled, not expired → `Depot.transferAmong()` → `Depot.advanceEpoch()`
Cancel: `requestOrderCancellation()` (effective next epoch; facilitated: this epoch)

### Delayed settlement

`[deposit above]` → sign/`preApprove()` → solver `DelayedSettlementSwapConductor.settle()` → escrow (released immediately if neither side collateralized)
  ├─→ `repay()` ◄── `block.timestamp ≤ escrowDeadline` → release when both debts 0
  └─→ `reclaim()` ◄── `block.timestamp > escrowDeadline`

---

## Permissionless

Functions with no role gate. Several act only on the caller's own account (`_senderAccountId()` checks); they are listed here because any address may call them for itself.

### `Turnstile.dispatch()`

| Aspect | Detail |
|--------|--------|
| Visibility | external payable, `whenNotPaused` |
| Caller | Any user (or contract wallet) |
| Parameters | actions[] (user-controlled: type, data, bridgeFee, messageGas) |
| Call chain | Deposit: `→ SafeTransferLib.safeTransferFrom(user → VAULT) → _handleMessage → HubWarehouseConductor.receiveDeposit() | MessagingAdapter.send()`; Withdrawal: `→ HubWarehouseConductor.executeWithdrawal() → Depot.burn() → VAULT transferFrom | send()`; Generic: `→ whitelisted target (hub) | send()` |
| State modified | `messageStatus`, downstream Depot balances/reservations |
| Value flow | Tokens: user → VAULT (deposit); VAULT → `to` (hub withdrawal); ETH bridge fee → adapter/router; refund of unused fee to msg.sender |
| Reentrancy guard | no |

### `UserConductor.executeTransfer()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone once the request is effective; owner instantly via facilitated Generic |
| Parameters | request (user-controlled; must hash to an effective request) |
| Call chain | `→ RequestConductor._consume() → Depot.release() → Depot.transferFrom()` |
| State modified | `requestEffectiveAtEpoch`, Depot reservation + balances |
| Value flow | Ledger only (owner → recipient account); 0 if expired or short and not partially fillable |
| Reentrancy guard | no |

### `DelayedSettlementSwapConductor.reclaim()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone after an escrow deadline |
| Parameters | escrowIds (user-controlled) |
| Call chain | `→ _reclaimLeg() ×2 → Depot.transferFrom(conductor → owner | PENALTY_RECIPIENT)` |
| State modified | `escrowLegs`, `escrowDeadline` (deleted), Depot balances |
| Value flow | Ledger: escrow → owners (refund) / penalty recipient (forfeited collateral) |
| Reentrancy guard | no |

### `DelayedSettlementSwapConductor.repay()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Leg owner (direct on hub, or Generic from the owner's chain) |
| Parameters | escrowId, side (user-controlled) |
| Call chain | `→ Depot.transferFrom(owner → conductor) → [_release() → Depot.transferFrom() ×≤6]` |
| State modified | `escrowLegs[id][side].debt`, possibly escrow deleted, Depot balances |
| Value flow | Ledger: owner → escrow → counterparties / surplus |
| Reentrancy guard | no |

### `Depot.advanceEpoch()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone once 24h since `lastEpochAdvancedAt`; CONDUCTOR role anytime |
| Parameters | none |
| Call chain | `→ _checkCanCall()` (only within 24h) |
| State modified | `settlementEpoch`, `lastEpochAdvancedAt` |
| Value flow | None |
| Reentrancy guard | no |

### Self-scoped user functions

| Function | Access check | Call chain | State modified |
|----------|-------------|------------|----------------|
| `UserConductor.requestTransfer()` | sender account == owner account | `→ Depot.reserve()` | `requestEffectiveAtEpoch`, reservation |
| `HubWarehouseConductor.requestWithdrawal()` | sender account == owner account | `→ Depot.reserve()` | `requestEffectiveAtEpoch`, reservation |
| `SpotSwapConductor.preApprove()` | sender account == order owner | none | `preApproved` |
| `DelayedSettlementSwapConductor.preApprove()` | sender account == order owner | none | `preApproved` |
| `SwapConductor.requestOrderCancellation()` (both swap conductors) | keyed by sender account | `→ Depot.settlementEpoch()` | `cancelledFrom` |
| `MessagingAdapter.receive()` | none (ETH in) | none | ETH balance |

---

## Role-Gated

| Role (reference holder) | Contract.function | Parameters | Call chain / effect |
|------|----------|------------|------------|
| SOLVER (`SOLVER_ADDRESS`, hub + spokes) | `Turnstile.facilitate()` | actions (keeper-provided), signatures (user-signed) | Same as `dispatch` with signer as actor; facilitated flag set for same-chain calls |
| SOLVER | `SpotSwapConductor.settle()` | epoch, orderFills (user-signed orders, keeper-provided fills), fees (keeper-provided) | `→ Depot.transferAmong() → Depot.advanceEpoch()`; writes `filledAmount` |
| SOLVER | `DelayedSettlementSwapConductor.settle()` | epoch, orders/signatures (user-signed), fills (keeper-provided) | `→ Depot.transferAmong() → _release() → Depot.advanceEpoch()`; writes `escrowLegs`, `escrowDeadline`, `escrowCount`, `filledAmount` |
| TURNSTILE (hub Turnstile) | `HubWarehouseConductor.receiveDeposit()` | protocol-derived from message | `→ Depot.mint() [→ Depot.transferFrom() fee]` |
| TURNSTILE | `HubWarehouseConductor.executeWithdrawal()` | action (user-controlled/signed) | `→ _consume() → Depot.release() → Depot.burn()` |
| CONDUCTOR (4 conductors) | `Depot.transferFrom()` / `transferAmong()` / `mint()` / `burn()` / `reserve()` / `release()` | protocol-derived | Ledger writes (`balanceOf`, `reservation`), `whenNotPaused` |
| MESSAGING_ADAPTER (local adapter) | `Turnstile.handleReceivedMessage()` | chainId (bridge), payload | `→ _handleMessage() → _executeMessageLocally()` |
| PAUSER (`PAUSER_ADDRESS` EOA, instant) | `Depot.pause()`, `Turnstile.pause()` | none | `_paused = true` |
| UNPAUSER (`ADMIN_MULTISIG`, instant) | `Depot.unpause()`, `Turnstile.unpause()` | none | `_paused = false` |
| FREEZE_MANAGER (Predicate) | `AddressFreezeList.freeze/freezeAccounts/unfreeze/unfreezeAccounts()` | accounts | `_isFrozen` |
| `LOCAL_TURNSTILE` (msg.sender check) | `MessagingAdapter.send()` | chainId, gasLimit, payload (protocol-derived) | `→ IRouterClient.ccipSend()` (ETH value) |
| CCIP router (`onlyRouter`) | `CCIPReceiver.ccipReceive()` → `_ccipReceive()` | message (bridge-provided) | `→ MessagingAdapter._receive() → Turnstile.handleReceivedMessage()` |

---

## Admin-Only

Unmapped `restricted` functions → ADMIN role (multisig; 48h schedule → execute in the reference wiring).

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| Depot | `forceTransferFrom()` | from, to, asset, amount | `balanceOf` (bypasses pause, freeze, reservations, validity) |
| Depot | `setAddressFreezeList()` | freeze list | `addressFreezeList` |
| Turnstile | `retry()` | sourceChainId, actionType, body | `messageStatus` (Failed → re-executed) |
| Turnstile | `setRoutable()` | target, selectors, allowed | `genericMessageWhitelist` |
| Turnstile | `setAssetWhitelisted()` | assets, allowed | `assetWhitelisted` |
| Turnstile | `setMessagingAdapter()` | adapter | `messagingAdapter` |
| Turnstile | `setHubWarehouseConductor()` | conductor | `hubWarehouseConductor` (hub only) |
| MessagingAdapter | `setPeer()` | chainId, peer, remoteId, gas bounds, allow flags | `peers`, `chainIdForRemoteId` |
| MessagingAdapter | `removePeer()` | chainId | `peers`, `chainIdForRemoteId` |
| MessagingAdapter | `setAllowMessagesFromChain()` / `setAllowMessagesToChain()` | chainId, allowed | `peers[chainId]` flags |
| MessagingAdapter | `setPeerGasLimit()` | chainId, limit | `peers[chainId].messageGasLimit` |
| MessagingAdapter | `withdrawETH()` | to | ETH balance |
