# Run 2 — solidity-auditor

<!--RUN pass=2 of=3 stamp=20261124-124956 sha=81b4e5f agents=12/12-->

Pass 2 of 3 · 2026-11-24 · `81b4e5f` · 12/12 agents returned.

## Findings

<!--F key=delayedsettlementswapconductor|-escrowleg|missing-receiver-validation conf=90 kind=FINDING agents=5-->

[90] **An invalid receiver on one order makes the counterparty forfeit its collateral**

`DelayedSettlementSwapConductor._escrowLeg` · Confidence: 90

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

<!--/F-->

<!--F key=delayedsettlementswapconductor|-releaseleg|freeze-bypass-escrow-release conf=80 kind=FINDING agents=3-->

[80] **A frozen user's open escrow still pays an unfrozen receiver**

`DelayedSettlementSwapConductor._releaseLeg` · Confidence: 80

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

<!--/F-->

<!--F key=delayedsettlementswapconductor|repay|pause-blocks-deadline-repay conf=75 kind=FINDING agents=8-->

[75] **A pause across an escrow deadline makes a willing payer lose its collateral**

`DelayedSettlementSwapConductor.repay` · Confidence: 75

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

<!--/F-->

<!--F key=delayedsettlementswapconductor|-fillorders|fok-split-across-escrows conf=75 kind=FINDING agents=1-->

[75] **A fill-or-kill order split across escrows can execute only in part**

`DelayedSettlementSwapConductor._fillOrders` · Confidence: 75

**Description**
The fill-or-kill check uses only the batch total, so a collateralized counterparty that defaults on one pair leaves the order half filled and fully used.

**Fix**

```diff
+        // in _escrowFill, for each side:
+        if (!order.partiallyFillable && fill.amounts[side] != order.sellAmount) revert NotPartiallyFillable(orderHash);
```

<!--/F-->

## Leads

<!--F key=turnstile|-isroutable|routing-guard-misses-role-forwarder kind=LEAD agents=6-->

- **The routing guard misses targets that forward the Turnstile's authority** — `Turnstile._isRoutable` — Code smells: `_isTurnstileOnly` checks only a direct TURNSTILE role; `AccessManager.execute` (role ADMIN) and `MessagingAdapter.send` (gated on `msg.sender`) both pass. — If an admin whitelists either one, any Generic sender can mint through `receiveDeposit` or forge a Withdrawal message. This needs an admin whitelist error.

<!--/F-->

<!--F key=turnstile|-hasvaultallowance|routing-guard-ignores-user-allowances kind=LEAD agents=4-->

- **The routing guard ignores user allowances to the Turnstile** — `Turnstile._hasVaultAllowance` — Code smells: only `allowance(VAULT, Turnstile)` is checked; users give the hub Turnstile deposit allowances. — A routed token whose VAULT allowance is 0 lets a Generic sender call `transferFrom(victim, attacker, x)`. This needs an admin to route the token.

<!--/F-->

<!--F key=turnstile|-executemessagelocally|oog-heuristic-nested-call kind=LEAD agents=4-->

- **The out-of-gas check misses an out-of-gas error in a nested call** — `Turnstile._executeMessageLocally` — Code smells: `gasleft() <= gasBefore / 63` assumes one call frame. — Two agents estimate the leftover gas cannot pay for the Failed write and event at normal token costs, so the third-party path is not shown.

<!--/F-->

<!--F key=turnstile|-executemessagelocally|failed-withdrawal-no-recovery kind=LEAD agents=2-->

- **A withdrawal release that always fails has no recovery path** — `Turnstile._executeMessageLocally` — Code smells: the hub burns first; a blacklisted `to` makes every `retry` fail. — The tokens stay in the VAULT and no path re-mints the hub balance.

<!--/F-->

<!--F key=turnstile|-executemessagelocally|depot-pause-forces-failed-deposit kind=LEAD agents=1-->

- **A Depot pause turns every in-flight message into a Failed message** — `Turnstile._executeMessageLocally` — Code smells: a Turnstile pause reverts delivery for a bridge retry, but a Depot pause makes the conductor call fail inside the try. — The pauser can make all in-flight deposits need a 48h admin `retry` each. We did not measure the volume.

<!--/F-->

<!--F key=turnstile|-executemessagelocally|short-calldata-selector-mismatch kind=LEAD agents=2-->

