# 🔐 Security Review — transit-contracts

---

## Scope

|  |  |
| --- | --- |
| **Mode** | default |
| **Files reviewed** | `./src/AddressFreezeList.sol` · `./src/depot/Depot.sol` · `./src/turnstile/Turnstile.sol`<br>`./src/conductor/SpotSwapConductor.sol` · `./src/conductor/SwapConductor.sol` · `./src/conductor/DelayedSettlementSwapConductor.sol`<br>`./src/conductor/ConductorGatedByTurnstile.sol` · `./src/conductor/UserConductor.sol` · `./src/conductor/RequestConductor.sol`<br>`./src/conductor/HubWarehouseConductor.sol` · `./src/messaging/CCIPMessagingAdapter.sol` · `./src/messaging/MessagingAdapter.sol`<br>`./src/helpers/Roles.sol` · `./src/helpers/TransitAddressLib.sol` · `./src/helpers/Typehashes.sol` |
| **Confidence threshold (1-100)** | 75 |
| **Passes** | 3 |
| **Memory** | 0 records before this scan · 42 after · `81b4e5f` |

---

## Findings

[95] **1. The adapter requests safe-head finality that its own receiver rejects**

`CCIPMessagingAdapter._buildMessage` · Confidence: 95 · seen in 1/3 runs · NEW

**Description**
The adapter sends with `WAIT_FOR_SAFE_FLAG` but inherits a receiver config that allows only full finality, so the OffRamp rejects every message and no deposit or withdrawal arrives.

**Fix (Option A — accept the requested finality)**:

```diff
+    function getCCVsAndFinalityConfig(uint64, bytes calldata)
+        external
+        pure
+        override
+        returns (address[] memory, address[] memory, uint8, bytes4)
+    {
+        return (new address[](0), new address[](0), 0, FinalityCodec.WAIT_FOR_SAFE_FLAG);
+    }
```

**Fix (Option B — request full finality)**:

```diff
-            extraArgs: ExtraArgsCodec._getBasicEncodedExtraArgsV3FastConfirmationRule(SafeCastLib.toUint32(gasLimit))
+            extraArgs: ExtraArgsCodec._getBasicEncodedExtraArgsV3(SafeCastLib.toUint32(gasLimit), FinalityCodec.WAIT_FOR_FINALITY_FLAG)
```

---

[90] **2. An invalid receiver on one order makes the counterparty forfeit its collateral**

`DelayedSettlementSwapConductor._escrowLeg` · Confidence: 90 · seen in 3/3 runs · NEW

**Description**
An attacker signs an order with a zero receiver or receiver chain, so every `repay` by the collateralized counterparty reverts and `reclaim` sends its collateral to the penalty recipient.

**Fix**

```diff
+        bytes28 receiverAccountId = TransitAddressLib.formatTransitAddress(order.receiverChainId, order.receiver);
+        if (!TransitAddressLib.isValid(receiverAccountId)) revert BadPair(index);
         escrowLegs[escrowId][side] = Leg({
             accountId: ownerAccountIds[orderIndex],
-            receiverAccountId: TransitAddressLib.formatTransitAddress(order.receiverChainId, order.receiver),
+            receiverAccountId: receiverAccountId,
```

---

[80] **3. A frozen user's open escrow still pays an unfrozen receiver**

`DelayedSettlementSwapConductor._releaseLeg` · Confidence: 80 · seen in 3/3 runs · NEW

**Description**
When a frozen user's counterparty repays, `_releaseLeg` debits only the conductor account, so the frozen user's escrowed tokens pay out to a receiver that the user chose.

**Fix (Option A — take the reclaim path for a frozen leg)**:

```diff
     function _release(uint256 escrowId) internal {
         Leg[2] memory legs = escrowLegs[escrowId];
+        IAddressFreezeList freezeList = IDepot(DEPOT).addressFreezeList();
+        if (freezeList.isFrozen(legs[0].accountId) || freezeList.isFrozen(legs[1].accountId)) {
+            // refund both legs to their owners so the admin can seize the frozen side
+        }
```

**Fix (Option B — redirect frozen proceeds to the owner account)**:

```diff
-            .transferFrom(conductorAccountId, counterparty.receiverAccountId, leg.assetId, leg.amount - leg.fee);
+            .transferFrom(
+                conductorAccountId,
+                frozen(counterparty.accountId) ? counterparty.accountId : counterparty.receiverAccountId,
+                leg.assetId,
+                leg.amount - leg.fee
+            );
```

---

