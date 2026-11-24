# Run 1 — solidity-auditor

<!--RUN pass=1 of=3 stamp=20261124-124956 sha=81b4e5f agents=12/12-->

Pass 1 of 3 · 2026-11-24 · `81b4e5f` · 12/12 agents returned.

## Findings

<!--F key=delayedsettlementswapconductor|-escrowleg|missing-receiver-validation conf=90 kind=FINDING agents=10-->

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

<!--F key=delayedsettlementswapconductor|-releaseleg|freeze-bypass-escrow-release conf=80 kind=FINDING agents=4-->

[80] **A frozen user's open escrow still pays an unfrozen receiver**

`DelayedSettlementSwapConductor._releaseLeg` · Confidence: 80

**Description**
When a frozen user's counterparty repays, `_releaseLeg` debits only the conductor account, so the frozen user's escrowed tokens pay out to a receiver that the user chose.

**Fix (Option A — refund the frozen leg)**:

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

<!--F key=delayedsettlementswapconductor|repay|pause-blocks-deadline-repay conf=75 kind=FINDING agents=4-->

[75] **A pause across an escrow deadline makes a willing payer lose its collateral**

`DelayedSettlementSwapConductor.repay` · Confidence: 75

**Description**
A Depot pause blocks `repay` but does not extend `escrowDeadline`, so after the unpause any caller can `reclaim` and send an honest payer's collateral to the penalty recipient.

**Fix (Option A — extend deadlines by paused time)**:

```diff
-        if (block.timestamp > escrowDeadline[escrowId]) revert SettlementPeriodOver();
+        if (block.timestamp > escrowDeadline[escrowId] + IDepot(DEPOT).pausedDurationSince(escrowCreatedAt[escrowId])) {
+            revert SettlementPeriodOver();
+        }
```

**Fix (Option B — refund collateral when a pause covered the window)**:

```diff
         } else if (leg.collateral != 0) {
-            IDepot(DEPOT).transferFrom(conductorAccountId, PENALTY_RECIPIENT_ACCOUNT_ID, leg.assetId, leg.collateral);
+            bytes28 to = pausedDuringWindow ? leg.accountId : PENALTY_RECIPIENT_ACCOUNT_ID;
+            IDepot(DEPOT).transferFrom(conductorAccountId, to, leg.assetId, leg.collateral);
         }
```

<!--/F-->

## Leads

<!--F key=turnstile|-executemessagelocally|oog-heuristic-nested-call kind=LEAD agents=8-->

- **The out-of-gas check misses an out-of-gas error in a nested call** — `Turnstile._executeMessageLocally` — Code smells: `gasleft() <= gasBefore / 63` assumes one call frame; a proxy token or a conductor that calls the Depot keeps about 0.031 of the gas, more than 1/63. — A nested out-of-gas can be recorded as Failed and wait for the 48h admin `retry`. Agents disagree whether enough gas remains to write the Failed status and emit the event, so the path is not proven.

<!--/F-->

<!--F key=turnstile|-executemessagelocally|failed-withdrawal-no-recovery kind=LEAD agents=1-->

- **A withdrawal release that always fails has no recovery path** — `Turnstile._executeMessageLocally` — Code smells: the hub burns first; a blacklisted or zero `to` makes every `retry` fail with the same body; no function re-routes or re-mints. — The user loses the burned balance and the tokens stay in the VAULT. We did not confirm an admin recovery outside the contracts.

<!--/F-->

<!--F key=turnstile|-executemessagelocally|short-calldata-selector-mismatch kind=LEAD agents=1-->

- **Short Generic calldata makes the checked selector differ from the called selector** — `Turnstile._executeMessageLocally` — Code smells: `bytes4(message.data)` pads short data with zeros, but the executed call takes selector bytes from the chainId suffix. — This needs a source chainId of 2^32 or more and an admin who whitelists a padded selector. We found no live configuration that reaches it.

<!--/F-->

<!--F key=turnstile|-dispatchwithdraw|third-party-message-gas-choice kind=LEAD agents=2-->

- **Any caller picks the message gas for another user's withdrawal** — `Turnstile._dispatchWithdraw` — Code smells: once a request is effective anyone dispatches it and chooses `messageGas`; the reference wiring sets `minimumMessageGas` to 0. — An under-gassed release reverts on the spoke and needs a CCIP manual execution. We did not confirm a deployed minimum that is too low.

<!--/F-->