- **Short Generic calldata makes the checked selector differ from the called selector** — `Turnstile._executeMessageLocally` — Code smells: `bytes4(message.data)` pads short data with zeros. — The selectors differ only for a chainId of 2^32 or more. We found no live chain that reaches it.

<!--/F-->

<!--F key=turnstile|-dispatchwithdraw|third-party-message-gas-choice kind=LEAD agents=3-->

- **Any caller picks the message gas for another user's withdrawal** — `Turnstile._dispatchWithdraw` — Code smells: `messageGas` is not signed; only `minimumMessageGas` bounds it. — A direct out-of-gas reverts for a bridge retry, so the harm is a delay unless the minimum is too low.

<!--/F-->

<!--F key=turnstile|-dispatchwithdraw|dependency-blocks-expired-consume kind=LEAD agents=1-->

- **An expired withdrawal whose dependency never executes can never be consumed** — `Turnstile._dispatchWithdraw` — Code smells: `_requireDependency` runs before `executeWithdrawal`, which is the only path that consumes an expired request. — The reservation then locks the owner's funds forever. The owner chooses `dependsOn`.

<!--/F-->

<!--F key=turnstile|-dispatchdeposit|vault-self-deposit-unbacked-mint kind=LEAD agents=1-->

- **A deposit from the VAULT to itself mints balance with no new tokens** — `Turnstile._dispatchDeposit` — Code smells: no check that `from != VAULT`, and the VAULT approves the Turnstile. — Whoever operates the VAULT can mint unbacked balance. We found no unprivileged path.

<!--/F-->

<!--F key=turnstile|-dispatchdeposit|assumed-amount-fee-on-transfer kind=LEAD agents=1-->

- **The deposit mints the signed amount, not the received amount** — `Turnstile._dispatchDeposit` — Code smells: no balance check before and after `safeTransferFrom`. — If a token such as USDT turns on its transfer fee, ledger supply exceeds the VAULT balance. TA-5 accepts this today.

<!--/F-->

<!--F key=turnstile|-requiredependency|dependency-satisfied-on-send kind=LEAD agents=3-->

- **dependsOn passes when the parent message is only sent** — `Turnstile._requireDependency` — Code smells: the source marks a message Executed before `send`; CCIP keeps no order. — A spoke repay that depends on a deposit can reach the hub first and fail. We did not confirm reordering on a real lane.

<!--/F-->

<!--F key=hubwarehouseconductor|executewithdrawal|missing-recipient-validation kind=LEAD agents=2-->

- **The withdrawal path accepts a zero recipient** — `HubWarehouseConductor.executeWithdrawal` — Code smells: no check on `action.to`. — The hub burns the balance and the release fails. Only the owner can sign this input.

<!--/F-->

<!--F key=hubwarehouseconductor|executewithdrawal|facilitated-withdrawal-replay-after-conductor-swap kind=LEAD agents=1-->

- **A facilitated withdrawal signature can run again after a conductor swap** — `HubWarehouseConductor.executeWithdrawal` — Code smells: replay state lives in the old conductor. — The solver can burn the owner's balance a second time when the executed amount differs.

<!--/F-->

<!--F key=hubwarehouseconductor|executewithdrawal|frozen-owner-zero-burn-blocks-consume kind=LEAD agents=1-->

- **A zero burn reverts for a frozen owner, so its request cannot be consumed** — `HubWarehouseConductor.executeWithdrawal` — Code smells: `burn(account, asset, 0)` still runs the freeze check. — The frozen owner's reservation stays until the deadline, or forever with a maximum deadline.

<!--/F-->

<!--F key=hubwarehouseconductor|executewithdrawal|invalid-destination-locks-reservation kind=LEAD agents=1-->

- **A withdrawal to a chain with no peer locks its reservation** — `HubWarehouseConductor.executeWithdrawal` — Code smells: every dispatch reverts in the adapter, which also rolls back `_consume`. — If the admin removes a peer, open long-deadline requests to that chain stay reserved.

<!--/F-->

<!--F key=hubwarehouseconductor|receivedeposit|deposit-fee-blocked-by-reservation kind=LEAD agents=4-->

- **A recipient reservation above its balance blocks the deposit fee** — `HubWarehouseConductor.receiveDeposit` — Code smells: the fee needs free balance; KI-8 can leave reserved above balance. — The deposit stays Failed until the request is consumed and an admin retries.