[75] **4. A fill-or-kill order split across escrows can execute only in part**

`DelayedSettlementSwapConductor._fillOrders` · Confidence: 75 · seen in 2/3 runs · NEW

**Description**
The fill-or-kill check uses only the batch total, so a collateralized counterparty that defaults on one pair leaves the order half filled and fully used.

**Fix (Option A — fill-or-kill per pair)**:

```diff
+        // in _escrowFill, for each side:
+        if (!order.partiallyFillable && fill.amounts[side] != order.sellAmount) revert NotPartiallyFillable(orderHash);
```

**Fix (Option B — ban the risky pairing)**:

```diff
+        // reject a fill-or-kill order that appears in more than one PairedFill or is paired with a collateralized order
```

---

[75] **5. A pause across an escrow deadline makes a willing payer lose its collateral**

`DelayedSettlementSwapConductor.repay` · Confidence: 75 · seen in 3/3 runs · NEW

**Description**
A Depot pause, or a Turnstile pause for a spoke owner, blocks `repay` but not `reclaim`, so after the deadline any caller sends an honest payer's collateral to the penalty recipient.

**Fix (Option A — extend deadlines by paused time)**:

```diff
-        if (block.timestamp > escrowDeadline[escrowId]) revert SettlementPeriodOver();
+        if (block.timestamp > escrowDeadline[escrowId] + IDepot(DEPOT).pausedDurationSince(escrowCreatedAt[escrowId])) {
+            revert SettlementPeriodOver();
+        }
```

**Fix (Option B — accept late payment until reclaim)**:

```diff
-        if (block.timestamp > escrowDeadline[escrowId]) revert SettlementPeriodOver();
+        if (escrowDeadline[escrowId] == 0) revert SettlementPeriodOver();
```

**Fix (Option C — block reclaim while paused)**:

```diff
     function _reclaim(uint256 escrowId) internal {
         if (block.timestamp <= escrowDeadline[escrowId]) revert SettlementPeriodActive();
+        if (Pausable(address(TURNSTILE)).paused()) revert EnforcedPause();
```

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [95] | The adapter requests safe-head finality that its own receiver rejects |
| 2 | [90] | An invalid receiver on one order makes the counterparty forfeit its collateral |
| 3 | [80] | A frozen user's open escrow still pays an unfrozen receiver |
| 4 | [75] | A fill-or-kill order split across escrows can execute only in part |
| 5 | [75] | A pause across an escrow deadline makes a willing payer lose its collateral |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **An address-only freeze can freeze protocol accounts** — `AddressFreezeList.isFrozen` · seen in 1/3 runs · NEW — Code smells: the chainId is dropped, so a frozen address freezes the hub account of the same address. — A freeze of the DS conductor address blocks every escrow payout. Reachability not confirmed.
- **Delayed orders can be escrowed after expiresAt** — `DelayedSettlementSwapConductor._checkOrders` · seen in 1/3 runs · NEW — Code smells: expiry compares with `lastEpochAdvancedAt`. — The owner can take on a collateralized debt about 24 hours after its order expired.
- **Many tiny escrows raise the collateral above one percent** — `DelayedSettlementSwapConductor._escrowLeg` · seen in 1/3 runs · NEW — Code smells: `divUp(amount, FILL_RATIO)` rounds up per escrow, not per order. — A solver that splits an order into many tiny pairs makes the owner post far more collateral. Not confirmed for a real token.
- **reclaim emits Reclaimed for an escrow that does not exist** — `DelayedSettlementSwapConductor._reclaim` · seen in 3/3 runs · NEW — Code smells: a deleted escrow has deadline 0. — Indexers can record false reclaims.
- **A freeze of the DS conductor address locks every escrow** — `DelayedSettlementSwapConductor._releaseLeg` · seen in 1/3 runs · NEW — Code smells: every payout debits the conductor account, which the freeze check covers. — Release, repay and reclaim all fail until an unfreeze. This needs a freeze-manager mistake.
- **An unused period decides whether an uncollateralized pair settles** — `DelayedSettlementSwapConductor._settlementPeriod` · seen in 2/3 runs · NEW — Code smells: the second order's period is checked when neither side is collateralized. — A valid match can fail. No loss.
- **The constructor accepts an invalid penalty or surplus account** — `DelayedSettlementSwapConductor.constructor` · seen in 1/3 runs · NEW — Code smells: no `isValid` check on the immutables. — A wrong deploy makes every reclaim and fee release revert. Only a redeploy fixes it.
- **A failed cross-chain repay cannot be retried before the deadline** — `DelayedSettlementSwapConductor.repay` · seen in 1/3 runs · NEW — Code smells: admin `retry` takes 48h, longer than the 1-day maximum period. — The user must resend before the deadline; a retry never saves the repay.
- **repay debits the free balance with no epoch delay** — `DelayedSettlementSwapConductor.repay` · seen in 3/3 runs · NEW — Code smells: `repay` lowers free balance at once. — A user can make the solver's batch revert. No funds are lost.
- **Reservations fail after 2^32 epochs** — `Depot._reserve` · seen in 1/3 runs · NEW — Code smells: `pendingEpoch` is a `uint32` and empty settles advance the epoch. — About 4.3e9 settles are needed, so this is not practical.
- **The caller who executes pooled requests decides which one gets the funds** — `Depot._reserve` · seen in 3/3 runs · NEW — Code smells: reservations form one pool per account and asset, and `reserve` never checks the balance. — A third party who picks the execution order decides which request moves funds and which is consumed for zero.
- **One request cannot reserve more than 2^112 base units** — `Depot._reserve` · seen in 1/3 runs · NEW — Code smells: `toUint112` caps the reservation per account and asset. — A very large holder needs many requests. No whitelisted token reaches this size.
- **The solver can advance the epoch many times with empty settles** — `Depot.advanceEpoch` · seen in 1/3 runs · NEW — Code smells: both swap conductors accept empty batches and still advance. — Every conductor holds the full CONDUCTOR grant. No user loss found.
- **A facilitated withdrawal signature can run again after a conductor swap** — `HubWarehouseConductor.executeWithdrawal` · seen in 3/3 runs · NEW — Code smells: replay state lives in the old conductor; a different executed amount gives a new message body. — The solver can withdraw a partially fillable action a second time after `setHubWarehouseConductor`.
- **A zero burn reverts for a frozen owner, so its request cannot be consumed** — `HubWarehouseConductor.executeWithdrawal` · seen in 1/3 runs · NEW — Code smells: `burn(account, asset, 0)` still runs the freeze check. — The frozen owner's reservation stays until the deadline, or forever with a maximum deadline.
- **A withdrawal to a chain with no peer locks its reservation** — `HubWarehouseConductor.executeWithdrawal` · seen in 1/3 runs · NEW — Code smells: every dispatch reverts in the adapter, which also rolls back `_consume`. — If the admin removes a peer, open long-deadline requests to that chain stay reserved.
- **The withdrawal path accepts a zero recipient** — `HubWarehouseConductor.executeWithdrawal` · seen in 2/3 runs · NEW — Code smells: no check on `action.to`. — The hub burns the balance and the release fails. Only the owner can sign this input.
- **Two hashWithdrawalAction functions return different hashes** — `HubWarehouseConductor.hashWithdrawalAction` · seen in 1/3 runs · NEW — Code smells: the conductor returns a raw struct hash; the Turnstile returns the EIP-712 digest. — An integrator who looks up a request with the Turnstile hash finds nothing. No on-chain path mixes them.
- **A frozen recipient makes a fee deposit fail on every retry** — `HubWarehouseConductor.receiveDeposit` · seen in 1/3 runs · NEW — Code smells: only `fromAccountId` is checked for a freeze; the fee debits `toAccountId`. — The depositor's tokens wait in the VAULT until the recipient is unfrozen.
- **A recipient reservation above its balance blocks the deposit fee** — `HubWarehouseConductor.receiveDeposit` · seen in 2/3 runs · NEW — Code smells: the fee needs free balance; KI-8 can leave reserved above balance. — The deposit stays Failed until the request is consumed and an admin retries.
- **Any caller can consume an underfunded request for zero** — `RequestConductor._consume` · seen in 3/3 runs · NEW — Code smells: a short fill-or-kill request executes 0 and is marked EXECUTED. — The owner loses one epoch.
- **Orders can fill after expiresAt for up to one epoch** — `SpotSwapConductor._fillOrders` · seen in 2/3 runs · NEW — Code smells: expiry compares with `lastEpochAdvancedAt`. — For up to 24 hours the owner cannot stop a fill of an expired order. The limit price holds.
- **A Turnstile pause stops spoke owners from cancelling orders** — `SwapConductor.requestOrderCancellation` · seen in 1/3 runs · NEW — Code smells: spoke owners cancel only through Generic messages; settle checks only the Depot pause. — The solver keeps filling orders that spoke owners cannot cancel. Fills still meet the limit price.
- **The deposit mints the signed amount, not the received amount** — `Turnstile._dispatchDeposit` · seen in 1/3 runs · NEW — Code smells: no balance check before and after `safeTransferFrom`. — If a token such as USDT turns on its transfer fee, ledger supply exceeds the VAULT balance. TA-5 accepts this today.
- **A deposit from the VAULT to itself mints balance with no new tokens** — `Turnstile._dispatchDeposit` · seen in 1/3 runs · NEW — Code smells: no check that `from != VAULT`, and the VAULT approves the Turnstile. — Whoever operates the VAULT can mint unbacked balance. We found no unprivileged path.
- **An expired withdrawal whose dependency never executes can never be consumed** — `Turnstile._dispatchWithdraw` · seen in 1/3 runs · NEW — Code smells: `_requireDependency` runs before `executeWithdrawal`, which is the only path that consumes an expired request. — The reservation then locks the owner's funds forever. The owner chooses `dependsOn`.
- **Any caller picks the message gas for another user's withdrawal** — `Turnstile._dispatchWithdraw` · seen in 3/3 runs · NEW — Code smells: `messageGas` is not signed; only `minimumMessageGas` bounds it. — The harm depends on the configured minimum.
- **A Depot pause turns every in-flight message into a Failed message** — `Turnstile._executeMessageLocally` · seen in 2/3 runs · NEW — Code smells: a Depot pause fails the conductor call inside the try, while a Turnstile pause reverts for a bridge retry. — The pauser can make all in-flight deposits wait for a 48h admin `retry` each.
- **A withdrawal release that always fails has no recovery path** — `Turnstile._executeMessageLocally` · seen in 2/3 runs · NEW — Code smells: the hub burns first; a blacklisted `to` makes every `retry` fail. — The tokens stay in the VAULT and no path re-mints the hub balance.
- **The hub accepts a Withdrawal message from any spoke** — `Turnstile._executeMessageLocally` · seen in 1/3 runs · NEW — Code smells: no check ties a Withdrawal message to source chain == hub. — A compromised spoke Turnstile or adapter can release hub VAULT tokens. This needs a peer compromise (TA-3).
- **The out-of-gas check misses an out-of-gas error in a nested call** — `Turnstile._executeMessageLocally` · seen in 3/3 runs · NEW — Code smells: `gasleft() <= gasBefore / 63` assumes one call frame; any caller picks `messageGas` for another user's withdrawal. — Two agents claim a Failed release; the gas left (about 1,100) cannot pay for the Failed write and the `MessageFailed` event, so the delivery reverts for a bridge retry. Not proven for normal token costs.
- **Short Generic calldata makes the checked selector differ from the called selector** — `Turnstile._executeMessageLocally` · seen in 2/3 runs · NEW — Code smells: `bytes4(message.data)` pads short data with zeros. — The selectors differ only for a chainId of 2^32 or more. We found no live chain that reaches it.
- **The routing guard ignores user allowances to the Turnstile** — `Turnstile._hasVaultAllowance` · seen in 2/3 runs · NEW — Code smells: only `allowance(VAULT, Turnstile)` is checked. — A routed token with no VAULT allowance lets a Generic sender spend users' deposit approvals. This needs an admin to route the token.
- **The routing guard misses targets that forward the Turnstile's authority** — `Turnstile._isRoutable` · seen in 2/3 runs · NEW — Code smells: `_isTurnstileOnly` checks only a direct TURNSTILE role in the Turnstile's own authority; `MessagingAdapter.send` and `AccessManager.execute` pass. — If an admin whitelists either one, any Generic sender can forge a Withdrawal message or mint through `receiveDeposit`. This needs an admin whitelist error.
- **dependsOn passes when the parent message is only sent** — `Turnstile._requireDependency` · seen in 3/3 runs · NEW — Code smells: the source marks a message Executed before `send`; CCIP keeps no order. — A spoke repay that depends on a deposit can reach the hub first and fail; the user can resend with a new salt.
- **A zero transfer reverts for a frozen owner, so its request cannot be consumed** — `UserConductor.executeTransfer` · seen in 1/3 runs · NEW — Code smells: `transferFrom(account, to, asset, 0)` still runs the freeze check. — The frozen owner's reservation stays until the request deadline.
- **A transfer request to a zero address can never be consumed** — `UserConductor.executeTransfer` · seen in 3/3 runs · NEW — Code smells: the `to == address(0)` check runs before `_consume` and before the deadline branch. — The owner's reservation stays forever. Only the owner can sign this request.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