<!--F key=turnstile|-requiredependency|dependency-satisfied-on-send kind=LEAD agents=3-->

- **dependsOn passes when the parent message is only sent** — `Turnstile._requireDependency` — Code smells: `_handleMessage` marks a cross-chain message Executed before `send`; CCIP V3 keeps no order. — A dependent action, such as a fee or a spoke repay that depends on a deposit, can run on the hub before its parent or after the parent fails. We did not confirm out-of-order delivery on a real lane.

<!--/F-->

<!--F key=hubwarehouseconductor|executewithdrawal|missing-recipient-validation kind=LEAD agents=2-->

- **The withdrawal path accepts a zero recipient** — `HubWarehouseConductor.executeWithdrawal` — Code smells: no check on `action.to`, while `UserConductor.executeTransfer` checks `to`. — The hub burns the balance and the spoke release fails on every retry. Only the owner can sign this input.

<!--/F-->

<!--F key=hubwarehouseconductor|executewithdrawal|facilitated-withdrawal-replay-after-conductor-swap kind=LEAD agents=1-->

- **A facilitated withdrawal signature can run again after a conductor swap** — `HubWarehouseConductor.executeWithdrawal` — Code smells: replay protection lives in the old conductor's request state; a partially fillable body hash changes with the amount. — After `setHubWarehouseConductor`, the solver can replay an old signature and burn the owner's balance again. We did not check whether a migration blocks this.

<!--/F-->

<!--F key=hubwarehouseconductor|receivedeposit|deposit-fee-blocked-by-reservation kind=LEAD agents=2-->

- **A recipient reservation above its balance blocks the deposit fee** — `HubWarehouseConductor.receiveDeposit` — Code smells: the fee uses `transferFrom`, which checks the free balance; `reserve` never checks the balance. — The deposit stays Failed until the reservation is consumed and an admin retries. We found no attacker who gains from this.

<!--/F-->

<!--F key=userconductor|executetransfer|invalid-destination-locks-reservation kind=LEAD agents=1-->

- **A transfer request to chain 0 locks the reservation until its deadline** — `UserConductor.executeTransfer` — Code smells: `requestTransfer` does not check `toChainId`; every execution reverts `InvalidAccount`. — The owner's funds stay reserved until the deadline because no owner cancel exists. Only the owner can create this request.

<!--/F-->

<!--F key=requestconductor|-consume|unfunded-request-consumed-by-anyone kind=LEAD agents=1-->

- **Any caller can consume an underfunded request for zero** — `RequestConductor._consume` — Code smells: an effective fill-or-kill request with a short free balance executes 0 and is marked EXECUTED. — An attacker who times the call wastes one epoch of the owner's time. We found no loss of funds.

<!--/F-->

<!--F key=depot|-reserve|reservation-exceeds-balance kind=LEAD agents=1-->

- **Requests can reserve more than the balance** — `Depot._reserve` — Code smells: `_reserve` never compares with `balanceOf`, and reservations are pooled per account and asset. — The request that runs first can get 0 or a partial amount. We found no third party who gains value.

<!--/F-->

<!--F key=delayedsettlementswapconductor|repay|undelayed-user-outflow-breaks-batch kind=LEAD agents=1-->

- **repay debits the free balance with no epoch delay** — `DelayedSettlementSwapConductor.repay` — Code smells: every other user outflow waits one epoch; `repay` moves funds at once. — A user who owes a debt can call `repay` before `SpotSwapConductor.settle`, so the solver batch reverts for all users. No funds are lost.

<!--/F-->

<!--F key=delayedsettlementswapconductor|-reclaim|reclaim-nonexistent-escrow kind=LEAD agents=1-->

- **reclaim emits Reclaimed for an escrow that does not exist** — `DelayedSettlementSwapConductor._reclaim` — Code smells: a released or unknown escrow has deadline 0, so the guard passes with zero legs. — Any caller can emit a false `Reclaimed` event for indexers. No funds move.

<!--/F-->

<!--F key=spotswapconductor|-fillorders|epoch-based-expiry kind=LEAD agents=2-->

- **Orders can fill after expiresAt for up to one epoch** — `SpotSwapConductor._fillOrders` — Code smells: expiry compares with `lastEpochAdvancedAt`, not `block.timestamp`; DS `_checkOrders` does the same. — The solver can fill an order up to about 24 hours after its expiry. This repeats KI-18.

<!--/F-->