<!--/F-->

<!--F key=hubwarehouseconductor|receivedeposit|deposit-fee-blocked-by-frozen-recipient kind=LEAD agents=1-->

- **A frozen recipient makes a fee deposit fail on every retry** — `HubWarehouseConductor.receiveDeposit` — Code smells: only `fromAccountId` is checked for a freeze; the fee debits `toAccountId`. — The depositor's tokens wait in the VAULT until the recipient is unfrozen.

<!--/F-->

<!--F key=userconductor|executetransfer|invalid-destination-locks-reservation kind=LEAD agents=2-->

- **A transfer request to chain 0 locks the reservation until its deadline** — `UserConductor.executeTransfer` — Code smells: `requestTransfer` does not check `toChainId`. — Only the owner can create this request.

<!--/F-->

<!--F key=requestconductor|-consume|unfunded-request-consumed-by-anyone kind=LEAD agents=4-->

- **Any caller can consume an underfunded request for zero** — `RequestConductor._consume` — Code smells: a short fill-or-kill request executes 0 and is marked EXECUTED. — The owner loses one epoch. No agent found an unprivileged way to make the balance short.

<!--/F-->

<!--F key=depot|-reserve|reservation-exceeds-balance kind=LEAD agents=1-->

- **Requests can reserve more than the balance** — `Depot._reserve` — Code smells: no check against `balanceOf`. — Later inflows and fee debits on that account fail until the request is consumed.

<!--/F-->

<!--F key=swapconductor|requestordercancellation|turnstile-pause-blocks-spoke-cancel kind=LEAD agents=2-->

- **A Turnstile pause stops spoke owners from cancelling orders** — `SwapConductor.requestOrderCancellation` — Code smells: spoke owners cancel only through Generic messages; settle checks only the Depot pause. — The solver keeps filling orders that spoke owners cannot cancel. Fills still meet the limit price.

<!--/F-->

<!--F key=delayedsettlementswapconductor|repay|undelayed-user-outflow-breaks-batch kind=LEAD agents=2-->

- **repay debits the free balance with no epoch delay** — `DelayedSettlementSwapConductor.repay` — Code smells: `repay` is the only unprivileged path that lowers free balance at once. — A user can make the solver's batch for the epoch revert. No funds are lost.

<!--/F-->

<!--F key=delayedsettlementswapconductor|-checkorders|epoch-based-expiry kind=LEAD agents=2-->

- **Delayed orders can be escrowed after expiresAt** — `DelayedSettlementSwapConductor._checkOrders` — Code smells: expiry compares with `lastEpochAdvancedAt`. — The owner can take on a collateralized debt about 24 hours after its order expired.

<!--/F-->

<!--F key=delayedsettlementswapconductor|-settlementperiod|uncollateralized-pair-period-check kind=LEAD agents=1-->

- **An unused period decides whether an uncollateralized pair settles** — `DelayedSettlementSwapConductor._settlementPeriod` — Code smells: the second order's period is checked even when neither side is collateralized. — The result depends on the order of the indexes. No loss.

<!--/F-->

<!--F key=delayedsettlementswapconductor|constructor|unvalidated-recipient-immutables kind=LEAD agents=1-->

- **The constructor accepts an invalid penalty or surplus account** — `DelayedSettlementSwapConductor.constructor` — Code smells: no `isValid` check on the immutables. — A wrong deploy makes every reclaim and fee release revert. Only a redeploy fixes it.

<!--/F-->

<!--F key=delayedsettlementswapconductor|-reclaim|reclaim-nonexistent-escrow kind=LEAD agents=1-->

- **reclaim emits Reclaimed for an escrow that does not exist** — `DelayedSettlementSwapConductor._reclaim` — Code smells: a deleted escrow has deadline 0. — Indexers can record false reclaims. No funds move.

<!--/F-->

<!--F key=spotswapconductor|-fillorders|epoch-based-expiry kind=LEAD agents=3-->

- **Orders can fill after expiresAt for up to one epoch** — `SpotSwapConductor._fillOrders` — Code smells: expiry compares with `lastEpochAdvancedAt`. — For up to 24 hours the owner cannot stop a fill of an expired order. The limit price holds.

<!--/F-->
